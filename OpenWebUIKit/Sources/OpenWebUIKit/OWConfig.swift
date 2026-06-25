import Foundation
import Network

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

    /// Only http/https are ever accepted (no file://, data:, custom schemes).
    public static let allowedSchemes: Set<String> = ["http", "https"]

    /// True only for genuine loopback / link-local / RFC-1918 hosts, *.local, or
    /// localhost. Parses real IP literals so a public name like `10.evil.com`
    /// (which `hasPrefix("10.")` wrongly matched) is NOT treated as local and is
    /// therefore never downgraded to cleartext http.
    public static func isLocalHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h == "0.0.0.0" || h.hasSuffix(".local") { return true }
        if let v4 = IPv4Address(h) {
            let b = [UInt8](v4.rawValue)
            guard b.count == 4 else { return false }
            switch b[0] {
            case 127: return true                              // 127.0.0.0/8
            case 10: return true                               // 10.0.0.0/8
            case 169: return b[1] == 254                       // 169.254.0.0/16
            case 172: return (16...31).contains(Int(b[1]))     // 172.16.0.0/12
            case 192: return b[1] == 168                       // 192.168.0.0/16
            default: return false
            }
        }
        if let v6 = IPv6Address(h) {
            if v6 == IPv6Address("::1") { return true }
            let first = [UInt8](v6.rawValue).first ?? 0
            return (first & 0xfe) == 0xfc                       // fc00::/7
        }
        return false
    }

    /// Normalizes free-form user input ("openwebui.example.com", "10.0.0.5:8080")
    /// into a usable base URL. Real local addresses get plain **http**; everything
    /// else defaults to **https**. Non-http(s) schemes are rejected.
    public static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") {
            let bare = s.split(whereSeparator: { $0 == "/" || $0 == ":" }).first.map(String.init) ?? s
            s = (isLocalHost(bare) ? "http://" : "https://") + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let host = url.host, !host.isEmpty,
              let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else { return nil }
        return url
    }
}
