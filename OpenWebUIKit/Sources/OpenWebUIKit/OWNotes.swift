import Foundation

// Notes API (/api/v1/notes). Verified against live 0.9.6:
//   GET  /api/v1/notes/            → [ {id,title,data{content{md}},is_pinned,updated_at,created_at} ]
//   GET  /api/v1/notes/{id}        → full note
//   POST /api/v1/notes/create      body {title, data:{content:{md}}}
//   POST /api/v1/notes/{id}/update body {title, data:{content:{md}}}   (NO access_control → 400)
//   DELETE /api/v1/notes/{id}/delete
// Timestamps come back in NANOSECONDS.

public struct OWNote: Decodable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var markdown: String
    public var pinned: Bool
    public var updatedAt: Double?   // normalized to seconds
    public var createdAt: Double?

    enum CodingKeys: String, CodingKey { case id, title, data, is_pinned, updated_at, created_at }
    struct DataBox: Decodable { struct Content: Decodable { var md: String? }; var content: Content? }

    public init(id: String, title: String, markdown: String, pinned: Bool = false,
                updatedAt: Double? = nil, createdAt: Double? = nil) {
        self.id = id; self.title = title; self.markdown = markdown; self.pinned = pinned
        self.updatedAt = updatedAt; self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        title = (try? c.decode(String.self, forKey: .title)).flatMap { $0.isEmpty ? nil : $0 } ?? "Sem título"
        let box = try? c.decode(DataBox.self, forKey: .data)
        markdown = box?.content?.md ?? ""
        pinned = (try? c.decode(Bool.self, forKey: .is_pinned)) ?? false
        updatedAt = OWNote.seconds(try? c.decode(Double.self, forKey: .updated_at))
        createdAt = OWNote.seconds(try? c.decode(Double.self, forKey: .created_at))
    }

    /// Open WebUI note timestamps are nanosecond epoch; normalize to seconds.
    static func seconds(_ v: Double?) -> Double? {
        guard let v else { return nil }
        return v > 1e14 ? v / 1e9 : v
    }
}

struct OWNoteForm: Encodable {
    var title: String
    var data: DataBox
    struct DataBox: Encodable { var content: Content; struct Content: Encodable { var md: String } }
    init(title: String, markdown: String) {
        self.title = title
        self.data = DataBox(content: .init(md: markdown))
    }
}

extension OpenWebUIClient {
    public func notes() async throws -> [OWNote] {
        decodeList(OWNote.self, try await send(request("/api/v1/notes/")))
    }

    public func note(_ id: String) async throws -> OWNote {
        try decode(OWNote.self, try await send(request("/api/v1/notes/\(id)")))
    }

    @discardableResult
    public func createNote(title: String, markdown: String) async throws -> OWNote {
        let req = try jsonRequest("/api/v1/notes/create", method: "POST",
                                  body: OWNoteForm(title: title, markdown: markdown))
        return try decode(OWNote.self, try await send(req))
    }

    public func updateNote(id: String, title: String, markdown: String) async throws {
        let req = try jsonRequest("/api/v1/notes/\(id)/update", method: "POST",
                                  body: OWNoteForm(title: title, markdown: markdown))
        _ = try await send(req)
    }

    public func deleteNote(_ id: String) async throws {
        _ = try await send(request("/api/v1/notes/\(id)/delete", method: "DELETE"))
    }
}
