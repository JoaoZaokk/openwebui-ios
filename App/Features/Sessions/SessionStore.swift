import SwiftUI
import OpenWebUIKit

/// Loads and mutates the user's chat list from Open WebUI.
@MainActor
final class ChatStore: ObservableObject {
    @Published var chats: [OWChatSummary] = []
    @Published var loading = false
    @Published var error: String?

    private let client: OpenWebUIClient
    init(client: OpenWebUIClient) { self.client = client }

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
            // Hide archived; pinned first, then most-recent.
            chats = merged
                .filter { !$0.archived }
                .sorted { lhs, rhs in
                    if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
                    return (lhs.updatedAt ?? 0) > (rhs.updatedAt ?? 0)
                }
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func delete(_ chat: OWChatSummary) async {
        do {
            try await client.deleteChat(chat.id)
            chats.removeAll { $0.id == chat.id }
        } catch { report(error) }
    }

    func pin(_ chat: OWChatSummary) async {
        do { try await client.pinChat(chat.id); await load() } catch { report(error) }
    }

    func archive(_ chat: OWChatSummary) async {
        do { try await client.archiveChat(chat.id); chats.removeAll { $0.id == chat.id } }
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
