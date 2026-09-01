import AuthenticationServices
import Foundation
import OpenWebUIKit

/// Sign-in through the system sheet — the one that says "«App» wants to use
/// google.com to sign in", shows the account you are already signed into, and
/// fills the password from the keychain.
///
/// It is unreachable through Open WebUI's own OAuth flow.
/// `ASWebAuthenticationSession` hands back exactly one thing, a URL matching a
/// scheme the app registered, and the server ends its flow by redirecting to its
/// own `https` origin with the session in a **cookie**. No scheme, no URL, nothing
/// to hand back. That is why the other path uses an embedded web view, and why
/// that path asks for the email every time: an embedded web view has its own
/// cookie jar, separate from Safari's, so the provider has never seen it.
///
/// This path goes around the server instead. The app runs its own PKCE
/// authorization directly against the provider with a public client of its own,
/// then trades the provider's access token for an Open WebUI session at
/// `/api/v1/auths/oauth/{provider}/token/exchange`, which answers in the body.
///
/// Needs two things that are not the app's to arrange, so it stays switched off
/// until both are true — and the web-view path keeps working meanwhile:
/// - an **iOS** OAuth client (`OWGoogleOAuthClientID` in Info.plist). A web
///   client will not do: Google refuses a custom scheme for one, and its token
///   endpoint demands a secret, which must never ship inside an app.
/// - `ENABLE_OAUTH_TOKEN_EXCHANGE` on the server. Without it the exchange is a
///   403, and this reports that rather than pretending.
@MainActor
enum NativeSSO {

    /// Google's endpoints. Fixed rather than discovered: the redirect below is
    /// derived from Google's own client-id format, so this path is already
    /// Google-shaped and discovery would only hide that.
    private static let authorizeEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    private static let scope = "openid email profile"

    /// The iOS OAuth client, or nil when none is configured. Not a secret — an
    /// iOS client has none, and Google binds it to the bundle id — but a fork
    /// with its own bundle id needs its own.
    static var googleClientID: String? {
        (Bundle.main.object(forInfoDictionaryKey: "OWGoogleOAuthClientID") as? String)
            .flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
    }

    /// Whether the system sheet can be offered for this provider.
    static func isAvailable(provider: String) -> Bool {
        provider.lowercased() == "google" && googleClientID != nil
    }

    enum Failure: Error, LocalizedError {
        case notConfigured
        case provider(String)
        case noToken

        var errorDescription: String? {
            switch self {
            case .notConfigured:  return L("Não foi possível concluir o login.")
            case .provider(let m): return m
            case .noToken:        return L("Não foi possível concluir o login.")
            }
        }
    }

    /// Runs the whole thing and returns the provider's access token, ready to be
    /// traded for a session.
    static func signIn(provider: String, anchor: ASPresentationAnchor?) async throws -> String {
        guard let clientID = googleClientID,
              let redirectURI = OWNativeOAuth.googleRedirectURI(clientID: clientID),
              let scheme = OWNativeOAuth.googleRedirectScheme(clientID: clientID)
        else { throw Failure.notConfigured }

        let pkce = OWNativeOAuth.PKCE()
        let state = OWNativeOAuth.newState()
        guard let url = OWNativeOAuth.authorizationURL(
            endpoint: authorizeEndpoint, clientID: clientID, redirectURI: redirectURI,
            scope: scope, state: state, pkce: pkce)
        else { throw Failure.notConfigured }

        let callback = try await present(url: url, scheme: scheme, anchor: anchor)
        let code = try OWNativeOAuth.code(from: callback, expectedState: state)
        return try await accessToken(code: code, verifier: pkce.verifier,
                                     clientID: clientID, redirectURI: redirectURI)
    }

    /// The system sheet. Deliberately **not** ephemeral: sharing Safari's session
    /// is the entire point — it is what turns "type your email again" into "pick
    /// the account you are already signed into".
    private static func present(url: URL, scheme: String,
                                anchor: ASPresentationAnchor?) async throws -> URL {
        let context = PresentationContext(anchor: anchor)
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback { continuation.resume(returning: callback) }
                else if let error { continuation.resume(throwing: error) }
                else { continuation.resume(throwing: Failure.noToken) }
            }
            session.presentationContextProvider = context
            session.prefersEphemeralWebBrowserSession = false
            // Held by the closure so it outlives this scope.
            withExtendedLifetime(context) { _ = session.start() }
        }
    }

    /// Trades the authorization code for the provider's access token. No client
    /// secret: an iOS client has none, and PKCE is what stands in for it.
    private static func accessToken(code: String, verifier: String,
                                    clientID: String, redirectURI: String) async throws -> String {
        var req = URLRequest(url: tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            .init(name: "code", value: code),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code_verifier", value: verifier),
        ]
        req.httpBody = form.percentEncodedQuery.map { Data($0.utf8) }

        let (data, resp) = try await URLSession.shared.data(for: req)
        struct Token: Decodable {
            var access_token: String?
            var error: String?
            var error_description: String?
        }
        let decoded = try? JSONDecoder().decode(Token.self, from: data)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.provider(decoded?.error_description ?? decoded?.error
                                   ?? L("Erro %@", String(http.statusCode)))
        }
        guard let token = decoded?.access_token, !token.isEmpty else { throw Failure.noToken }
        return token
    }

    private final class PresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
        private let anchor: ASPresentationAnchor?
        init(anchor: ASPresentationAnchor?) { self.anchor = anchor }
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            anchor ?? ASPresentationAnchor()
        }
    }
}
