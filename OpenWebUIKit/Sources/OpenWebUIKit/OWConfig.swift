import Foundation

/// Connection config for an Open WebUI server. A small value type on purpose:
/// the second app (a real-time voice companion that repoints inference to recent
/// GPUs) can aim the same core at a different host without touching anything else.
public struct OWConfig: Sendable, Equatable {
    public var baseURL: URL

    public init(baseURL: URL) { self.baseURL = baseURL }

    /// The user's self-hosted instance (Open WebUI 0.9.6, behind Cloudflare).
    public static let defaultBaseURL = URL(string: "https://openwebui.example.com")!

    public static let `default` = OWConfig(baseURL: defaultBaseURL)

    /// Resolves an absolute API URL. We use `URL(string:relativeTo:)` instead of
    /// `appendingPathComponent` so query strings survive — `?` and `&` must not
    /// be percent-escaped into the path (the bug that broke half the Odysseus
    /// spaces). An absolute "/api/..." path replaces only the base's path.
    public func url(_ path: String) -> URL {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path) ?? baseURL
        }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL ?? baseURL
    }

    /// Normalizes free-form user input ("openwebui.example.com", "10.0.0.5:8080")
    /// into a usable base URL. When no scheme is given we pick one by host: local
    /// addresses (localhost, LAN IPs, *.local) are plain **http**; everything else
    /// defaults to **https** — so a domain works and a home server doesn't fail.
    public static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") {
            let bare = s.split(whereSeparator: { $0 == "/" || $0 == ":" }).first.map(String.init) ?? s
            let isLocal = bare == "localhost" || bare == "0.0.0.0" || bare.hasSuffix(".local")
                || bare.hasPrefix("127.") || bare.hasPrefix("10.") || bare.hasPrefix("192.168.")
            s = (isLocal ? "http://" : "https://") + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.host != nil else { return nil }
        return url
    }
}
