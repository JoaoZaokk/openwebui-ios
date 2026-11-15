import Foundation
import Security

// Sign-in through the system browser (Open WebUI 0.13 `/api/v1/auths/sessions`).
//
// GitHub issue #13 — "It doesn't work with authentication using Passkeys
// (WebAuthn). The problem is that you're using a web view instead of the default
// system browser." A web view has no passkeys, no password manager and no
// session of its own to share, so the page that does the signing in has to run
// in the user's browser. 0.13 gives a native client the way back
// (routers/sessions.py): the app asks the server for a login request, sends the
// browser to `/auth/sessions/{id}`, and that page — once the person is signed in
// to the web app by whatever means it offers — ends by navigating to a loopback
// URL the app is listening on, carrying a one-time code the app redeems with its
// PKCE verifier.
//
// What is in this file is the part with no sockets and no UI in it, so it can be
// tested without either: the credentials the server hands out, the shapes its
// validators accept, the page URL, and the reading of what the browser sends to
// the loopback listener.

// MARK: - Credentials

/// What `POST /api/v1/auths/sessions/exchange` and `/refresh` answer with.
///
/// The access token is a session JWT that lives at most 15 minutes
/// (`min(now + 900, row.expires_at)`); the refresh token rotates on every use.
/// One struct decodes the server's body and is what goes into the Keychain, so
/// the pair is always read and written whole — half of a rotation is worthless.
public struct OWAuthSessionCredentials: Codable, Equatable, Sendable {
    /// The server's row id; what `DELETE /sessions/{id}` revokes at sign-out.
    public var sessionID: String
    public var token: String
    public var tokenType: String
    /// Epoch seconds. Nil only if a server leaves it out — never renewed early
    /// then, still renewed when a request is refused.
    public var expiresAt: Int?
    public var refreshToken: String
    public var refreshExpiresAt: Int?

    public init(sessionID: String, token: String, tokenType: String = "Bearer", expiresAt: Int?,
                refreshToken: String, refreshExpiresAt: Int?) {
        self.sessionID = sessionID; self.token = token; self.tokenType = tokenType
        self.expiresAt = expiresAt; self.refreshToken = refreshToken
        self.refreshExpiresAt = refreshExpiresAt
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", token, tokenType = "token_type", expiresAt = "expires_at"
        case refreshToken = "refresh_token", refreshExpiresAt = "refresh_expires_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        token = try c.decode(String.self, forKey: .token)
        tokenType = (try? c.decodeIfPresent(String.self, forKey: .tokenType)) ?? "Bearer"
        expiresAt = try? c.decodeIfPresent(Int.self, forKey: .expiresAt)
        refreshToken = try c.decode(String.self, forKey: .refreshToken)
        refreshExpiresAt = try? c.decodeIfPresent(Int.self, forKey: .refreshExpiresAt)
    }

    /// How early before the stated expiry a token is replaced. A request that
    /// leaves with 10 seconds on its token can reach a server whose clock
    /// disagrees by more than that, and a long upload or a chat stream is judged
    /// at its first byte, not its last.
    public static let refreshLeeway: TimeInterval = 120

    /// True when the access token is expired or will be within `leeway`.
    public func expires(within leeway: TimeInterval, now: Date) -> Bool {
        guard let expiresAt else { return false }
        return Date(timeIntervalSince1970: TimeInterval(expiresAt)).timeIntervalSince(now) <= leeway
    }

    /// Past its stated expiry — what a request sent with it would be refused for.
    public func isExpired(now: Date) -> Bool { expires(within: 0, now: now) }
}

// MARK: - The login request

public enum OWBrowserSignIn {

    /// `AuthorizationRequest.name` is capped at 100 characters server-side.
    public static let nameLimit = 100
    /// A request lives 600 s on the server (`authorization_request`); waiting
    /// longer than that is waiting for an answer that can no longer come.
    public static let timeout: TimeInterval = 600
    /// The one path the listener answers.
    public static let callbackPath = "/callback"

    /// What the user sees in the list of their sessions on the web: the app and
    /// the device, so a stray entry can be told from their own.
    public static func requestName(deviceLabel: String) -> String {
        let label = deviceLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = label.isEmpty ? "Open WebUI" : "Open WebUI · \(label)"
        // The server counts code points, not grapheme clusters.
        return String(String.UnicodeScalarView(full.unicodeScalars.prefix(nameLimit)))
    }

    /// `http://127.0.0.1:<port>/callback` — the shape `AuthorizationRequest.loopback`
    /// accepts: http, the literal 127.0.0.1 (not `localhost`), a port, and no
    /// userinfo, query or fragment.
    public static func redirectURI(port: Int) -> String { "http://127.0.0.1:\(port)\(callbackPath)" }

    /// 32 random bytes as base64url: 43 characters, inside the server's 32–256 of
    /// `[A-Za-z0-9_-]`. (`OWNativeOAuth.newState()` is 16 bytes — 22 characters —
    /// which this server would refuse.)
    public static func newState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }

    public static func isValidState(_ s: String) -> Bool {
        (32...256).contains(s.utf8.count)
            && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A)
                                   || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F }
    }

    /// Whatever the server names as the session is opened in a browser, so it has
    /// to be what the server issues: a UUID.
    public static func isValidSessionID(_ s: String) -> Bool {
        s.count == 36 && UUID(uuidString: s) != nil
    }

    /// `POST /api/v1/auths/sessions/requests`. The model is `extra='forbid'`:
    /// these four keys and nothing else.
    public struct RequestBody: Encodable, Sendable {
        public var name: String
        public var redirectURI: String
        public var state: String
        public var codeChallenge: String
        public init(name: String, redirectURI: String, state: String, codeChallenge: String) {
            self.name = name; self.redirectURI = redirectURI
            self.state = state; self.codeChallenge = codeChallenge
        }
        enum CodingKeys: String, CodingKey {
            case name, redirectURI = "redirect_uri", state, codeChallenge = "code_challenge"
        }
    }

    /// `POST /api/v1/auths/sessions/exchange`.
    public struct ExchangeBody: Encodable, Sendable {
        public var sessionID: String
        public var code: String
        public var codeVerifier: String
        public var redirectURI: String
        public init(sessionID: String, code: String, codeVerifier: String, redirectURI: String) {
            self.sessionID = sessionID; self.code = code
            self.codeVerifier = codeVerifier; self.redirectURI = redirectURI
        }
        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id", code, codeVerifier = "code_verifier", redirectURI = "redirect_uri"
        }
    }

    /// The page the browser opens: `{base}/auth/sessions/{id}`, with
    /// `?provider=<key>` when the person tapped one provider's button — the page
    /// then goes straight to that provider's OAuth instead of the sign-in form
    /// (src/routes/auth/sessions/[id]/+page.svelte). The key is one the server
    /// listed in `/api/config`; it is encoded as a single query value regardless.
    public static func pageURL(config: OWConfig, sessionID: String, provider: String?) -> URL {
        var path = "/auth/sessions/"
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        path += sessionID.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let page = config.url(path)
        guard let provider, !provider.isEmpty else { return page }
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        let value = provider.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        return URL(string: page.absoluteString + "?provider=" + value) ?? page
    }
}

// MARK: - The listener's side

/// What a loopback listener does with the first line of each request it gets.
///
/// The server's page ends with `location.assign(redirect_uri?code=…&state=…)`
/// (sessions.py `authorize`). Anything else that can reach `127.0.0.1:<port>` —
/// the favicon request that follows, a page in another tab, a port scanner — is
/// not the answer, and must neither complete the sign-in nor be able to end it.
public enum OWLoopbackCallback {

    public enum Outcome: Equatable, Sendable {
        /// The server's page came back with a code and our state.
        case completed(code: String)
        /// The server named a failure (our state attached).
        case failed(String)
        /// Our state, no code.
        case missingCode
        /// A callback whose state is not ours, or has none.
        case badState
        /// Another path, another method.
        case notFound
        /// Not an HTTP request line at all.
        case malformed

        /// Whether the wait is over. Everything that is not the server's own
        /// answer is turned away and the listener carries on.
        public var isTerminal: Bool {
            switch self {
            case .completed, .failed, .missingCode: return true
            case .badState, .notFound, .malformed:  return false
            }
        }
    }

    /// A request line is `GET /callback?code=…&state=… HTTP/1.1`; a JWT code and
    /// a 43-character state fit comfortably in 8 KB, a peer that sends more is
    /// not the server's page.
    public static let maxRequestLine = 8192

    /// The first line of the request once its end has arrived; nil while it is
    /// still arriving; `""` (which `evaluate` calls malformed) when it never
    /// ends within `maxRequestLine`.
    public static func requestLine(in buffer: Data) -> String? {
        if let end = buffer.firstIndex(of: 0x0A) {
            let length = end - buffer.startIndex
            guard length <= maxRequestLine else { return "" }
            var line = buffer[buffer.startIndex..<end]
            if line.last == 0x0D { line = line.dropLast() }
            return String(decoding: line, as: UTF8.self)
        }
        return buffer.count > maxRequestLine ? "" : nil
    }

    public static func evaluate(requestLine: String, expectedState: String) -> Outcome {
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else { return .malformed }
        let target = parts[1]
        guard target.hasPrefix("/") else { return .malformed }
        guard parts[0] == "GET" else { return .notFound }

        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        guard path == OWBrowserSignIn.callbackPath else { return .notFound }
        guard let comps = URLComponents(string: "http://127.0.0.1" + target) else { return .malformed }
        let items = comps.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }

        // First, before anything else is read — the same order the Google path
        // keeps. An error with no state of ours is anybody's.
        guard !expectedState.isEmpty, let state = value("state"),
              constantTimeEquals(state, expectedState) else { return .badState }
        if let error = value("error") { return .failed(value("error_description") ?? error) }
        guard let code = value("code") else { return .missingCode }
        return .completed(code: code)
    }

    /// Compares without stopping at the first difference. The state is a secret
    /// for as long as the listener is up, and the listener is reachable by
    /// anything on the machine.
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(truncatingIfNeeded: x.count ^ y.count) | UInt8(truncatingIfNeeded: (x.count ^ y.count) >> 8)
        for i in 0..<max(x.count, y.count) {
            diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
        }
        return diff == 0 && x.count == y.count
    }

    // MARK: The answer

    /// The whole HTTP response for an outcome: a small page in the app's
    /// language, never cached, with no script and no outside resource — and
    /// `Referrer-Policy: no-referrer`, because the address this page was reached
    /// at carries a login code.
    public static func response(for outcome: Outcome) -> Data {
        let status: String, title: String, lines: [String]
        switch outcome {
        case .completed:
            status = "200 OK"
            title = L("Login concluído")
            lines = [L("Você já pode voltar ao app.")]
        case .failed(let why):
            status = "200 OK"
            title = L("Não foi possível entrar")
            lines = [why, L("Volte ao app e tente de novo.")]
        case .missingCode:
            status = "400 Bad Request"
            title = L("Não foi possível entrar")
            lines = [L("Volte ao app e tente de novo.")]
        case .badState, .malformed:
            status = "400 Bad Request"
            title = L("Pedido inválido")
            lines = []
        case .notFound:
            status = "404 Not Found"
            title = L("Página não encontrada")
            lines = []
        }
        let paragraphs = lines.map { "<p>\(escape($0))</p>" }.joined()
        let html = """
        <!doctype html><html><head><meta charset="utf-8">\
        <meta name="viewport" content="width=device-width,initial-scale=1">\
        <meta name="color-scheme" content="light dark"><meta name="referrer" content="no-referrer">\
        <title>\(escape(title))</title>\
        <style>body{font:17px -apple-system,system-ui,sans-serif;display:flex;align-items:center;\
        justify-content:center;min-height:100vh;margin:0;text-align:center}\
        main{padding:24px;max-width:28em}h1{font-size:1.4em;margin:0 0 .6em}p{margin:.3em 0;opacity:.7}</style>\
        </head><body><main><h1>\(escape(title))</h1>\(paragraphs)</main></body></html>
        """
        let body = Data(html.utf8)
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: text/html; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Referrer-Policy: no-referrer\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

// MARK: - The host

/// The two things only a phone can do — listen on loopback, and put a page in
/// the system browser — behind the one seam the flow needs, so the order of the
/// steps can be tested without either.
///
/// The app's implementation is `App/Features/Auth/BrowserSignInHost.swift`
/// (`NWListener` bound to 127.0.0.1, `ASWebAuthenticationSession`).
public protocol OWBrowserSignInHost: AnyObject, Sendable {
    /// Starts listening on 127.0.0.1 and returns the port the OS chose. Must be
    /// up before the server is told where to send the browser.
    func startListener() async throws -> Int
    /// Opens `pageURL` in the system browser and suspends until the listener has
    /// received a callback whose state is `expectedState` — returning its code —
    /// or the person closes the browser (`CancellationError`), or the server's
    /// page reports a failure. Must give up after `OWBrowserSignIn.timeout`.
    func present(pageURL: URL, expectedState: String) async throws -> String
    /// Closes the listener and the browser sheet. Called on every way out;
    /// calling it twice is harmless.
    func stop() async
}

extension OWServerConfig {
    /// `features.auth_sessions` (main.py:2478) — this server has the sessions
    /// routes. A server that says nothing is an older one: the web-view and
    /// native-Google paths stay exactly as they were.
    public var browserSignInAvailable: Bool { features?.authSessions ?? false }
}

// MARK: - Keychain

extension OWKeychainStore {
    static let credentialsKey = "session.credentials"

    /// The browser-session pair, stored as one item so a rotation is one write.
    public func loadCredentials() -> OWAuthSessionCredentials? {
        guard let raw = Self.get(Self.credentialsKey, service: serviceName),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OWAuthSessionCredentials.self, from: data)
    }

    /// Saves the pair and keeps `session.token` equal to its access token, so
    /// anything that still reads the older item finds the live token. Nil removes
    /// the pair only; the plain token is the caller's to clear.
    @discardableResult
    public func save(credentials: OWAuthSessionCredentials?) -> Bool {
        guard let credentials, let data = try? JSONEncoder().encode(credentials),
              let raw = String(data: data, encoding: .utf8) else {
            return Self.delete(Self.credentialsKey, service: serviceName)
        }
        let ok = Self.set(raw, key: Self.credentialsKey, service: serviceName)
        save(token: credentials.token)
        return ok
    }
}
