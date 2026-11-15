import Foundation

/// The notes functions the app offers the model itself — `search_notes` and
/// `view_note`, with the names, parameters and meaning of the builtin tools in
/// Open WebUI 0.13 (`tools/builtin.py:1147`, `:1248`).
///
/// On the web the model answers from the user's Notes because the server hands it
/// those builtins. It does that only for a request that carries a `session_id`
/// (`middleware.py:2070`) — a browser tab's — so for the app's requests no notes
/// tool exists and the model "has no information". Offering them and running
/// them is therefore the app's job, exactly as it is for `search_web`
/// (`OWWebSearchTool`); `streamReply` routes the calls here by name, and this
/// file runs them through the REST API the web UI itself uses.
///
/// What is left out of the upstream signature is `__request__` / `__user__`: the
/// server injects them, and the model must never be asked to fill them. What
/// differs from the upstream result is mostly the dates — nanosecond epochs
/// mean nothing to a model, so they go out as ISO-8601 — and the `url`, which is
/// a path on the web UI.
public enum OWNotesTools {
    public static let searchName = "search_notes"
    public static let viewName = "view_note"

    /// Whether a call is one of ours, by the name the model used.
    public static func handles(_ name: String) -> Bool { name == searchName || name == viewName }

    /// Most notes one search hands the model, whatever it asks for. Each hit
    /// carries a snippet, so this bounds the prompt, not the server.
    public static let maxHits = 20
    /// `count` default of the upstream tool.
    public static let defaultHits = 5
    /// What `view_note` hands over of one note, in characters. A note can be
    /// pages long; the rest is announced, not silently dropped, so the model can
    /// say so or ask for one page.
    public static let maxBodyCharacters = 12_000
    /// What the saved card keeps of what the model read: a short excerpt, not
    /// the note. The card is written into the chat record on the server
    /// (`statusHistory`), and a chat can be shared or exported where the note's
    /// own access grants do not apply (review finding 18).
    static let maxCardCharacters = 280
    /// Where the server cuts each hit's body in `GET /notes/search`
    /// (`_truncate_note_data`, routers/notes.py:65-75).
    static let serverSnippetCut = 1_000

    static let specs: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": searchName,
                "description": "Search the user's saved notes by title and content. Use it when the user refers to their notes, or to something they may have written down.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "The search query to find matching notes."],
                        "count": ["type": "integer", "description": "Maximum number of results to return (default: 5)."],
                        "start_timestamp": ["type": "integer", "description": "Only include notes updated after this Unix timestamp (seconds)."],
                        "end_timestamp": ["type": "integer", "description": "Only include notes updated before this Unix timestamp (seconds)."],
                    ] as [String: Any],
                    "required": ["query"],
                ] as [String: Any],
            ] as [String: Any],
        ],
        [
            "type": "function",
            "function": [
                "name": viewName,
                "description": "Get the full content of a note by its ID (the id comes from search_notes).",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "note_id": ["type": "string", "description": "The ID of the note to retrieve."],
                        "page_id": ["type": "string", "description": "Page to read; omit to read the complete note and see its page directory."],
                    ] as [String: Any],
                    "required": ["note_id"],
                ] as [String: Any],
            ] as [String: Any],
        ],
    ]
}

/// One result of `GET /api/v1/notes/search`.
public struct OWNoteHit: Sendable, Equatable {
    public var id: String
    public var title: String
    /// Around the first matching word of the best-matching page, as upstream's
    /// `search_notes` cuts it; empty for a note with no body.
    public var snippet: String
    public var pageID: String?
    public var pageTitle: String?
    /// Seconds (the wire has nanoseconds).
    public var updatedAt: Double?
}

/// A page of a note, as `view_note` lists them.
public struct OWNotePageRef: Sendable, Equatable {
    public var id: String
    public var title: String
    public var parentID: String?
}

/// `GET /api/v1/notes/{id}`, reduced to what `view_note` answers with.
public struct OWNoteView: Sendable, Equatable {
    public var id: String
    public var title: String
    /// Markdown of the page read, or of the whole note.
    public var content: String
    /// Set when one page was read; nil for the whole note.
    public var pageID: String?
    public var pageTitle: String?
    public var pages: [OWNotePageRef]
    public var updatedAt: Double?
    public var createdAt: Double?
}

/// What a notes tool call turned into: the text the model is told, and the card
/// the reply shows.
public struct OWNotesToolResult: Sendable {
    public var text: String
    public var use: OWToolUse
}

/// A reason the model can read; becomes `{"error": …}`.
enum OWNotesToolError: LocalizedError {
    case missing(String)
    case unknownTool(String)
    case unknownPage(String, [String])

    var errorDescription: String? {
        switch self {
        case .missing(let arg): return "Missing required argument: \(arg)"
        case .unknownTool(let name): return "Unknown tool: \(name)"
        case .unknownPage(let page, let known):
            return "Page '\(page)' not found in this note. Pages: \(known.joined(separator: ", "))"
        }
    }
}

extension OpenWebUIClient {

    // MARK: - REST

    /// `GET /api/v1/notes/search`. `permission=read` because the route defaults to
    /// `write`, which hides notes shared read-only (routers/notes.py:213); what
    /// upstream's tool asks for too. The route answers a fixed page of 60 with
    /// each body cut to 1000 characters (`_truncate_note_data`), newest first;
    /// the date window and `count` are applied here, as the tool applies them to
    /// its own query.
    public func searchNotes(query: String, count: Int = OWNotesTools.defaultHits,
                            startTimestamp: Int? = nil, endTimestamp: Int? = nil) async throws -> [OWNoteHit] {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#")
        let q = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let data = try await send(request("/api/v1/notes/search?query=\(q)&permission=read"))

        struct Page: Decodable {
            var items: [Item]?
            struct Item: Decodable {
                var id: String?
                var title: String?
                var updated_at: Double?
                var data: Body?
                struct Body: Decodable {
                    var content: Content?
                    var page_id: String?
                    var page_title: String?
                    struct Content: Decodable { var md: String? }
                }
            }
        }
        let items: [Page.Item]
        if let page = try? JSONDecoder().decode(Page.self, from: data), let list = page.items {
            items = list
        } else {
            // A server that answers the bare list of the other notes routes.
            items = try decodeList(Page.Item.self, data, key: "items")
        }

        let cap = max(1, min(count, OWNotesTools.maxHits))
        var hits: [OWNoteHit] = []
        for item in items {
            guard let id = item.id else { continue }
            let updated = OWNote.seconds(item.updated_at)
            if let start = startTimestamp, let u = updated, u < Double(start) { continue }
            if let end = endTimestamp, let u = updated, u > Double(end) { continue }
            hits.append(OWNoteHit(id: id, title: item.title ?? "",
                                  snippet: Self.snippet(of: item.data?.content?.md ?? "", for: query),
                                  pageID: item.data?.page_id, pageTitle: item.data?.page_title,
                                  updatedAt: updated))
            if hits.count >= cap { break }
        }
        return hits
    }

    /// `GET /api/v1/notes/{id}` — the full note, pages included. With `pageID`, that
    /// page; without, the one page of a single-page note, or the whole note
    /// (`data.content.md`, the pages joined under `## path` headings) with its
    /// page directory — the same choice `view_note` makes upstream.
    public func viewNote(id: String, pageID: String? = nil) async throws -> OWNoteView {
        let data = try await send(request("/api/v1/notes/\(encPath(id))"))
        struct Full: Decodable {
            var id: String?
            var title: String?
            var updated_at: Double?
            var created_at: Double?
            var data: Body?
            struct Body: Decodable {
                var pages: [P]?
                var content: C?
                struct C: Decodable { var md: String? }
                struct P: Decodable {
                    var id: String?
                    var title: String?
                    var parent_id: String?
                    var content: C?
                }
            }
        }
        let note = try decode(Full.self, data)
        let pages = (note.data?.pages ?? []).compactMap { p -> (OWNotePageRef, String)? in
            guard let pid = p.id else { return nil }
            return (OWNotePageRef(id: pid, title: p.title ?? "", parentID: p.parent_id), p.content?.md ?? "")
        }
        let refs = pages.map(\.0)

        var chosen: (OWNotePageRef, String)?
        if let pageID {
            guard let p = pages.first(where: { $0.0.id == pageID }) else {
                throw OWNotesToolError.unknownPage(pageID, refs.map(\.id))
            }
            chosen = p
        } else if pages.count == 1 {
            chosen = pages[0]
        }
        let content: String
        if let chosen {
            content = chosen.1
        } else if let whole = note.data?.content?.md {
            content = whole
        } else {
            content = pages.map { "## \($0.0.title)\n\n\($0.1)" }.joined(separator: "\n\n")
        }
        return OWNoteView(id: note.id ?? id, title: note.title ?? "", content: content,
                          pageID: chosen?.0.id, pageTitle: chosen?.0.title, pages: refs,
                          updatedAt: OWNote.seconds(note.updated_at),
                          createdAt: OWNote.seconds(note.created_at))
    }

    /// About 50 characters before and 100 after the first word of the query found in
    /// the page — upstream's `search_notes` window — else the first 150.
    static func snippet(of md: String, for query: String) -> String {
        guard !md.isEmpty else { return "" }
        for word in query.split(whereSeparator: \.isWhitespace) {
            guard let r = md.range(of: String(word), options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            let start = md.index(r.lowerBound, offsetBy: -50, limitedBy: md.startIndex) ?? md.startIndex
            let end = md.index(r.upperBound, offsetBy: 100, limitedBy: md.endIndex) ?? md.endIndex
            return (start > md.startIndex ? "..." : "") + String(md[start..<end]) + (end < md.endIndex ? "..." : "")
        }
        // No query word in the text the server sent. When the server cut the body
        // the match may lie past the cut, so this is the start of the note and
        // must not look like context around a match (review finding 15).
        if md.count >= OWNotesTools.serverSnippetCut {
            return String(md.prefix(150)) + "... [start of the note only: the match is further down; open it with view_note]"
        }
        return String(md.prefix(150)) + (md.count > 150 ? "..." : "")
    }

    // MARK: - The tool

    /// Runs one notes call the model made. A failed lookup is an answer, not an
    /// error: it becomes `{"error": …}` for the model (as the upstream tool's
    /// `except` does) and a card that says so, and the reply goes on. What is
    /// thrown is only what must stop the turn: the user's Stop, and a dead
    /// session.
    public func runNotesTool(_ call: OWToolCall) async throws -> OWNotesToolResult {
        var subject = ""
        do {
            switch call.name {
            case OWNotesTools.searchName:
                guard let query = (call.string("query") ?? call.searchQueries.first)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                    throw OWNotesToolError.missing("query")
                }
                subject = query
                let hits = try await searchNotes(query: query,
                                                 count: call.int("count") ?? OWNotesTools.defaultHits,
                                                 startTimestamp: call.int("start_timestamp"),
                                                 endTimestamp: call.int("end_timestamp"))
                let rows: [[String: Any]] = hits.map { h in
                    ["id": h.id, "title": h.title, "snippet": h.snippet,
                     "page_id": h.pageID ?? NSNull(), "page_title": h.pageTitle ?? NSNull(),
                     "updated_at": Self.iso(h.updatedAt) ?? NSNull()]
                }
                // Titles only: the snippets are the notes' own text (finding 18).
                let card = hits.isEmpty ? "—" : hits.map { h in
                    "• \(h.title.isEmpty ? "—" : h.title)"
                }.joined(separator: "\n")
                return OWNotesToolResult(
                    text: Self.jsonText(rows),
                    use: OWToolUse(action: call.name, query: query,
                                   results: String(card.prefix(OWNotesTools.maxCardCharacters)), sources: [],
                                   callID: UUID().uuidString))

            case OWNotesTools.viewName:
                guard let id = (call.string("note_id") ?? call.string("id"))?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
                    throw OWNotesToolError.missing("note_id")
                }
                subject = id
                let note = try await viewNote(id: id, pageID: call.string("page_id"))
                var body = note.content
                if body.count > OWNotesTools.maxBodyCharacters {
                    let more = body.count - OWNotesTools.maxBodyCharacters
                    body = String(body.prefix(OWNotesTools.maxBodyCharacters))
                        + "\n\n[… truncated: \(more) more characters."
                        + (note.pages.count > 1 && note.pageID == nil ? " Call view_note with a page_id to read one page.]" : "]")
                }
                let obj: [String: Any] = [
                    "id": note.id, "title": note.title, "content": body,
                    "page_id": note.pageID ?? NSNull(), "page_title": note.pageTitle ?? NSNull(),
                    "pages": note.pages.map { ["id": $0.id, "title": $0.title, "parent_id": $0.parentID ?? NSNull()] as [String: Any] },
                    "updated_at": Self.iso(note.updatedAt) ?? NSNull(),
                    "created_at": Self.iso(note.createdAt) ?? NSNull(),
                ]
                return OWNotesToolResult(
                    text: Self.jsonText(obj),
                    use: OWToolUse(action: call.name, query: note.title.isEmpty ? id : note.title,
                                   results: String(note.content.prefix(OWNotesTools.maxCardCharacters)), sources: [],
                                   callID: UUID().uuidString))

            default:
                throw OWNotesToolError.unknownTool(call.name)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch OWError.notAuthenticated {
            throw OWError.notAuthenticated
        } catch {
            let why = OWFailure.msg(error)
            return OWNotesToolResult(
                text: Self.jsonText(["error": why]),
                use: OWToolUse(action: call.name, query: subject, results: why, sources: [],
                               callID: UUID().uuidString))
        }
    }

    private static func iso(_ seconds: Double?) -> String? {
        guard let seconds else { return nil }
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
    }

    /// The JSON the model reads between `<notes_tool_result>` tags. A note is
    /// whatever its author wrote — and for a note shared with the user, that is
    /// someone else — so a body holding `</notes_tool_result>` would close the
    /// fence and leave what follows outside it (review finding 13). JSON allows
    /// `\u003c` and `\u003e` for any character inside a string, and `<`/`>` never
    /// occur outside strings, so escaping them removes every way to write a tag
    /// while the model still reads the same text back.
    static func jsonText(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let d = try? JSONSerialization.data(withJSONObject: value,
                                                   options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
    }
}
