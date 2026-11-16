import Foundation
import Network

/// Connection config for an Open WebUI server. A small value type on purpose:
/// the second app (a real-time voice companion that repoints inference to recent
/// GPUs) can aim the same core at a different host without touching anything else.
public struct OWConfig: Sendable, Equatable {
    public var baseURL: URL
    /// The person said, for THIS server, that plain `http://` is acceptable even
    /// though the host is not a local address (a Tailscale name, a LAN domain).
    /// Nothing else in the app sets it: see `ServerConfig.cleartextConsent`.
    public var allowsCleartext: Bool

    public init(baseURL: URL, allowsCleartext: Bool = false) {
        self.baseURL = baseURL
        self.allowsCleartext = allowsCleartext
    }

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

    /// True only for genuine loopback / link-local / RFC-1918 / Tailscale (100.64.0.0/10)
    /// hosts, *.local, unqualified names, or localhost. Parses real IP literals so a public name like `10.evil.com`
    /// (which `hasPrefix("10.")` wrongly matched) is NOT treated as local and is
    /// therefore never downgraded to cleartext http.
    public static func isLocalHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h == "0.0.0.0" || h.hasSuffix(".local") { return true }
        // An unqualified name ("nas", "mac-mini") is one the local resolver or
        // Tailscale's short MagicDNS name answers; it is also exactly what ATS
        // treats as local, so cleartext to it needs no exception.
        if !h.contains("."), !h.contains(":"), IPv4Address(h) == nil { return true }
        if let v4 = IPv4Address(h) {
            let b = [UInt8](v4.rawValue)
            guard b.count == 4 else { return false }
            switch b[0] {
            case 127: return true                              // 127.0.0.0/8
            case 10: return true                               // 10.0.0.0/8
            case 169: return b[1] == 254                       // 169.254.0.0/16
            case 172: return (16...31).contains(Int(b[1]))     // 172.16.0.0/12
            case 100: return (64...127).contains(Int(b[1]))    // 100.64.0.0/10 — Tailscale / CGNAT
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

    /// What plain `http://` means for an address, for the screen that asks the
    /// person and for the guard every request passes through.
    public enum Cleartext: Sendable, Equatable {
        /// `https://`, or not a web address at all.
        case none
        /// `http://` to a local address: the OS lets it through and nothing asks.
        case local
        /// `http://` to a Tailscale name (`*.ts.net`): the tunnel is encrypted, the
        /// OS still refuses the name, so the person must say it is fine.
        case tailnet
        /// `http://` to any other name: readable by everyone on the path.
        case open

        /// Whether the person has to say "I understand" before it is used.
        public var needsConsent: Bool { self == .tailnet || self == .open }
    }

    public static func cleartext(_ url: URL) -> Cleartext {
        guard url.scheme?.lowercased() == "http", let host = url.host?.lowercased() else { return .none }
        if isLocalHost(host) { return .local }
        if host.hasSuffix(".ts.net") { return .tailnet }
        return .open
    }

    /// The one gate for what leaves the app. With the system's own check relaxed
    /// (`NSAllowsArbitraryLoads`, so a person can reach `http://box.ts.net`), this
    /// is what keeps cleartext limited to local addresses and to the single server
    /// the person confirmed.
    public func permits(_ url: URL) -> Bool {
        switch Self.cleartext(url) {
        case .none, .local: return true
        case .tailnet, .open:
            return allowsCleartext && url.host?.lowercased() == baseURL.host?.lowercased()
        }
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
