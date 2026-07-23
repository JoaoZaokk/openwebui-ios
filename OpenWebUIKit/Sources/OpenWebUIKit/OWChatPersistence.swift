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

    /// Tree-preserving initializer for branching edits. Writes EVERY node (so
    /// sibling branches survive), computes each node's `childrenIds` from the
    /// parent links, and sets the flat `messages` array to the active branch
    /// (currentId → root). Unlike the linear init above this never collapses the
    /// tree, so it can't clobber branches created elsewhere.
    init(title: String, models: [String], tree nodes: [OWMessage], currentId: String?) {
        self.title = title
        self.models = models
        self.params = [:]
        self.tags = []
        let now = Int(Date().timeIntervalSince1970)
        self.timestamp = now * 1000
        let fallbackModel = models.first ?? ""

        // children of each node, ordered oldest→newest (the branch order the UI shows).
        var childrenOf: [String: [OWMessage]] = [:]
        for n in nodes {
            if let p = n.parentId { childrenOf[p, default: []].append(n) }
        }
        for k in childrenOf.keys {
            childrenOf[k]?.sort { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
        }

        var map: [String: Msg] = [:]
        for n in nodes {
            let isUser = (n.role == .user)
            let atts = n.imageURLs.map { OWAttachment(type: "image", url: $0) } + n.documents
            map[n.id] = Msg(
                id: n.id,
                role: n.role.rawValue,
                content: n.content,
                timestamp: n.timestamp.map { Int($0) } ?? now,
                model: isUser ? nil : (n.model ?? fallbackModel),
                modelName: isUser ? nil : (n.model ?? fallbackModel),
                parentId: n.parentId,
                childrenIds: (childrenOf[n.id] ?? []).map(\.id),
                files: atts.isEmpty ? nil : atts
            )
        }

        // Active branch = walk currentId up to the root, then reverse.
        var branch: [Msg] = []
        var id = currentId
        var guardCount = 0
        while let i = id, let m = map[i], guardCount < 10_000 {
            branch.append(m); id = m.parentId; guardCount += 1
        }
        self.messages = branch.reversed()
        self.history = History(messages: map, currentId: currentId)
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
    public func updateChat(id: String, title: String, model: String, messages: [OWMessage]) async throws {
        let payload = OWChatPayload(title: title, model: model, messages: messages)
        let req = try jsonRequest("/api/v1/chats/\(encPath(id))", method: "POST", body: ["chat": payload])
        _ = try await send(req)
    }

    /// Creates a new chat from a full history tree (branch-preserving). Returns the id.
    public func createChatTree(title: String, models: [String],
                               tree: [OWMessage], currentId: String?) async throws -> String {
        let payload = OWChatPayload(title: title, models: models, tree: tree, currentId: currentId)
        let req = try jsonRequest("/api/v1/chats/new", method: "POST", body: ["chat": payload])
        struct R: Decodable { var id: String }
        return try decode(R.self, try await send(req)).id
    }

    /// Replaces a chat with a full history tree — writes every node, so sibling
    /// branches survive. Use this (not `updateChat`) for edit/regenerate flows.
    public func updateChatTree(id: String, title: String, models: [String],
                               tree: [OWMessage], currentId: String?) async throws {
        let payload = OWChatPayload(title: title, models: models, tree: tree, currentId: currentId)
        let req = try jsonRequest("/api/v1/chats/\(encPath(id))", method: "POST", body: ["chat": payload])
        _ = try await send(req)
    }
}
