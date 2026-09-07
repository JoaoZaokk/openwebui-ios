import Foundation

// Native Open WebUI chat actions: pin, archive, clone, rename, share, export.
// (delete is on OpenWebUIClient already.)
extension OpenWebUIClient {

    /// POST /api/v1/chats/{id}/pin — toggles the pinned flag.
    public func pinChat(_ id: String) async throws {
        _ = try await send(request("/api/v1/chats/\(encPath(id))/pin", method: "POST"))
    }

    /// POST /api/v1/chats/{id}/archive — toggles archived. Calling it again on an
    /// archived chat unarchives it (that's how the web UI restores).
    public func archiveChat(_ id: String) async throws {
        _ = try await send(request("/api/v1/chats/\(encPath(id))/archive", method: "POST"))
    }

    /// GET /api/v1/chats/archived — the user's archived chats (id / title / dates),
    /// so an "Archived" screen can restore or delete them.
    public func archivedChats() async throws -> [OWChatSummary] {
        try decodeList(OWChatSummary.self, try await send(request("/api/v1/chats/archived")))
    }

    /// POST /api/v1/chats/{id}/clone — duplicates the chat; returns the new id.
    @discardableResult
    public func cloneChat(_ id: String) async throws -> String {
        var req = request("/api/v1/chats/\(encPath(id))/clone", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        struct R: Decodable { var id: String }
        return try decode(R.self, try await send(req)).id
    }

    /// Renames a chat.
    ///
    /// On 0.11+ this is a one-request partial patch: the server merges top-level
    /// keys (`{**stored, **chat}`) and only bumps `updated_at` when the write
    /// carries `history` or `messages`, so a rename no longer jumps the chat to the
    /// top of the list. It also means the rename stops round-tripping the whole
    /// conversation — which mattered, because 0.11 overlays any reply still being
    /// streamed onto the chat it hands back, and sending that back froze the
    /// truncated text into the database.
    ///
    /// Older servers replace the blob wholesale, so there the only safe rename is
    /// still fetch → patch title → save.
    public func renameChat(_ id: String, to title: String) async throws {
        await ensureServerInfo()
        if mergesHistoryServerSide {
            let req = try jsonRequest("/api/v1/chats/\(encPath(id))", method: "POST",
                                      body: ["chat": ["title": title]])
            _ = try await send(req)
            return
        }
        let data = try await send(request("/api/v1/chats/\(encPath(id))"))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var chat = obj["chat"] as? [String: Any] else { throw OWError.decoding("chat") }
        chat["title"] = title
        var req = request("/api/v1/chats/\(encPath(id))", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["chat": chat])
        _ = try await send(req)
    }

    /// POST /api/v1/chats/{id}/share — returns the public share URL ( /s/{id} ).
    public func shareChat(_ id: String) async throws -> URL? {
        let data = try await send(request("/api/v1/chats/\(encPath(id))/share", method: "POST"))
        struct R: Decodable { var share_id: String? }
        if let sid = (try? JSONDecoder().decode(R.self, from: data))?.share_id, !sid.isEmpty {
            return config.url("/s/\(encPath(sid))")
        }
        return nil
    }

    /// DELETE /api/v1/chats/{id}/share — revokes the public share link.
    public func unshareChat(_ id: String) async throws {
        _ = try await send(request("/api/v1/chats/\(encPath(id))/share", method: "DELETE"))
    }

    /// GET /api/v1/chats/{id} — the full chat JSON, for "download / export".
    public func exportChat(_ id: String) async throws -> Data {
        try await send(request("/api/v1/chats/\(encPath(id))"))
    }

    // MARK: - The server names the conversation

    /// POST /api/v1/tasks/title/completions — asks the server to name a chat.
    ///
    /// This is the web client's own call, and the point is that nothing here
    /// decides the words: the server picks the task model, fills the admin's
    /// title template, and answers 200 `{"detail": "Title generation is
    /// disabled"}` when the admin switched the feature off. `model` is the
    /// chat's model — the server only falls back to it when no task model is set.
    ///
    /// The default template reads `{{MESSAGES:END:2}}`, so only the LAST TWO of
    /// `messages` are sent, as plain `{role, content}` text: image parts are
    /// dropped, and an image-only user turn goes as an empty string — the reply
    /// that answered it carries the topic.
    ///
    /// Returns nil when the server declined to name the chat (disabled, or an
    /// answer with no `{…}` title object in it). There is no local fallback: nil
    /// means keep whatever title the chat already has.
    public func generateTitle(model: String, messages: [OWChatMessageInput],
                              chatID: String?) async throws -> String? {
        let turn = messages.suffix(2).map { OWTitleTaskBody.Message(role: $0.role, content: $0.text) }
        let body = OWTitleTaskBody(model: model, messages: Array(turn), chat_id: chatID)
        let req = try jsonRequest("/api/v1/tasks/title/completions", method: "POST", body: body)
        return Self.title(fromTaskResponse: try await send(req))
    }

    /// The web client's parser (`src/lib/apis/index.ts`, `generateTitle`), pure so
    /// it can be tested without a server.
    ///
    /// The default template asks the task model for a raw JSON object
    /// `{ "title": "…" }`, and models wrap it in prose, in a ```json fence, in
    /// single quotes, or behind a `<think>` block. So: normalize the quote
    /// characters, take the span from the first `{` to the last `}`, parse that,
    /// and read `title`. Anything else — the "disabled" body, plain prose, a
    /// different object, an empty title — is nil. Deliberately no plain-text
    /// fallback: a model that ignored the template must not have its prose
    /// installed as the chat's name.
    public static func title(fromTaskResponse data: Data) -> String? {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { var content: String? }
                var message: Message?
            }
            var choices: [Choice]?
        }
        guard let raw = (try? JSONDecoder().decode(Response.self, from: data))?
            .choices?.first?.message?.content else { return nil }

        var content = raw
        for quote in ["'", "\u{2018}", "\u{2019}", "`"] {
            content = content.replacingOccurrences(of: quote, with: "\"")
        }
        guard let open = content.firstIndex(of: "{"),
              let close = content.lastIndex(of: "}"), open < close else { return nil }
        let object = String(content[open...close])
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(object.utf8)),
              let title = (parsed as? [String: Any])?["title"] as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return title
    }
}

/// The body of a title task. `chat_id` is optional server-side, and the
/// synthesized encoder omits it when nil — which is what a chat that is not
/// saved yet needs.
struct OWTitleTaskBody: Encodable {
    var model: String
    var messages: [Message]
    var chat_id: String?

    /// Plain text only: the task endpoint feeds these into a string template, so
    /// an OpenAI-style parts array would reach the task model as gibberish.
    struct Message: Encodable {
        var role: String
        var content: String
    }
}
