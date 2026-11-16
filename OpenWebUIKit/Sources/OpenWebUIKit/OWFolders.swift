import Foundation

/// A folder of conversations (Open WebUI "Pastas"; 0.13 also calls them projects
/// in its UI). What the app reads of one: a name, where it sits, and the
/// instruction every chat inside it starts from.
///
/// The server's wire shape, measured on 0.13.3:
/// - `GET  /api/v1/folders/`          the list — **without** `data`, so no instruction.
/// - `GET  /api/v1/folders/{id}`      one folder, with `data.system_prompt`.
/// - `POST /api/v1/folders/`          `{name, parent_id?}`.
/// - `POST /api/v1/folders/{id}/update` `{name, data}` — `data` replaces the stored one.
/// - `DELETE /api/v1/folders/{id}`.
/// - `POST /api/v1/chats/{id}/folder` `{folder_id}`; `null` takes the chat out.
/// - `GET  /api/v1/chats/folder/{id}` the chats inside. The main chat list leaves
///   them out, so a chat moved into a folder disappears from it, as on the web.
/// - `folder_id` in the `/api/chat/completions` body makes the server prepend the
///   folder's instruction (answered "banana" to a folder that said so).
public struct OWFolder: Decodable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var parentID: String?
    /// The instruction chats in this folder start from. Only the by-id route
    /// carries it; the list leaves it nil.
    public var systemPrompt: String?

    enum CodingKeys: String, CodingKey { case id, name, parent_id, data }
    private struct Data: Decodable { var system_prompt: String? }

    public init(id: String, name: String, parentID: String? = nil, systemPrompt: String? = nil) {
        self.id = id; self.name = name; self.parentID = parentID; self.systemPrompt = systemPrompt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        parentID = try? c.decode(String?.self, forKey: .parent_id)
        let prompt = (try? c.decode(Data.self, forKey: .data))?.system_prompt
        systemPrompt = prompt.flatMap { $0.isEmpty ? nil : $0 }
    }
}

extension OpenWebUIClient {
    /// All folders, top level and nested, in the order the server keeps them. A
    /// server without folders (404) is an empty list, not a failure: the section
    /// simply does not draw.
    public func folders() async throws -> [OWFolder] {
        do {
            let data = try await send(request("/api/v1/folders/"))
            return try decodeList(OWFolder.self, data)
        } catch OWError.http(let status, _) where status == 404 || status == 405 {
            return []
        }
    }

    /// One folder with its instruction.
    public func folder(_ id: String) async throws -> OWFolder {
        try decode(OWFolder.self, try await send(request("/api/v1/folders/\(encPath(id))")))
    }

    @discardableResult
    public func createFolder(name: String, parentID: String? = nil) async throws -> OWFolder {
        struct Body: Encodable { var name: String; var parent_id: String? }
        let req = try jsonRequest("/api/v1/folders/", method: "POST",
                                  body: Body(name: name, parent_id: parentID))
        return try decode(OWFolder.self, try await send(req))
    }

    /// Renames the folder and sets its instruction in one call. `data` is replaced
    /// whole by the server, so an empty instruction is sent as an empty object
    /// rather than left out (which would keep the old one).
    @discardableResult
    public func updateFolder(_ id: String, name: String, systemPrompt: String) async throws -> OWFolder {
        struct Body: Encodable { var name: String; var data: Prompt }
        struct Prompt: Encodable {
            var system_prompt: String?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: Keys.self)
                if let p = system_prompt, !p.isEmpty { try c.encode(p, forKey: .system_prompt) }
            }
            enum Keys: String, CodingKey { case system_prompt }
        }
        let trimmed = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let req = try jsonRequest("/api/v1/folders/\(encPath(id))/update", method: "POST",
                                  body: Body(name: name, data: Prompt(system_prompt: trimmed)))
        return try decode(OWFolder.self, try await send(req))
    }

    public func deleteFolder(_ id: String) async throws {
        _ = try await send(request("/api/v1/folders/\(encPath(id))", method: "DELETE"))
    }

    /// Puts a chat in a folder, or takes it out with `nil`.
    public func moveChat(_ chatID: String, toFolder folderID: String?) async throws {
        struct Body: Encodable {
            var folder_id: String?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: Keys.self)
                try c.encode(folder_id, forKey: .folder_id)   // `null` must be written: it is the request
            }
            enum Keys: String, CodingKey { case folder_id }
        }
        let req = try jsonRequest("/api/v1/chats/\(encPath(chatID))/folder", method: "POST",
                                  body: Body(folder_id: folderID))
        _ = try await send(req)
    }

    /// The chats inside one folder, as list rows.
    public func chats(inFolder id: String) async throws -> [OWChatSummary] {
        let data = try await send(request("/api/v1/chats/folder/\(encPath(id))"))
        return try decodeList(OWChatSummary.self, data).map { var c = $0; c.folderID = id; return c }
    }
}
