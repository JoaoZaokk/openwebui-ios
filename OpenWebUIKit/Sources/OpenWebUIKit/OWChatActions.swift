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
        decodeList(OWChatSummary.self, try await send(request("/api/v1/chats/archived")))
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

    /// Renames a chat, preserving everything else (fetch → patch title → save).
    public func renameChat(_ id: String, to title: String) async throws {
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
}
