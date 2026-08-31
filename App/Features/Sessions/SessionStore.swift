import SwiftUI
import SwiftData
import OpenWebUIKit

/// Loads and mutates the user's chat list from Open WebUI.
@MainActor
final class ChatStore: ObservableObject {
    @Published var chats: [OWChatSummary] = []
    @Published var loading = false
    @Published var error: String?
    /// Full-text search results (title + cached message bodies). Populated by `search`.
    @Published var searchResults: [OWChatSummary] = []
    /// The query behind `searchResults`, so a mutation can refresh them.
    private var query = ""
    /// True when the current list is being served from the offline cache.
    @Published private(set) var offline = false

    private let client: OpenWebUIClient
    let cache: ServerChatCache
    init(client: OpenWebUIClient, cache: ServerChatCache) {
        self.client = client
        self.cache = cache
    }

    /// Hide archived; pinned first, then most-recent.
    private func sorted(_ list: [OWChatSummary]) -> [OWChatSummary] {
        list.filter { !$0.archived }.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
            return (lhs.updatedAt ?? 0) > (rhs.updatedAt ?? 0)
        }
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            // The main list excludes pinned chats, so fetch those separately and
            // merge. Pinned fetch is best-effort: a failure must not wipe the list.
            let regular = try await client.chats()
            let pinned: [OWChatSummary] = (try? await client.pinnedChats())?
                .map { var c = $0; c.pinned = true; return c } ?? []
            let pinnedIDs = Set(pinned.map(\.id))
            let merged = pinned + regular.filter { !pinnedIDs.contains($0.id) }
            cache.cacheSummaries(merged)   // keep the offline list fresh
            chats = sorted(merged)
            offline = false
            error = nil
            await refreshSearch()
        } catch is CancellationError {
        } catch {
            // Server unreachable: fall back to the chats we've cached so past
            // conversations stay readable offline.
            let cached = cache.cachedSummaries()
            if !cached.isEmpty { chats = sorted(cached); offline = true }
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Full-text search: title match across the whole list, plus body matches over
    /// cached (previously-opened) conversations. Entirely on-device.
    func search(_ text: String) async {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        query = q
        guard !q.isEmpty else { searchResults = []; return }
        var results = cache.search(q)
        // Include list chats whose TITLE matches but that we haven't opened/cached.
        let have = Set(results.map(\.id))
        let titleOnly = chats.filter { !have.contains($0.id) && $0.title.localizedCaseInsensitiveContains(q) }
        results += titleOnly
        searchResults = sorted(results)
    }

    func delete(_ chat: OWChatSummary) async {
        do {
            try await client.deleteChat(chat.id)
            cache.deleteCached(id: chat.id)
            forget(chat.id)
        } catch { report(error) }
    }

    /// Drops a chat from every list the screen can be showing.
    ///
    /// `chats` and `searchResults` are separate arrays and the list renders
    /// whichever is active, so removing from `chats` alone left the row on screen:
    /// deleting or archiving a chat *while a search was open* looked like it did
    /// nothing until the search was cleared.
    private func forget(_ id: String) {
        chats.removeAll { $0.id == id }
        searchResults.removeAll { $0.id == id }
    }

    /// Re-runs the active search after the underlying list changed.
    private func refreshSearch() async {
        guard !query.isEmpty else { return }
        await search(query)
    }

    func pin(_ chat: OWChatSummary) async {
        do { try await client.pinChat(chat.id); await load() } catch { report(error) }
    }

    func archive(_ chat: OWChatSummary) async {
        do { try await client.archiveChat(chat.id); forget(chat.id) }
        catch { report(error) }
    }

    func clone(_ chat: OWChatSummary) async {
        do { _ = try await client.cloneChat(chat.id); await load() } catch { report(error) }
    }

    func rename(_ chat: OWChatSummary, to title: String) async {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        do { try await client.renameChat(chat.id, to: t); await load() } catch { report(error) }
    }

    /// Returns the public share URL for the iOS share sheet.
    func shareLink(_ chat: OWChatSummary) async -> URL? {
        do { return try await client.shareChat(chat.id) } catch { report(error); return nil }
    }

    /// Revokes the public share link (best-effort — a not-shared chat is a no-op).
    func unshare(_ chat: OWChatSummary) async {
        do { try await client.unshareChat(chat.id) } catch { report(error) }
    }

    /// Exports the chat JSON to a temp file and returns its URL (for "download").
    func export(_ chat: OWChatSummary) async -> URL? {
        do {
            let data = try await client.exportChat(chat.id)
            let safe = chat.title.replacingOccurrences(of: "/", with: "-").prefix(40)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).json")
            try data.write(to: url)
            return url
        } catch { report(error); return nil }
    }

    private func report(_ error: Error) {
        self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - Offline cache (read-only)
//
// Kept in this file (rather than its own) so it joins the existing target
// membership without a project regeneration.

/// On-device mirror of a server chat, so past conversations stay readable with no
/// connectivity. Refreshed whenever the server is reachable; history is stored the
/// first time a chat is opened. Messages are kept as an encoded `[OWMessage]` blob
/// (they're already `Codable`) so the schema stays a single table.
@Model
final class CachedServerChat {
    @Attribute(.unique) var id: String
    var title: String
    var createdAt: Double
    var updatedAt: Double
    var pinned: Bool
    var archived: Bool
    private var modelsData: Data
    private var messagesData: Data

    var models: [String] {
        get { (try? JSONDecoder().decode([String].self, from: modelsData)) ?? [] }
        set { modelsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
    var messages: [OWMessage] {
        get { (try? JSONDecoder().decode([OWMessage].self, from: messagesData)) ?? [] }
        set { messagesData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
    var hasHistory: Bool { !messagesData.isEmpty && !messages.isEmpty }

    init(id: String, title: String, createdAt: Double, updatedAt: Double,
         pinned: Bool, archived: Bool, models: [String], messages: [OWMessage]) {
        self.id = id; self.title = title; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.pinned = pinned; self.archived = archived
        self.modelsData = (try? JSONEncoder().encode(models)) ?? Data()
        self.messagesData = (try? JSONEncoder().encode(messages)) ?? Data()
    }
}

/// Thin CRUD wrapper around the on-device SwiftData cache. A manual store (not
/// `@Query`) so it slots into the existing `ChatStore` load/merge logic.
@MainActor
final class ServerChatCache {
    private let container: ModelContainer
    private var ctx: ModelContext { container.mainContext }

    init() {
        // Fall back to an in-memory store if the on-disk one can't open, so a
        // storage failure degrades to "chats don't cache" rather than a crash.
        if let c = try? ModelContainer(for: CachedServerChat.self) {
            container = c
        } else {
            let cfg = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try! ModelContainer(for: CachedServerChat.self, configurations: cfg)
        }
    }

    private func cached(id: String) -> CachedServerChat? {
        let d = FetchDescriptor<CachedServerChat>(predicate: #Predicate { $0.id == id })
        return try? ctx.fetch(d).first ?? nil
    }

    /// Refresh cached list metadata from a server fetch (keeps any cached history).
    func cacheSummaries(_ list: [OWChatSummary]) {
        for s in list {
            if let e = cached(id: s.id) {
                e.title = s.title
                if let u = s.updatedAt { e.updatedAt = u }
                if let c = s.createdAt { e.createdAt = c }
                e.pinned = s.pinned; e.archived = s.archived
            } else {
                ctx.insert(CachedServerChat(id: s.id, title: s.title,
                    createdAt: s.createdAt ?? 0, updatedAt: s.updatedAt ?? 0,
                    pinned: s.pinned, archived: s.archived, models: [], messages: []))
            }
        }
        try? ctx.save()
    }

    /// Cached chats that actually have history (i.e. were opened) — the set that's
    /// genuinely readable offline, newest first.
    func cachedSummaries() -> [OWChatSummary] {
        let d = FetchDescriptor<CachedServerChat>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        return ((try? ctx.fetch(d)) ?? []).filter(\.hasHistory).map {
            OWChatSummary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt,
                          createdAt: $0.createdAt, pinned: $0.pinned, archived: $0.archived)
        }
    }

    /// Store a chat's messages for offline reading.
    func cacheChat(_ chat: OWChat) {
        guard !chat.id.isEmpty, !chat.messages.isEmpty else { return }
        if let e = cached(id: chat.id) {
            if !chat.title.isEmpty { e.title = chat.title }
            e.models = chat.models
            e.messages = chat.messages
        } else {
            let now = Date().timeIntervalSince1970
            ctx.insert(CachedServerChat(id: chat.id, title: chat.title,
                createdAt: now, updatedAt: now, pinned: false, archived: false,
                models: chat.models, messages: chat.messages))
        }
        try? ctx.save()
    }

    /// Reconstruct a cached chat for offline reading (nil if none cached).
    func cachedChat(id: String) -> OWChat? {
        guard let e = cached(id: id), e.hasHistory else { return nil }
        return OWChat(id: e.id, title: e.title, models: e.models, messages: e.messages)
    }

    func deleteCached(id: String) {
        guard let e = cached(id: id) else { return }
        ctx.delete(e); try? ctx.save()
    }

    /// Full-text search over cached conversations. Matches title or any message
    /// body; returns summaries carrying a matching `snippet`, newest first.
    func search(_ text: String) -> [OWChatSummary] {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let d = FetchDescriptor<CachedServerChat>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        var out: [OWChatSummary] = []
        for c in (try? ctx.fetch(d)) ?? [] {
            guard c.hasHistory || c.title.lowercased().contains(q) else { continue }
            if let snip = Self.match(title: c.title, bodies: c.messages.map(\.content), query: q) {
                out.append(OWChatSummary(id: c.id, title: c.title, updatedAt: c.updatedAt,
                    createdAt: c.createdAt, pinned: c.pinned, archived: c.archived, snippet: snip))
            }
        }
        return out
    }

    /// A short excerpt around the first body match (or the title itself if only the
    /// title matched), or nil when nothing matches.
    private static func match(title: String, bodies: [String], query: String) -> String? {
        for body in bodies {
            let lower = body.lowercased()
            if let r = lower.range(of: query) {
                let start = body.index(r.lowerBound, offsetBy: -40, limitedBy: body.startIndex) ?? body.startIndex
                let end = body.index(r.upperBound, offsetBy: 60, limitedBy: body.endIndex) ?? body.endIndex
                let excerpt = body[start..<end].replacingOccurrences(of: "\n", with: " ")
                return (start > body.startIndex ? "…" : "") + excerpt + (end < body.endIndex ? "…" : "")
            }
        }
        return title.lowercased().contains(query) ? title : nil
    }
}
