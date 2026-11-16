import Foundation
import OpenWebUIKit

/// Persists which Open WebUI server the app talks to (UserDefaults) and bridges
/// to the package's `OWConfig`. Defaults to the user's instance.
struct ServerConfig: Equatable {
    var baseURL: URL

    private static let key = "openwebui.baseURL"

    static func load() -> ServerConfig {
        let stored = UserDefaults.standard.string(forKey: key)
        let url = stored.flatMap { URL(string: $0) } ?? OWConfig.defaultBaseURL
        return ServerConfig(baseURL: url)
    }

    /// Whether the user has actually saved a server (vs. the placeholder default).
    /// Drives the first-run prompt so nobody tries to log into the placeholder.
    static var isConfigured: Bool { UserDefaults.standard.string(forKey: key) != nil }

    func save() { UserDefaults.standard.set(baseURL.absoluteString, forKey: Self.key) }

    /// The server name the UI shows. Debug captures against the local stub
    /// replace it (`-screenshotHost`) so no screen reads 127.0.0.1.
    var displayHost: String {
        #if DEBUG
        if let h = ScreenshotRoute.hostLabel { return h }
        #endif
        return baseURL.host ?? baseURL.absoluteString
    }

    /// Bridge to the package's connection config.
    var owConfig: OWConfig { OWConfig(baseURL: baseURL, allowsCleartext: Self.hasCleartextConsent(baseURL)) }

    // MARK: Plain http:// to a named server
    //
    // The system's own check (ATS) is relaxed in Info.plist so that a person can
    // reach `http://box.tail1234.ts.net:3000`; what replaces it is this: cleartext
    // to anything but a local address goes out only for a server the person
    // confirmed on the Servidor screen, one entry per host:port, and only to it
    // (`OWConfig.permits`).

    private static let consentKey = "security.cleartextServers"

    private static func consentID(_ url: URL) -> String {
        "\(url.host?.lowercased() ?? ""):\(url.port ?? 80)"
    }

    static func hasCleartextConsent(_ url: URL) -> Bool {
        (UserDefaults.standard.stringArray(forKey: consentKey) ?? []).contains(consentID(url))
    }

    static func setCleartextConsent(_ granted: Bool, for url: URL) {
        var all = Set(UserDefaults.standard.stringArray(forKey: consentKey) ?? [])
        if granted { all.insert(consentID(url)) } else { all.remove(consentID(url)) }
        UserDefaults.standard.set(Array(all).sorted(), forKey: consentKey)
    }

    /// Normalizes free-form input ("openwebui.example.com", "http://10.0.0.5:8080").
    static func normalize(_ input: String) -> URL? { OWConfig.normalize(input) }
}
