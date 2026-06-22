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
        let req = try jsonRequest("/api/v1/chats/\(id)", method: "POST", body: ["chat": payload])
        _ = try await send(req)
    }
}
