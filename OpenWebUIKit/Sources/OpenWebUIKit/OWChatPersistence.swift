import Foundation

// Persisting a chat to Open WebUI. Verified against a live 0.9.6 instance:
// POST /api/v1/chats/new  body { "chat": { title, models, params, messages,
// history{messages,currentId}, tags, timestamp } } → 200 with the saved record;
// POST /api/v1/chats/{id} updates it. The server keeps a branching `history`
// map keyed by message id (parentId/childrenIds); we build a simple linear chain.

/// The `chat` object Open WebUI expects when creating/updating a conversation.
struct OWChatPayload: Encodable {
    var title: String
    var models: [String]
    var params: [String: String]
    var messages: [Msg]
    var history: History
    var tags: [String]
    var timestamp: Int   // epoch milliseconds

    struct Msg: Encodable {
        var id: String
        var role: String
        var content: String
        var timestamp: Int          // epoch seconds
        var model: String?
        var modelName: String?
        var parentId: String?
        var childrenIds: [String]
        var files: [OWAttachment]?       // attached images + documents
    }

    struct History: Encodable {
        var messages: [String: Msg]
        var currentId: String?
    }

    init(title: String, model: String, messages source: [OWMessage]) {
        self.title = title
        self.models = [model]
        self.params = [:]
        self.tags = []
        let now = Int(Date().timeIntervalSince1970)
        self.timestamp = now * 1000

        var list: [Msg] = []
        var map: [String: Msg] = [:]
        var parentId: String? = nil
        for (i, m) in source.enumerated() {
            let ts = m.timestamp.map { Int($0) } ?? now
            let isUser = (m.role == .user)
            let childId = (i + 1 < source.count) ? source[i + 1].id : nil
            let msg = Msg(
                id: m.id,
                role: m.role.rawValue,
                content: m.content,
                timestamp: ts,
                model: isUser ? nil : (m.model ?? model),
                modelName: isUser ? nil : (m.model ?? model),
                parentId: parentId,
                childrenIds: childId.map { [$0] } ?? [],
                files: {
                    let atts = m.imageURLs.map { OWAttachment(type: "image", url: $0) } + m.documents
                    return atts.isEmpty ? nil : atts
                }()
            )
            list.append(msg)
            map[m.id] = msg
            parentId = m.id
        }
        self.messages = list
        self.history = History(messages: map, currentId: source.last?.id)
    }
}

extension OWChatPayload {
    /// A history node dict for one message, built through Msg so the JSON shape
    /// stays identical to what createChat writes. parentId/childrenIds are
    /// linked by the caller.
    static func node(for m: OWMessage, model: String, now: Int) -> [String: Any] {
        let isUser = (m.role == .user)
        let msg = Msg(
            id: m.id, role: m.role.rawValue, content: m.content,
            timestamp: m.timestamp.map { Int($0) } ?? now,
            model: isUser ? nil : (m.model ?? model),
            modelName: isUser ? nil : (m.model ?? model),
            parentId: nil, childrenIds: [],
            files: {
                let atts = m.imageURLs.map { OWAttachment(type: "image", url: $0) } + m.documents
                return atts.isEmpty ? nil : atts
            }()
        )
        var dict = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(msg))) as? [String: Any] ?? [:]
        if !isUser {
            dict["done"] = true
            if !m.sources.isEmpty {
                dict["sources"] = m.sources.map { s -> [String: Any] in
                    ["source": ["name": s.name, "url": s.url ?? s.name] as [String: Any],
                     "document": [String](),
                     "metadata": [["source": s.url ?? s.name]]]
                }
            }
        }
        return dict
    }
}

extension OpenWebUIClient {
    /// Creates a new chat from the given messages. Returns the new chat id.
    public func createChat(title: String, model: String, messages: [OWMessage]) async throws -> String {
        let payload = OWChatPayload(title: title, model: model, messages: messages)
        let req = try jsonRequest("/api/v1/chats/new", method: "POST", body: ["chat": payload])
        struct R: Decodable { var id: String }
        return try decode(R.self, try await send(req)).id
    }

    /// Replaces an existing chat's contents (full message set).
    /// DESTRUCTIVE: drops server-side fields this client doesn't model
    /// (web `output`, sources, branching). Prefer syncChat.
    public func updateChat(id: String, title: String, model: String, messages: [OWMessage]) async throws {
        let payload = OWChatPayload(title: title, model: model, messages: messages)
        let req = try jsonRequest("/api/v1/chats/\(encPath(id))", method: "POST", body: ["chat": payload])
        _ = try await send(req)
    }

    /// Merge-safe save: fetches the raw server chat, keeps every byte the server
    /// already has (web-generated `output`, sources, statusHistory, params, the
    /// branching graph), appends ONLY messages the server has never seen, and
    /// writes the result back. Server wins for known ids — we never re-encode
    /// pre-existing messages, so web data survives an app save untouched.
    public func syncChat(id: String, localMessages: [OWMessage], model: String) async throws {
        let data = try await send(request("/api/v1/chats/\(encPath(id))"))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var chat = obj["chat"] as? [String: Any] else { throw OWError.decoding("chat") }

        var history = chat["history"] as? [String: Any] ?? [:]
        var nodes = history["messages"] as? [String: [String: Any]] ?? [:]
        // Legacy/empty graph: seed it from the flat list so linking still works.
        if nodes.isEmpty, let flat = chat["messages"] as? [[String: Any]] {
            for m in flat { if let mid = m["id"] as? String { nodes[mid] = m } }
        }

        let fresh = localMessages.filter { nodes[$0.id] == nil }
        guard !fresh.isEmpty else { return }

        var parent = (history["currentId"] as? String).flatMap { nodes[$0] != nil ? $0 : nil }
        let now = Int(Date().timeIntervalSince1970)
        for m in fresh {
            var node = OWChatPayload.node(for: m, model: model, now: now)
            node["parentId"] = parent ?? NSNull()
            node["childrenIds"] = [String]()
            if let p = parent, var pn = nodes[p] {
                var kids = pn["childrenIds"] as? [String] ?? []
                if !kids.contains(m.id) { kids.append(m.id) }
                pn["childrenIds"] = kids
                nodes[p] = pn
            }
            nodes[m.id] = node
            parent = m.id
        }
        history["messages"] = nodes
        history["currentId"] = parent ?? NSNull()
        chat["history"] = history

        // Flat list = the active branch, exactly what the web UI itself stores.
        var chain: [[String: Any]] = []
        var walk = parent
        var guardCount = 0
        while let w = walk, let n = nodes[w], guardCount < 10_000 {
            chain.append(n)
            walk = n["parentId"] as? String
            guardCount += 1
        }
        if !chain.isEmpty { chat["messages"] = Array(chain.reversed()) }

        if ((chat["models"] as? [String])?.isEmpty ?? true) { chat["models"] = [model] }

        var req = request("/api/v1/chats/\(encPath(id))", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["chat": chat])
        _ = try await send(req)
    }
}
