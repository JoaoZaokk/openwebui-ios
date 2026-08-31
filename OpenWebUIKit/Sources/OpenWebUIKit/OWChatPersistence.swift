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
    /// Ids of replies the server is still writing.
    ///
    /// Open WebUI 0.11 overlays the live state of any in-flight reply — one the
    /// web UI or another device is generating right now — onto the chat it hands
    /// back: partial `content`, `output: []`, `done: false`
    /// (`overlay_response_streams`, backend routers/chats.py:62). This client
    /// re-sends every node it did not create byte for byte, and the server's merge
    /// is `{**existing, **incoming}` (backend models/chats.py:894) — so writing an
    /// overlaid node back pins the truncated text into the database and leaves the
    /// row `done = false` for good, which also makes `POST /{id}/fork` 409 forever.
    /// Omitting the id keeps the server's own copy. Every node this client writes
    /// carries `done: true`, so "not done" is exactly "someone else owns it".
    static func inFlightIDs(_ nodes: [String: [String: Any]]) -> Set<String> {
        Set(nodes.filter { ($0.value["done"] as? Bool) == false }.keys)
    }

    /// Writes the merged graph back into `chat`, minus the nodes someone else is
    /// still streaming. When any node is withheld the flat `messages` projection is
    /// dropped from the payload too: the server replaces that key wholesale
    /// (`{**stored, **chat}`) and rebuilds it itself once the stream lands, whereas
    /// only `history` gets the id-wise merge that makes withholding safe.
    ///
    /// `inFlight` must be empty unless `mergesHistoryServerSide` — on a server that
    /// replaces the blob, omitting a node deletes it.
    static func store(history: inout [String: Any], nodes: [String: [String: Any]],
                      currentId: String?, chat: inout [String: Any],
                      chain: [[String: Any]], inFlight: Set<String>) {
        var outgoing = nodes
        for id in inFlight { outgoing.removeValue(forKey: id) }
        history["messages"] = outgoing
        history["currentId"] = currentId ?? NSNull()
        chat["history"] = history
        if inFlight.isEmpty {
            if !chain.isEmpty { chat["messages"] = Array(chain.reversed()) }
        } else {
            chat.removeValue(forKey: "messages")
        }
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
        await ensureServerInfo()
        let data = try await send(request("/api/v1/chats/\(encPath(id))"))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var chat = obj["chat"] as? [String: Any] else { throw OWError.decoding("chat") }

        var history = chat["history"] as? [String: Any] ?? [:]
        var nodes = history["messages"] as? [String: [String: Any]] ?? [:]
        // Legacy/empty graph: seed it from the flat list so linking still works.
        if nodes.isEmpty, let flat = chat["messages"] as? [[String: Any]] {
            for m in flat { if let mid = m["id"] as? String { nodes[mid] = m } }
        }
        // Read this before adding ours: everything we add is already done.
        let inFlight = mergesHistoryServerSide ? Self.inFlightIDs(nodes) : []

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
        // Flat list = the active branch, exactly what the web UI itself stores.
        var chain: [[String: Any]] = []
        var walk = parent
        var guardCount = 0
        while let w = walk, let n = nodes[w], guardCount < 10_000 {
            chain.append(n)
            walk = n["parentId"] as? String
            guardCount += 1
        }
        Self.store(history: &history, nodes: nodes, currentId: parent,
                   chat: &chat, chain: chain, inFlight: inFlight)

        if ((chat["models"] as? [String])?.isEmpty ?? true) { chat["models"] = [model] }

        var req = request("/api/v1/chats/\(encPath(id))", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["chat": chat])
        _ = try await send(req)
    }
}

// MARK: - Branching writes (edit / regenerate / retry)

extension OpenWebUIClient {
    /// Folds a local history tree into a raw server `chat` dict.
    ///
    /// The rule is the same one `syncChat` follows and the reason this exists at
    /// all: **a node the server already knows is never re-encoded.** Round-tripping
    /// an existing node through `OWMessage` would silently drop every field this
    /// client doesn't model — `output`, `sources`, `statusHistory`, usage, tool
    /// calls — and an edit deep in a conversation would strip them from the whole
    /// history, not just the edited turn.
    ///
    /// What this adds over `syncChat` is shape rather than a tail: new nodes keep
    /// their own `parentId`, `childrenIds` is recomputed across the merged set (a
    /// derived field — a stale list from either side hides a branch in the web UI),
    /// and `currentId` moves to the leaf the app is showing.
    ///
    /// Returns false when nothing changed, so switching to a branch that is already
    /// current doesn't cost a write.
    static func mergeTree(into chat: inout [String: Any],
                          tree: [OWMessage], currentId leaf: String?,
                          model: String, withholdInFlight: Bool = false) -> Bool {
        var history = chat["history"] as? [String: Any] ?? [:]
        var nodes = history["messages"] as? [String: [String: Any]] ?? [:]
        // Legacy/empty graph: seed it from the flat list so linking still works.
        if nodes.isEmpty, let flat = chat["messages"] as? [[String: Any]] {
            for m in flat { if let mid = m["id"] as? String { nodes[mid] = m } }
        }

        // Read this before adding ours: everything we add is already done.
        let inFlight = withholdInFlight ? Self.inFlightIDs(nodes) : []

        let now = Int(Date().timeIntervalSince1970)
        var added = false
        for m in tree where nodes[m.id] == nil {
            var node = OWChatPayload.node(for: m, model: model, now: now)
            node["parentId"] = m.parentId ?? NSNull()
            nodes[m.id] = node
            added = true
        }

        let previousLeaf = history["currentId"] as? String
        let newLeaf = leaf.flatMap { nodes[$0] != nil ? $0 : nil } ?? previousLeaf
        guard added || newLeaf != previousLeaf else { return false }

        // childrenIds is derived, never trusted: oldest child first, which is the
        // order the branch switcher counts through.
        var childrenOf: [String: [String]] = [:]
        let ordered = nodes.sorted {
            ($0.value["timestamp"] as? Int ?? 0, $0.key) < ($1.value["timestamp"] as? Int ?? 0, $1.key)
        }
        for (nid, n) in ordered {
            if let p = n["parentId"] as? String { childrenOf[p, default: []].append(nid) }
        }
        for key in nodes.keys { nodes[key]?["childrenIds"] = childrenOf[key] ?? [] }

        // Flat list = the active branch, exactly what the web UI itself stores.
        var chain: [[String: Any]] = []
        var walk = newLeaf
        var guardCount = 0
        while let w = walk, let n = nodes[w], guardCount < 10_000 {
            chain.append(n)
            walk = n["parentId"] as? String
            guardCount += 1
        }
        store(history: &history, nodes: nodes, currentId: newLeaf,
              chat: &chat, chain: chain, inFlight: inFlight)
        return true
    }

    /// Creates a new chat from a history tree. Returns the new chat id.
    public func createChatTree(title: String, models: [String],
                               tree: [OWMessage], currentId: String?) async throws -> String {
        var chat: [String: Any] = [
            "title": title,
            "models": models,
            "params": [String: String](),
            "tags": [String](),
            "timestamp": Int(Date().timeIntervalSince1970) * 1000,
        ]
        _ = Self.mergeTree(into: &chat, tree: tree, currentId: currentId, model: models.first ?? "")

        var req = request("/api/v1/chats/new", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["chat": chat])
        struct R: Decodable { var id: String }
        return try decode(R.self, try await send(req)).id
    }

    /// Merge-safe save for a branching history — the tree counterpart of `syncChat`,
    /// and the only write path the edit/regenerate flows may use. `updateChatTree`
    /// does not exist on purpose: replacing the chat wholesale is what destroys
    /// web-side data.
    public func syncChatTree(id: String, title: String, models: [String],
                             tree: [OWMessage], currentId: String?) async throws {
        await ensureServerInfo()
        let data = try await send(request("/api/v1/chats/\(encPath(id))"))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var chat = obj["chat"] as? [String: Any] else { throw OWError.decoding("chat") }

        let model = models.first ?? (chat["models"] as? [String])?.first ?? ""
        guard Self.mergeTree(into: &chat, tree: tree, currentId: currentId, model: model,
                             withholdInFlight: mergesHistoryServerSide) else { return }

        if !title.isEmpty { chat["title"] = title }
        if !models.isEmpty { chat["models"] = models }

        var req = request("/api/v1/chats/\(encPath(id))", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["chat": chat])
        _ = try await send(req)
    }
}
