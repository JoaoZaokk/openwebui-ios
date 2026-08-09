import Foundation

// Codable types mirroring the Open WebUI 0.9.6 REST API. All decoders are
// deliberately tolerant — unexpected/extra fields must never break the UI, and
// shapes shift a little between Open WebUI versions.

// MARK: - Auth

/// POST /api/v1/auths/signin  body: { email, password }
/// (Open WebUI signs in with email, not username.)
public struct OWSignInForm: Encodable, Sendable {
    public var email: String
    public var password: String
    public init(email: String, password: String) { self.email = email; self.password = password }
}

/// Signin response — carries the bearer token plus the user record.
public struct OWSession: Decodable, Sendable {
    public var token: String
    public var tokenType: String?
    public var id: String?
    public var email: String?
    public var name: String?
    public var role: String?
    public var profileImageURL: String?

    enum CodingKeys: String, CodingKey {
        case token
        case tokenType = "token_type"
        case id, email, name, role
        case profileImageURL = "profile_image_url"
    }
}

/// GET /api/v1/auths/ — the current user (used to validate a persisted token
/// on launch).
public struct OWUser: Decodable, Sendable, Identifiable {
    public var id: String
    public var email: String?
    public var name: String?
    public var role: String?
    public var profileImageURL: String?

    enum CodingKeys: String, CodingKey {
        case id, email, name, role
        case profileImageURL = "profile_image_url"
    }

    public init(id: String, email: String? = nil, name: String? = nil,
                role: String? = nil, profileImageURL: String? = nil) {
        self.id = id; self.email = email; self.name = name
        self.role = role; self.profileImageURL = profileImageURL
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        email = try? c.decodeIfPresent(String.self, forKey: .email)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        role = try? c.decodeIfPresent(String.self, forKey: .role)
        profileImageURL = try? c.decodeIfPresent(String.self, forKey: .profileImageURL)
    }

    /// Build a user from a signin response.
    public init(session s: OWSession) {
        self.init(id: s.id ?? s.email ?? "me", email: s.email, name: s.name,
                  role: s.role, profileImageURL: s.profileImageURL)
    }

    public var isAdmin: Bool { role == "admin" }
}

// MARK: - Models (LLMs)

/// One entry from GET /api/models (`{ data: [...] }`). Open WebUI returns
/// OpenAI-style model objects merged across every connected backend.
public struct OWModel: Decodable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var ownedBy: String?

    enum CodingKeys: String, CodingKey { case id, name, object, owned_by }

    public init(id: String, name: String, ownedBy: String? = nil) {
        self.id = id; self.name = name; self.ownedBy = ownedBy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = (try? c.decode(String.self, forKey: .id)) ?? ""
        id = rawID
        name = (try? c.decode(String.self, forKey: .name)) ?? rawID
        ownedBy = try? c.decodeIfPresent(String.self, forKey: .owned_by)
        if id.isEmpty { id = name }
    }

    /// Short label, e.g. "llama3.1:8b" stays, but "openai/gpt-4o" → "gpt-4o".
    public var shortName: String { name.split(separator: "/").last.map(String.init) ?? name }
}

// MARK: - Messages

public enum OWRole: String, Codable, Sendable {
    case user, assistant, system, tool

    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? "assistant"
        self = OWRole(rawValue: raw.lowercased()) ?? .assistant
    }
}

/// One element of a multimodal `content` array
/// (e.g. [{type:"text", text:"…"}, {type:"image_url", image_url:{url:"data:…"}}]).
struct OWContentPart: Decodable {
    var type: String?
    var text: String?
    var image_url: ImageURL?
    struct ImageURL: Decodable { var url: String? }
    var imageURL: String? { image_url?.url }
}

/// A `files` entry on a message (Open WebUI stores attached images as
/// {type:"image", url:"data:…"}).
struct OWFileRef: Decodable { var type: String?; var url: String? }

/// One item of the structured `output` array. Since Open WebUI 0.10 the server
/// persists assistant replies ONLY here — flat `content` stays "" — so we must
/// reconstruct the text or web-generated responses render empty.
struct OWOutputItem: Decodable {
    var type: String?
    var text: String?
    var parts: [Part]
    struct Part: Decodable { var type: String?; var text: String? }

    enum CodingKeys: String, CodingKey { case type, text, content }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        if let lossy = try? c.decode([OWLossy<Part>].self, forKey: .content) {
            parts = lossy.compactMap(\.value)
        } else if let s = try? c.decode(String.self, forKey: .content) {
            parts = [Part(type: "output_text", text: s)]
        } else {
            parts = []
        }
    }

    /// Flatten output items to displayable text ("message" items win; anything
    /// carrying text is the fallback so future item types degrade gracefully).
    static func flatten(_ items: [OWOutputItem]) -> String {
        let messages = items.filter { $0.type == "message" || $0.type == nil }
        let texts = messages.map { $0.parts.compactMap(\.text).joined() }.filter { !$0.isEmpty }
        if !texts.isEmpty { return texts.joined(separator: "\n\n") }
        return items.compactMap { $0.text ?? ($0.parts.compactMap(\.text).joined().isEmpty ? nil : $0.parts.compactMap(\.text).joined()) }
            .joined(separator: "\n\n")
    }
}

/// A web-search citation attached to an assistant message.
public struct OWWebSource: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var url: String?
    public var id: String { url ?? name }
    public init(name: String, url: String? = nil) { self.name = name; self.url = url }
}

/// One entry of the server's `sources` array (chat JSON and SSE frame share the
/// shape): { source: {name…}, document: […], metadata: [{source: <url>…}] }.
struct OWSourceEntry: Decodable {
    var source: Src?
    var metadata: [Meta]
    struct Src: Decodable { var name: String?; var url: String? }
    struct Meta: Decodable { var source: String? }

    enum CodingKeys: String, CodingKey { case source, metadata }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try? c.decodeIfPresent(Src.self, forKey: .source)
        metadata = ((try? c.decode([OWLossy<Meta>].self, forKey: .metadata)) ?? []).compactMap(\.value)
    }

    /// Distinct citations across all entries.
    static func webSources(_ entries: [OWSourceEntry]) -> [OWWebSource] {
        var out: [OWWebSource] = []
        var seen = Set<String>()
        for e in entries {
            let urls = e.metadata.compactMap(\.source).filter { $0.hasPrefix("http") }
            if urls.isEmpty {
                let u = e.source?.url ?? (e.source?.name?.hasPrefix("http") == true ? e.source?.name : nil)
                guard let n = e.source?.name ?? u, !n.isEmpty else { continue }
                if seen.insert(u ?? n).inserted { out.append(OWWebSource(name: n, url: u)) }
            } else {
                for u in urls where seen.insert(u).inserted {
                    out.append(OWWebSource(name: e.source?.name ?? URL(string: u)?.host ?? u, url: u))
                }
            }
        }
        return out
    }
}

/// A chat message. Open WebUI stores `content` as a plain string for text and as
/// an array of parts for multimodal; we flatten to text here (images handled by
/// the attachments layer later).
public struct OWMessage: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var role: OWRole
    public var content: String
    public var model: String?
    public var timestamp: Double?
    /// Parent in the branching history graph (decode-only; drives ordered()).
    public var parentId: String?
    /// Attached images as URLs (data: URLs for local attachments, server urls otherwise).
    public var imageURLs: [String]
    /// Non-image attachments (documents → RAG).
    public var documents: [OWAttachment]
    /// Web-search citations (from the server chat or the SSE sources frame).
    public var sources: [OWWebSource]

    public init(id: String = UUID().uuidString, role: OWRole, content: String,
                model: String? = nil, timestamp: Double? = nil,
                imageURLs: [String] = [], documents: [OWAttachment] = [],
                sources: [OWWebSource] = []) {
        self.id = id; self.role = role; self.content = content
        self.model = model; self.timestamp = timestamp
        self.imageURLs = imageURLs; self.documents = documents
        self.sources = sources
    }

    enum CodingKeys: String, CodingKey { case id, role, content, model, timestamp, files, parentId, output, sources }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .id) { id = s }
        else if let i = try? c.decode(Int.self, forKey: .id) { id = String(i) }
        else { id = UUID().uuidString }
        role = (try? c.decode(OWRole.self, forKey: .role)) ?? .assistant

        var imgs: [String] = []
        var docs: [OWAttachment] = []
        if let s = try? c.decode(String.self, forKey: .content) {
            content = s
        } else if let parts = try? c.decode([OWContentPart].self, forKey: .content) {
            content = parts.compactMap(\.text).joined(separator: "\n")
            imgs += parts.compactMap(\.imageURL)
        } else {
            content = ""
        }
        // Open WebUI >= 0.10 saves assistant replies ONLY as structured `output`
        // items (flat content stays "") — rebuild the text from there.
        if content.isEmpty,
           let items = try? c.decode([OWLossy<OWOutputItem>].self, forKey: .output) {
            content = OWOutputItem.flatten(items.compactMap(\.value))
        }
        // Lossy per-element: one exotic file entry must not drop every attachment.
        if let files = try? c.decode([OWLossy<OWAttachment>].self, forKey: .files) {
            for f in files.compactMap(\.value) {
                if f.isImage, let u = f.url { imgs.append(u) } else { docs.append(f) }
            }
        }
        imageURLs = imgs
        documents = docs
        let entries = (try? c.decode([OWLossy<OWSourceEntry>].self, forKey: .sources))?.compactMap(\.value) ?? []
        sources = OWSourceEntry.webSources(entries)

        model = try? c.decodeIfPresent(String.self, forKey: .model)
        timestamp = try? c.decode(Double.self, forKey: .timestamp)
        parentId = try? c.decodeIfPresent(String.self, forKey: .parentId)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role.rawValue, forKey: .role)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(timestamp, forKey: .timestamp)
        var files = imageURLs.map { OWAttachment(type: "image", url: $0) }
        files += documents
        if !files.isEmpty { try c.encode(files, forKey: .files) }
    }
}

// MARK: - Chats

/// One row from GET /api/v1/chats/ — Open WebUI uses integer epoch-second
/// timestamps (not ISO strings, unlike Odysseus).
public struct OWChatSummary: Decodable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var updatedAt: Double?
    public var createdAt: Double?
    public var pinned: Bool
    public var archived: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, updated_at, created_at, pinned, archived
    }

    public init(id: String, title: String, updatedAt: Double? = nil,
                createdAt: Double? = nil, pinned: Bool = false, archived: Bool = false) {
        self.id = id; self.title = title; self.updatedAt = updatedAt
        self.createdAt = createdAt; self.pinned = pinned; self.archived = archived
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .id) { id = s }
        else if let i = try? c.decode(Int.self, forKey: .id) { id = String(i) }
        else { id = UUID().uuidString }
        title = (try? c.decode(String.self, forKey: .title)).flatMap { $0.isEmpty ? nil : $0 } ?? "Nova conversa"
        updatedAt = try? c.decode(Double.self, forKey: .updated_at)
        createdAt = try? c.decode(Double.self, forKey: .created_at)
        pinned = (try? c.decode(Bool.self, forKey: .pinned)) ?? false
        archived = (try? c.decode(Bool.self, forKey: .archived)) ?? false
    }
}

/// Decodes T but swallows per-element failures — one malformed message must not
/// nuke the whole chat (the exact failure mode when web-created messages carry
/// fields/shapes this client has never seen).
struct OWLossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// Open WebUI keeps a branching history map `{ messages: { id: msg }, currentId }`
/// alongside the flat `messages` array. The active conversation is the
/// currentId → parentId chain (what the web UI renders); timestamp sort is only
/// the fallback for orphans.
struct OWHistory: Decodable {
    var messages: [String: OWMessage]
    var currentId: String?

    enum CodingKeys: String, CodingKey { case messages, currentId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lossy = (try? c.decode([String: OWLossy<OWMessage>].self, forKey: .messages)) ?? [:]
        messages = lossy.compactMapValues(\.value)
        currentId = try? c.decodeIfPresent(String.self, forKey: .currentId)
    }

    func ordered() -> [OWMessage] {
        // Walk the active branch backwards from currentId.
        if let cur = currentId, messages[cur] != nil {
            var chain: [OWMessage] = []
            var id: String? = cur
            var guardCount = 0
            while let i = id, let m = messages[i], guardCount < 10_000 {
                chain.append(m); id = m.parentId; guardCount += 1
            }
            if chain.count > 1 || messages.count == 1 { return chain.reversed() }
        }
        return messages.values.sorted { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
    }
}

/// GET /api/v1/chats/{id}. The server wraps the real chat under a `chat` key:
/// `{ id, user_id, title, chat: { models, messages, history }, … }`. We flatten
/// so callers get `messages` directly.
public struct OWChat: Decodable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var models: [String]
    public var messages: [OWMessage]

    enum Top: String, CodingKey { case id, title, chat }
    enum Inner: String, CodingKey { case id, title, models, messages, history }

    public init(id: String, title: String, models: [String] = [], messages: [OWMessage] = []) {
        self.id = id; self.title = title; self.models = models; self.messages = messages
    }

    public init(from decoder: Decoder) throws {
        let top = try decoder.container(keyedBy: Top.self)
        id = (try? top.decode(String.self, forKey: .id)) ?? UUID().uuidString
        let topTitle = (try? top.decode(String.self, forKey: .title)).flatMap { $0.isEmpty ? nil : $0 }

        if let inner = try? top.nestedContainer(keyedBy: Inner.self, forKey: .chat) {
            title = (try? inner.decode(String.self, forKey: .title)).flatMap { $0.isEmpty ? nil : $0 }
                ?? topTitle ?? L("Conversa")
            models = (try? inner.decode([String].self, forKey: .models)) ?? []
            // Decode BOTH sources lossily and keep the fuller one — the web app
            // sometimes updates only the history graph, and a single malformed
            // message must not drop the rest of the conversation.
            let flat = ((try? inner.decode([OWLossy<OWMessage>].self, forKey: .messages)) ?? [])
                .compactMap(\.value)
            let chain = (try? inner.decode(OWHistory.self, forKey: .history))?.ordered() ?? []
            // The history chain is the web UI's source of truth (it shows the
            // active branch); flat is only the fallback for broken/absent graphs.
            messages = (!chain.isEmpty && chain.count >= flat.count) ? chain : flat
        } else {
            title = topTitle ?? "Conversa"
            models = []
            messages = []
        }
    }
}
