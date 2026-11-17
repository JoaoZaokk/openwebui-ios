import Foundation

/// Find-in-conversation. The browser's page search does this on the web;
/// the app has no page to search, so it matches the messages themselves.
public enum ChatFind {
    /// Ids of the messages whose visible text contains `query`, in conversation
    /// order. Case and accents are ignored ("franca" finds "França"). The model's
    /// collapsed reasoning is not searched: a hit the reader cannot see would
    /// scroll to a bubble that shows nothing.
    public static func matchingIDs(_ query: String, in messages: [OWMessage]) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return messages.filter {
            $0.content.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }.map(\.id)
    }

    /// The match to show after moving `delta` places from `index`, wrapping at
    /// both ends. 0 when there is nothing to move through.
    public static func step(from index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }
}
