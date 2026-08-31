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

    /// The chain-of-thought the server stored alongside the answer, for the
    /// reasoning disclosure. Kept out of `flatten` so it never reaches the bubble.
    static func reasoningText(_ items: [OWOutputItem]) -> String {
        items.filter { $0.type == "reasoning" }
            .map { $0.parts.compactMap(\.text).joined() }
            .filter { !$0.isEmpty }
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
struct OWSourceEntry: Codable {
    var source: Src?
    var metadata: [Meta]
    struct Src: Codable { var name: String?; var url: String? }
    struct Meta: Codable { var source: String? }

    enum CodingKeys: String, CodingKey { case source, metadata }

    /// Rebuild the server shape from a citation (offline cache round-trip).
    init(_ s: OWWebSource) {
        source = Src(name: s.name, url: s.url)
        metadata = s.url.map { [Meta(source: $0)] } ?? []
    }

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

/// A source cited by a tool run (a web-search result).
public struct OWSource: Codable, Hashable, Sendable {
    public var title: String
    public var url: String
    public init(title: String, url: String) { self.title = title; self.url = url }
}

/// An auditable record of one tool the model ran — the query it used and the raw
/// context it got back. Lets the UI show a Claude-style, expandable
/// "searched X → here's what it saw" card, so tool runs aren't a black box.
public struct OWToolUse: Identifiable, Hashable, Sendable {
    public var action: String        // "web_search" | "weather" | …
    public var query: String
    public var results: String       // the raw text the model was given
    public var sources: [OWSource]
    public var id: String { "\(action)|\(query)|\(sources.count)|\(results.count)" }
    public var title: String {
        if !query.isEmpty { return query }
        switch action {
        case "web_search": return L("Busca na web")
        case "weather":    return L("Clima")
        // Named after the files themselves whenever the server said which; the
        // generic fallback is the same word the attachment list already uses.
        case "files":      return L("arquivo")
        default:           return action
        }
    }
    public var icon: String {
        switch action {
        case "web_search": return "magnifyingglass"
        case "weather":    return "cloud.sun"
        case "files":      return "doc.text.magnifyingglass"
        default:           return "wrench.and.screwdriver"
        }
    }
    public init(action: String, query: String, results: String, sources: [OWSource]) {
        self.action = action; self.query = query; self.results = results; self.sources = sources
    }
}

/// One `statusHistory` entry as Open WebUI stores it on a message. A tool-calling
/// pipe adds the rich `action`/`query`/`results`/`sources` fields on tool runs.
struct OWStatusEntry: Codable {
    var action: String?
    var query: String?
    var results: String?
    var sources: [OWSource]?
    var description: String?
    var done: Bool?
}

/// One entry of Open WebUI's NATIVE `sources` array (built-in web search / RAG,
/// no custom pipe): `{ source: {name, id}, document: ["raw retrieved text", …] }`.
/// This is what a stock Open WebUI emits, so tool cards work without any pipe.
struct OWNativeSource: Decodable {
    struct Ref: Decodable { var name: String?; var id: String? }
    var source: Ref?
    var document: [String]?
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
    /// The model's chain-of-thought, shown in a collapsible disclosure and kept
    /// separate from the visible reply. Filled from streamed `reasoning` deltas or
    /// split out of an inline `<think>…</think>` block on decode. Display-only —
    /// never re-encoded, so it isn't pushed back to the server.
    public var reasoning: String
    /// Attached images as URLs (data: URLs for local attachments, server urls otherwise).
    public var imageURLs: [String]
    /// Non-image attachments (documents → RAG). An entry here may still be a
    /// picture the server holds by id rather than by URL — see `imageDocuments`.
    public var documents: [OWAttachment]

    /// Pictures that arrived as uploaded files, so they have an id instead of a
    /// URL. The bubble renders these as thumbnails through
    /// `client.fileContentURL(id)` rather than as document pills.
    public var imageDocuments: [OWAttachment] { documents.filter { $0.isImage && $0.id != nil } }

    /// Everything in `documents` that is genuinely a document.
    public var otherDocuments: [OWAttachment] { documents.filter { !($0.isImage && $0.id != nil) } }
    /// Web-search citations (from the server chat or the SSE sources frame).
    public var sources: [OWWebSource]
    /// Auditable tool runs behind this reply (built-in web search / RAG, or a
    /// tool-calling pipe) — each with its query, raw results, and sources.
    public var toolUses: [OWToolUse]

    public init(id: String = UUID().uuidString, role: OWRole, content: String,
                model: String? = nil, timestamp: Double? = nil, reasoning: String = "",
                imageURLs: [String] = [], documents: [OWAttachment] = [],
                sources: [OWWebSource] = [], toolUses: [OWToolUse] = []) {
        self.id = id; self.role = role; self.content = content
        self.model = model; self.timestamp = timestamp; self.reasoning = reasoning
        self.imageURLs = imageURLs; self.documents = documents
        self.sources = sources
        self.toolUses = toolUses
    }

    enum CodingKeys: String, CodingKey {
        case id, role, content, model, timestamp, files, parentId
        case output, sources, reasoning, statusHistory
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .id) { id = s }
        else if let i = try? c.decode(Int.self, forKey: .id) { id = String(i) }
        else { id = UUID().uuidString }
        role = (try? c.decode(OWRole.self, forKey: .role)) ?? .assistant

        var imgs: [String] = []
        var docs: [OWAttachment] = []
        var body: String
        if let s = try? c.decode(String.self, forKey: .content) {
            body = s
        } else if let parts = try? c.decode([OWContentPart].self, forKey: .content) {
            body = parts.compactMap(\.text).joined(separator: "\n")
            imgs += parts.compactMap(\.imageURL)
        } else {
            body = ""
        }
        // Open WebUI >= 0.10 keeps the reply as structured `output` items, and a
        // web-generated one can leave the flat `content` empty — so the text is
        // rebuilt from there when there is nothing else.
        //
        // The reasoning is read unconditionally, which the text is not. It lives
        // in its own `output` item (`type: "reasoning"`,
        // backend utils/middleware.py:3534) while `content` carries only the
        // answer, so gating the whole decode on an empty `content` threw the
        // chain-of-thought away for every reply that had any text at all: the web
        // UI showed "Pensado por 9 segundos" and the app showed no disclosure.
        var outputReasoning = ""
        if let items = try? c.decode([OWLossy<OWOutputItem>].self, forKey: .output) {
            let list = items.compactMap(\.value)
            if body.isEmpty { body = OWOutputItem.flatten(list) }
            outputReasoning = OWOutputItem.reasoningText(list)
        }
        // Thinking models (and Open WebUI itself) persist chain-of-thought inline
        // as a leading <think>…</think> block. Lift it into `reasoning` so the
        // disclosure can show it and the raw tags never leak into the bubble.
        let split = OWMessage.splitReasoning(body)
        content = split.content
        // A cached copy carries `reasoning` verbatim; server payloads never do.
        let stored = (try? c.decodeIfPresent(String.self, forKey: .reasoning)) ?? nil
        reasoning = stored ?? (outputReasoning.isEmpty ? split.reasoning
            : (split.reasoning.isEmpty ? outputReasoning : outputReasoning + "\n\n" + split.reasoning))
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

        // Auditable tool runs live in statusHistory — the rich entries carry `action`.
        let status: [OWStatusEntry] = (try? c.decode([OWStatusEntry].self, forKey: .statusHistory)) ?? []
        var tools = status.compactMap { e -> OWToolUse? in
            guard let action = e.action else { return nil }
            return OWToolUse(action: action, query: e.query ?? "",
                             results: e.results ?? "", sources: e.sources ?? [])
        }
        // Stock Open WebUI (native web search / RAG, no pipe) exposes the same audit
        // data in `sources`; synthesize a card from it when no rich entry was present.
        if tools.isEmpty, let native = try? c.decode([OWNativeSource].self, forKey: .sources), !native.isEmpty {
            tools = [OWMessage.toolUse(fromNative: native)]
        }
        toolUses = tools
    }

    /// Fold Open WebUI's native `sources` (built-in web search / RAG) into a single
    /// auditable card: the source URLs become tappable links, the `document` texts
    /// become the retrieved context.
    ///
    /// The kind is read off the sources rather than assumed. This used to hardcode
    /// `web_search`, so context retrieved from an attached file, a knowledge base
    /// or a skill was announced as "Busca na web" over a magnifying glass, with
    /// the file's raw markdown as its "results" — a search that never happened,
    /// naming a web page that does not exist.
    static func toolUse(fromNative sources: [OWNativeSource]) -> OWToolUse {
        var docs: [String] = []
        var srcs: [OWSource] = []
        var names: [String] = []
        for n in sources {
            docs += (n.document ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let name = n.source?.name ?? "", id = n.source?.id ?? ""
            let url = id.hasPrefix("http") ? id : (name.hasPrefix("http") ? name : "")
            if !url.isEmpty, !srcs.contains(where: { $0.url == url }) {
                srcs.append(OWSource(title: (name.hasPrefix("http") || name.isEmpty) ? url : name, url: url))
            } else if url.isEmpty, !name.isEmpty, !names.contains(name) {
                names.append(name)
            }
        }
        // A web result always carries an http URL; retrieved files never do.
        let fromWeb = !srcs.isEmpty
        return OWToolUse(action: fromWeb ? "web_search" : "files",
                         query: fromWeb ? "" : names.joined(separator: ", "),
                         results: String(docs.joined(separator: "\n\n---\n\n").prefix(4000)), sources: srcs)
    }

    /// Only the offline cache encodes an `OWMessage` (server payloads are built
    /// by `OWChatPayload`), so `reasoning` and `sources` are written in the same
    /// shape the decoder reads — otherwise a cached chat loses both on reload.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role.rawValue, forKey: .role)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(timestamp, forKey: .timestamp)
        // Persist the branch link — without it a written history flattens on the
        // next save and sibling branches become unreachable.
        try c.encodeIfPresent(parentId, forKey: .parentId)
        if !reasoning.isEmpty { try c.encode(reasoning, forKey: .reasoning) }
        if !sources.isEmpty {
            try c.encode(sources.map(OWSourceEntry.init), forKey: .sources)
        }
        var files = imageURLs.map { OWAttachment(type: "image", url: $0) }
        files += documents
        if !files.isEmpty { try c.encode(files, forKey: .files) }
        // Round-trip the tool cards through statusHistory so a rewrite (a later turn
        // that re-persists the whole chat) doesn't drop them.
        if !toolUses.isEmpty {
            let entries = toolUses.map { t in
                OWStatusEntry(action: t.action, query: t.query, results: t.results,
                              sources: t.sources, description: t.title, done: true)
            }
            try c.encode(entries, forKey: .statusHistory)
        }
    }

    /// Pulls a leading `<think>…</think>` span out of a message body, returning
    /// the reasoning text and the remaining visible content. A `<think>` with no
    /// closing tag (mid-stream persistence) is treated as all-reasoning. Bodies
    /// with no think block are returned unchanged.
    static func splitReasoning(_ body: String) -> (content: String, reasoning: String) {
        let trimmed = body.drop { $0 == "\n" || $0 == " " }
        guard trimmed.hasPrefix("<think>") else { return (body, "") }
        let afterOpen = trimmed.dropFirst("<think>".count)
        if let close = afterOpen.range(of: "</think>") {
            let reasoning = afterOpen[afterOpen.startIndex..<close.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = afterOpen[close.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (rest, reasoning)
        }
        return ("", afterOpen.trimmingCharacters(in: .whitespacesAndNewlines))
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
    /// A matching excerpt for full-text search results (not part of the API).
    public var snippet: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, updated_at, created_at, pinned, archived
    }

    public init(id: String, title: String, updatedAt: Double? = nil,
                createdAt: Double? = nil, pinned: Bool = false, archived: Bool = false,
                snippet: String? = nil) {
        self.id = id; self.title = title; self.updatedAt = updatedAt
        self.createdAt = createdAt; self.pinned = pinned; self.archived = archived
        self.snippet = snippet
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
    /// The active branch (currentId → root chain) — what the UI renders by default.
    public var messages: [OWMessage]
    /// EVERY node in the branching history, not just the active branch. Needed to
    /// navigate and preserve sibling branches (edit / regenerate) instead of
    /// flattening them away on the next save.
    public var allMessages: [OWMessage]
    /// The active leaf the server considers current.
    public var currentId: String?

    enum Top: String, CodingKey { case id, title, chat }
    enum Inner: String, CodingKey { case id, title, models, messages, history }

    public init(id: String, title: String, models: [String] = [], messages: [OWMessage] = []) {
        self.id = id; self.title = title; self.models = models; self.messages = messages
        self.allMessages = messages; self.currentId = messages.last?.id
    }

    /// Rebuilds a chat from a history tree (all nodes + the active leaf). `messages`
    /// is derived by walking the `currentId → root` chain.
    public init(id: String, title: String, models: [String],
                allMessages: [OWMessage], currentId: String?) {
        self.id = id; self.title = title; self.models = models
        self.allMessages = allMessages; self.currentId = currentId
        self.messages = OWChat.activeBranch(allMessages, currentId: currentId)
    }

    /// The active branch (currentId → root, reversed) from a flat node list.
    /// Falls back to timestamp order when the leaf is unknown, so a chat with a
    /// broken graph still renders in a sane order.
    public static func activeBranch(_ nodes: [OWMessage], currentId: String?) -> [OWMessage] {
        let map = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard let cur = currentId, map[cur] != nil else {
            return nodes.sorted { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
        }
        var chain: [OWMessage] = []
        var id: String? = cur
        var guardCount = 0
        while let i = id, let m = map[i], guardCount < 10_000 {
            chain.append(m); id = m.parentId; guardCount += 1
        }
        return chain.reversed()
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
            let history = try? inner.decode(OWHistory.self, forKey: .history)
            let chain = history?.ordered() ?? []
            // The history chain is the web UI's source of truth (it shows the
            // active branch); flat is only the fallback for broken/absent graphs.
            messages = (!chain.isEmpty && chain.count >= flat.count) ? chain : flat
            // Keep the full node set and the server's leaf so branches created in
            // the web UI stay navigable — and survive our next write.
            allMessages = history.map { Array($0.messages.values) } ?? messages
            currentId = history?.currentId ?? messages.last?.id
        } else {
            title = topTitle ?? "Conversa"
            models = []
            messages = []
            allMessages = []
            currentId = nil
        }
    }
}

/// What `GET /api/config` says this server offers. Public, no auth — this is how
/// the login screen learns whether to draw a password form, an LDAP form, SSO
/// buttons, or some combination, instead of assuming email+password is the only
/// way in (github.com/JoaoZaokk/openwebui-ios issue #13).
public struct OWServerConfig: Decodable, Sendable {
    public var name: String?
    public var version: String?
    public var oauth: OAuth?
    public var features: Features?

    public struct OAuth: Decodable, Sendable {
        /// provider key (`google`, `microsoft`, `github`, `oidc`, `feishu`) → the
        /// label the admin chose. Empty on a server with no SSO configured.
        public var providers: [String: String]?
        public var autoRedirect: Bool?
        enum CodingKeys: String, CodingKey { case providers, autoRedirect = "auto_redirect" }
    }

    public struct Features: Decodable, Sendable {
        public var auth: Bool?
        public var enableLoginForm: Bool?
        public var enableLdap: Bool?
        public var enableSignup: Bool?
        public var authTrustedHeader: Bool?
        /// New in 0.11: with plugins off the server silently discards `tool_ids`.
        public var enablePlugins: Bool?
        enum CodingKeys: String, CodingKey {
            case auth
            case enableLoginForm = "enable_login_form"
            case enableLdap = "enable_ldap"
            case enableSignup = "enable_signup"
            case authTrustedHeader = "auth_trusted_header"
            case enablePlugins = "enable_plugins"
        }
    }

    /// Providers in a stable order, so the login screen doesn't reshuffle its
    /// buttons between launches.
    public var oauthProviders: [(key: String, label: String)] {
        (oauth?.providers ?? [:]).map { (key: $0.key, label: $0.value) }
            .sorted { $0.key < $1.key }
    }
    public var passwordLoginAvailable: Bool { features?.enableLoginForm ?? true }
    public var ldapAvailable: Bool { features?.enableLdap ?? false }
    /// `false` only when the admin turned plugins off — then `tool_ids` are dropped.
    public var pluginsAvailable: Bool { features?.enablePlugins ?? true }
}

/// Which model a new conversation opens with.
///
/// Shared by the chat screen and voice mode, and split out here because the rule
/// is the whole fix for "Bei jedem neuen Chat neu auswählen nervt" — both places
/// used to take `models.first`, whatever order the server happened to answer in,
/// so every new chat and every voice session discarded the user's choice.
public enum OWModelChoice {
    /// The remembered pick when this server still offers it, else the first model.
    ///
    /// Falling back matters as much as remembering: a model can be removed, lose
    /// its access control, or simply not exist on a server the user switched to,
    /// and a remembered id that resolves to nothing would leave the composer
    /// disabled with no explanation.
    public static func resolve(remembered: String?, available: [String]) -> String? {
        if let remembered, available.contains(remembered) { return remembered }
        return available.first
    }
}
