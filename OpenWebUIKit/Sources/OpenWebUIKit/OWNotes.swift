import Foundation

// Notes API (/api/v1/notes). Verified against live 0.9.6:
//   GET  /api/v1/notes/            → [ {id,title,data{content{md}},is_pinned,updated_at,created_at} ]
//   GET  /api/v1/notes/{id}        → full note
//   POST /api/v1/notes/create      body {title, data:{content:{md}}}
//   POST /api/v1/notes/{id}/update body {title, data:{content:{md}}}   (NO access_control → 400)
//   DELETE /api/v1/notes/{id}/delete
// Timestamps come back in NANOSECONDS.

/// One entry of a note's sharing list. The server reads exactly these four keys
/// back (`normalize_access_grants`), so round-tripping a grant is lossless.
public struct OWAccessGrant: Codable, Hashable, Sendable {
    public var id: String?
    public var principal_type: String
    public var principal_id: String
    public var permission: String
}

public struct OWNote: Decodable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var markdown: String
    public var pinned: Bool
    public var updatedAt: Double?   // normalized to seconds
    public var createdAt: Double?
    /// Who this note is shared with. Carried only so an edit can hand it straight
    /// back — see `updateNote`.
    public var accessGrants: [OWAccessGrant]?

    enum CodingKeys: String, CodingKey {
        case id, title, data, is_pinned, updated_at, created_at, access_grants
    }
    struct DataBox: Decodable { struct Content: Decodable { var md: String? }; var content: Content? }

    public init(id: String, title: String, markdown: String, pinned: Bool = false,
                updatedAt: Double? = nil, createdAt: Double? = nil) {
        self.id = id; self.title = title; self.markdown = markdown; self.pinned = pinned
        self.updatedAt = updatedAt; self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        title = (try? c.decode(String.self, forKey: .title)).flatMap { $0.isEmpty ? nil : $0 } ?? L("Sem título")
        let box = try? c.decode(DataBox.self, forKey: .data)
        markdown = box?.content?.md ?? ""
        pinned = (try? c.decode(Bool.self, forKey: .is_pinned)) ?? false
        updatedAt = OWNote.seconds(try? c.decode(Double.self, forKey: .updated_at))
        createdAt = OWNote.seconds(try? c.decode(Double.self, forKey: .created_at))
        accessGrants = try? c.decode([OWAccessGrant].self, forKey: .access_grants)
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
    var access_grants: [OWAccessGrant]?
    struct DataBox: Encodable { var content: Content; struct Content: Encodable { var md: String } }
    init(title: String, markdown: String, accessGrants: [OWAccessGrant]? = nil) {
        self.title = title
        self.data = DataBox(content: .init(md: markdown))
        self.access_grants = accessGrants
    }
}

extension OpenWebUIClient {
    public func notes() async throws -> [OWNote] {
        try decodeList(OWNote.self, try await send(request("/api/v1/notes/")))
    }

    public func note(_ id: String) async throws -> OWNote {
        try decode(OWNote.self, try await send(request("/api/v1/notes/\(encPath(id))")))
    }

    @discardableResult
    public func createNote(title: String, markdown: String) async throws -> OWNote {
        let req = try jsonRequest("/api/v1/notes/create", method: "POST",
                                  body: OWNoteForm(title: title, markdown: markdown))
        return try decode(OWNote.self, try await send(req))
    }

    /// Saves a note's title and body **and hands its sharing list straight back**.
    ///
    /// This takes the whole note rather than an id on purpose. The update route
    /// runs the incoming `access_grants` through `filter_allowed_access_grants`
    /// and assigns the result onto the form — which marks the field as set even
    /// when the client never sent it, so `exclude_unset` no longer hides it and
    /// `set_access_grants` deletes every grant on the note and re-inserts nothing
    /// (backend routers/notes.py:557, models/notes.py:361, models/access_grants.py:454).
    /// Editing a shared note from the app therefore un-shared it from everyone.
    /// Echoing the grants back is what keeps them.
    public func updateNote(_ note: OWNote, title: String, markdown: String) async throws {
        let req = try jsonRequest("/api/v1/notes/\(encPath(note.id))/update", method: "POST",
                                  body: OWNoteForm(title: title, markdown: markdown,
                                                   accessGrants: note.accessGrants))
        _ = try await send(req)
    }

    public func deleteNote(_ id: String) async throws {
        _ = try await send(request("/api/v1/notes/\(encPath(id))/delete", method: "DELETE"))
    }
}
