import CryptoKit
import Foundation

/// The pieces of a native OAuth sign-in that are worth testing on their own:
/// the PKCE pair, the authorization URL, and reading the code back out of the
/// callback.
///
/// This exists because Open WebUI's own OAuth flow cannot end inside
/// `ASWebAuthenticationSession`. That API hands back only a URL, and only one
/// matching a scheme the app registered — while the server ends its flow by
/// redirecting to its own `https` origin with the session in a **cookie**. So the
/// system sign-in sheet, the one that reuses Safari's session and offers the
/// account already signed in, is unreachable through the server's flow.
///
/// The way to it is to talk to the identity provider directly: the app runs its
/// own PKCE authorization with a public client of its own, and trades the
/// provider's access token for an Open WebUI session at
/// `POST /api/v1/auths/oauth/{provider}/token/exchange` — which answers with the
/// JWT in the body and no cookie at all.
public enum OWNativeOAuth {

    /// A PKCE pair. The verifier stays in memory; only its hash leaves the device
    /// on the authorization request, so an intercepted code is useless without it.
    public struct PKCE: Sendable, Equatable {
        public let verifier: String
        public var challenge: String { OWNativeOAuth.challenge(for: verifier) }

        public init(verifier: String) { self.verifier = verifier }

        /// RFC 7636 asks for 43–128 characters from the unreserved set.
        public init() {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            self.verifier = Data(bytes).base64URLEncoded
        }
    }

    /// S256: the challenge is the SHA-256 of the verifier's ASCII bytes,
    /// base64url without padding.
    public static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }

    /// Google requires an iOS client's redirect to be the reversed client id.
    /// Derived rather than configured, so the two can never drift apart.
    ///
    /// `123-abc.apps.googleusercontent.com` → `com.googleusercontent.apps.123-abc`
    public static func googleRedirectScheme(clientID: String) -> String? {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix) else { return nil }
        return "com.googleusercontent.apps." + String(clientID.dropLast(suffix.count))
    }

    public static func googleRedirectURI(clientID: String) -> String? {
        googleRedirectScheme(clientID: clientID).map { $0 + ":/oauth2redirect" }
    }

    /// The URL the sign-in sheet opens.
    public static func authorizationURL(endpoint: URL, clientID: String, redirectURI: String,
                                        scope: String, state: String, pkce: PKCE) -> URL? {
        guard var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            // Ask for the account chooser rather than silently reusing whichever
            // account Safari happens to be signed into.
            .init(name: "prompt", value: "select_account"),
        ]
        return c.url
    }

    public enum CallbackError: Error, Equatable {
        /// The provider refused, and said why.
        case provider(String)
        /// A reply whose `state` is not the one we sent is not our reply.
        case stateMismatch
        case noCode
    }

    /// Pulls the authorization code out of the redirect the sheet came back with.
    public static func code(from url: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let error = value("error") {
            throw CallbackError.provider(value("error_description") ?? error)
        }
        // Checked before the code is read: a reply carrying someone else's state
        // is not an answer to our request, whatever else it carries.
        guard value("state") == expectedState else { throw CallbackError.stateMismatch }
        guard let code = value("code") else { throw CallbackError.noCode }
        return code
    }

    /// Opaque value tying the reply to this request.
    public static func newState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }
}

extension Data {
    /// base64url, unpadded — the encoding every part of PKCE is specified in.
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
