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

    /// Bridge to the package's connection config.
    var owConfig: OWConfig { OWConfig(baseURL: baseURL) }

    /// Normalizes free-form input ("openwebui.example.com", "http://10.0.0.5:8080").
    static func normalize(_ input: String) -> URL? { OWConfig.normalize(input) }
}
