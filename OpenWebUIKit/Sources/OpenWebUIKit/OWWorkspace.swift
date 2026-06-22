import Foundation

/// A generic workspace item (knowledge base, prompt, tool, function). Decoded
/// tolerantly so the different shapes (name/title/command, meta.description)
/// all map to a common id/name/description.
public struct OWNamedItem: Decodable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var description: String?

    enum CodingKeys: String, CodingKey { case id, name, title, command, description, meta }
    struct Meta: Decodable { var description: String? }

    public init(id: String, name: String, description: String? = nil) {
        self.id = id; self.name = name; self.description = description
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let command = try? c.decodeIfPresent(String.self, forKey: .command)
        if let s = try? c.decode(String.self, forKey: .id) { id = s }
        else if let i = try? c.decode(Int.self, forKey: .id) { id = String(i) }
        else { id = command ?? UUID().uuidString }
        name = (try? c.decodeIfPresent(String.self, forKey: .name)).flatMap { $0 }
            ?? (try? c.decodeIfPresent(String.self, forKey: .title)).flatMap { $0 }
            ?? command ?? id
        let meta = try? c.decodeIfPresent(Meta.self, forKey: .meta)
        description = (try? c.decodeIfPresent(String.self, forKey: .description)).flatMap { $0 }
            ?? meta?.description
    }
}

extension OpenWebUIClient {
    /// GET /api/v1/knowledge/ → `{ items: [...] }`.
    public func knowledgeBases() async throws -> [OWNamedItem] {
        decodeList(OWNamedItem.self, try await send(request("/api/v1/knowledge/")))
    }
    /// GET /api/v1/prompts/ → `[...]`.
    public func prompts() async throws -> [OWNamedItem] {
        decodeList(OWNamedItem.self, try await send(request("/api/v1/prompts/")))
    }
    /// GET /api/v1/tools/ → `[...]`.
    public func tools() async throws -> [OWNamedItem] {
        decodeList(OWNamedItem.self, try await send(request("/api/v1/tools/")))
    }
    /// GET /api/v1/functions/ → `[...]`.
    public func functions() async throws -> [OWNamedItem] {
        decodeList(OWNamedItem.self, try await send(request("/api/v1/functions/")))
    }
}
