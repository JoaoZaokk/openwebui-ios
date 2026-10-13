import Foundation

// MARK: - Questions under an answer (issue #15)

extension OpenWebUIClient {

    /// POST /api/v1/tasks/follow_up/completions — asks the server for the
    /// questions to offer under the reply that ends `messages`.
    ///
    /// The twin of `generateTitle`: the server picks the task model and fills
    /// the admin's template, and an admin who switched the feature off gets 200
    /// `{"detail": "Follow-up generation is disabled"}` — an empty list here,
    /// not an error. The default template reads `{{MESSAGES:END:6}}`, so only
    /// the last six messages go, as plain `{role, content}` text.
    public func generateFollowUps(model: String, messages: [OWChatMessageInput],
                                  chatID: String?) async throws -> [String] {
        let turn = messages.suffix(6).map { OWTaskBody.Message(role: $0.role, content: $0.text) }
        let body = OWTaskBody(model: model, messages: Array(turn), chat_id: chatID)
        let req = try jsonRequest("/api/v1/tasks/follow_up/completions", method: "POST", body: body)
        return Self.followUps(fromTaskResponse: try await send(req))
    }

    /// Keeps the questions on the reply's history node as `followUps`, where the
    /// server's own background task and the web client put them — so the chat
    /// shows them again when it is reopened, here or on the web.
    ///
    /// `POST /chats/{id}/messages/{mid}` only takes `content`, so this is a chat
    /// write, and the node goes back whole: the server's merge replaces each
    /// node it is sent (`{**existing, **incoming}`), so a node holding only
    /// `followUps` would erase the reply. The node is the server's own copy,
    /// never re-encoded from `OWMessage`, which drops `output`, usage and the
    /// rest. A reply someone else is still streaming, or one the server does
    /// not have, is not written.
    public func saveFollowUps(_ followUps: [String], replyID: String, chatID: String) async throws {
        await ensureServerInfo()
        let data = try await send(request("/api/v1/chats/\(encPath(chatID))"))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chat = obj["chat"] as? [String: Any] else { throw OWError.decoding("chat") }
        guard let outgoing = Self.chat(writing: followUps, on: replyID, in: chat,
                                       partial: mergesHistoryServerSide) else { return }
        var req = request("/api/v1/chats/\(encPath(chatID))", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["chat": outgoing])
        _ = try await send(req)
    }

    /// What `saveFollowUps` posts as `chat`, or nil when nothing should be.
    ///
    /// `partial` (0.11+, which merges `history` by id and keeps keys it is not
    /// sent): the reply node alone, under `history.messages`. Otherwise the
    /// server replaces the blob, so the whole chat goes back with the list on
    /// both copies of the reply — the graph node and the flat `messages` entry.
    static func chat(writing followUps: [String], on replyID: String,
                     in chat: [String: Any], partial: Bool) -> [String: Any]? {
        var history = chat["history"] as? [String: Any] ?? [:]
        var nodes = history["messages"] as? [String: [String: Any]] ?? [:]
        guard var node = nodes[replyID], (node["done"] as? Bool) != false else { return nil }
        node["followUps"] = followUps
        if partial {
            return ["history": ["messages": [replyID: node]]]
        }
        nodes[replyID] = node
        history["messages"] = nodes
        var whole = chat
        whole["history"] = history
        if var flat = whole["messages"] as? [[String: Any]] {
            for i in flat.indices where flat[i]["id"] as? String == replyID {
                flat[i]["followUps"] = followUps
            }
            whole["messages"] = flat
        }
        return whole
    }

    /// The server's own parser for a follow-up task answer
    /// (`utils/middleware.py`, the background `follow_up_generation` task), pure
    /// so it can be tested without a server.
    ///
    /// The text is `content`, or `reasoning_content` when a reasoning model left
    /// `content` empty; the span from the first `{` to the last `}` is parsed and
    /// `follow_ups` read from it. Anything else — the "disabled" body, prose, a
    /// different object — is no suggestions.
    ///
    /// Unlike `title(fromTaskResponse:)` the quotes are left alone: titles come
    /// back as single-quoted pseudo-JSON, but questions are full of apostrophes,
    /// and turning "What's" into `What"s` would make the whole object unreadable.
    public static func followUps(fromTaskResponse data: Data) -> [String] {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { var content: String?; var reasoning_content: String? }
                var message: Message?
            }
            var choices: [Choice]?
        }
        guard let message = (try? JSONDecoder().decode(Response.self, from: data))?
            .choices?.first?.message else { return [] }
        let content = message.content ?? ""
        let text = content.isEmpty ? (message.reasoning_content ?? "") : content
        guard let open = text.firstIndex(of: "{"),
              let close = text.lastIndex(of: "}"), open < close,
              let parsed = try? JSONSerialization.jsonObject(with: Data(text[open...close].utf8)),
              let list = (parsed as? [String: Any])?["follow_ups"] as? [Any] else { return [] }
        return list.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
