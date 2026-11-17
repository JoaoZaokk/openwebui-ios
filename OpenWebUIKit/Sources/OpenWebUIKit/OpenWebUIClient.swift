import Foundation
import Network

/// Talks to the Open WebUI REST API. Auth is a JWT bearer token: a successful
/// `signIn` returns a long-lived token that we persist (Keychain) and replay on
/// every request as `Authorization: Bearer …`. A `401` drops the token and posts
/// `sessionEndedNotification` so the host app can route back to login.
public final class OpenWebUIClient: @unchecked Sendable {
    public private(set) var config: OWConfig
    public let tokens: OWKeychainStore
    /// The bearer token requests go out with: the session JWT of a password or
    /// SSO sign-in, or the access token of a browser session (`credentials`).
    /// Written under `authLock`; read bare, as it always was.
    public internal(set) var token: String?
    /// Set only for a session made through the system browser
    /// (`signInThroughBrowser`): a 15-minute access token plus a rotating refresh
    /// token. Nil for every other kind of session, which keeps its long-lived
    /// token and its old behaviour exactly.
    public internal(set) var credentials: OWAuthSessionCredentials?
    /// Guards `token`/`credentials` and the refresh bookkeeping below. Never held
    /// across an `await`.
    let authLock = NSLock()
    /// The refresh in flight, if any: every request that needs a new token while
    /// it runs waits for this one instead of starting its own — the server spends
    /// the refresh token on the first, and the second would be refused.
    var refreshTask: Task<OWAuthSessionCredentials, Error>?
    /// The `request_id` sent with the refresh of `refreshToken`. A rotation whose
    /// answer was lost is retried with the same id, which is how the server knows
    /// it is the same rotation (`refresh_retry`) and replies instead of refusing.
    var pendingRefresh: (refreshToken: String, requestID: UUID)?
    /// When the current credentials arrived in this process; nil if they were
    /// loaded from the Keychain.
    var credentialsReceivedAt: Date?
    /// Identifies the session the client holds. Bumped, under `authLock`, every
    /// time that session is forgotten, dropped or replaced. A refresh captures it
    /// before it goes to the network and commits only if it is unchanged, so an
    /// answer that arrives after a sign-out, a server switch or a new sign-in
    /// can neither write its pair back nor end the session that replaced it
    /// (Auth review #2/#5).
    var sessionGeneration = 0
    /// Bumped, under `authLock`, when the client is pointed at a different
    /// origin. A sign-in whose answer arrives after that came from the old
    /// server and must not be adopted as the new server's session (Auth #11).
    /// Separate from `sessionGeneration` on purpose: an unrelated 401 dropping
    /// the session while the user types a password is not a reason to discard
    /// that password's sign-in.
    var originGeneration = 0
    /// True when the newest pair is in memory but the Keychain refused it, twice.
    /// The next request tries to persist it again (Auth review #4).
    var credentialsUnsaved = false
    /// True while `signOut` runs, so the 401 its own refresh may meet is not
    /// announced as a session that ended on the user.
    var signingOut = false
    /// The clock, replaceable so a test can make a token old without waiting.
    var now: @Sendable () -> Date = { Date() }
    public let session: URLSession
    /// Session for long transfers (SSE streams, generation, uploads) — no 30s resource cap.
    public let longSession: URLSession

    /// - Parameter protocolClasses: the transport. `nil` — the default, and the
    ///   only thing the app itself ever passes — is Foundation's own chain. A test
    ///   passes a `URLProtocol` subclass and the whole request stack becomes
    ///   reachable without a server: both sessions, the 401 hop, the 2xx guard,
    ///   `detail(from:)`, `decodeList`, and the SSE byte stream. The seam sits
    ///   *under* the concrete type, not in front of it: no protocol is declared,
    ///   and the single production construction site is untouched.
    public init(config: OWConfig = .default, tokens: OWKeychainStore = OWKeychainStore(),
                protocolClasses: [AnyClass]? = nil) {
        self.config = config
        self.tokens = tokens
        let stored = tokens.loadCredentials()
        self.credentials = stored
        self.token = stored?.token ?? tokens.loadToken()
        // A refresh whose answer may have been lost with the previous process
        // is retried with the SAME request id (Auth review #1); only meaningful
        // for the refresh token it was sent with.
        if let stored, let p = tokens.loadPendingRefresh(), p.refreshToken == stored.refreshToken,
           let id = UUID(uuidString: p.requestID) {
            self.pendingRefresh = (p.refreshToken, id)
        }
        let cfg = Self.sessionConfiguration(protocolClasses: protocolClasses)
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 30   // cap the whole request — never hang forever
        self.session = URLSession(configuration: cfg)
        // Long transfers (SSE chat streams, image generation, uploads, TTS/STT).
        // `timeoutIntervalForResource` caps the WHOLE transfer regardless of the
        // per-request `timeoutInterval` — on the 30s session a chat reply
        // streaming past 30s wall-clock was killed mid-stream and a slow image
        // generation could never finish. (Same fix as Odysseus 9fe0712.)
        let longCfg = Self.sessionConfiguration(protocolClasses: protocolClasses)
        longCfg.timeoutIntervalForRequest = 300    // idle gap between bytes
        longCfg.timeoutIntervalForResource = 7200  // total wall-clock
        self.longSession = URLSession(configuration: longCfg)
    }

    /// What both sessions share; they differ only in their timeouts. One
    /// function so the transport cannot be handed to one session and forgotten
    /// on the other. `URLProtocol.registerClass` is deliberately not the
    /// mechanism: it does not reach a session built from
    /// `URLSessionConfiguration.default`, which both of these are.
    private static func sessionConfiguration(protocolClasses: [AnyClass]?) -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = .shared           // OWUI also sets a cookie; harmless to keep
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.waitsForConnectivity = false      // fail fast with an error instead of waiting endlessly
        if let protocolClasses { cfg.protocolClasses = protocolClasses }
        return cfg
    }

    /// Posted when the server rejects the stored token (HTTP 401). The host app
    /// listens so a session that dies mid-use routes back to login instead of
    /// leaving every screen showing "Sessão expirada" over a dead token.
    public static let sessionEndedNotification = Notification.Name("OWSessionEnded")

    /// The server's own version string, once `/api/config` has been read. Two
    /// write paths change shape around it, so it is not cosmetic — see
    /// `mergesHistoryServerSide`.
    public private(set) var serverVersion: String?
    private var serverInfoFetched = false
    /// Bumped whenever `baseURL` changes. An `/api/config` answer only counts if
    /// the client still points where it was asked: a slow reply from the
    /// previous server landing after a switch would otherwise re-arm the
    /// merge gate with that server's version — and on a 0.10 server a write
    /// that omits a node deletes the message.
    private var configGeneration = 0

    public func updateConfig(_ config: OWConfig) {
        // Read before the origin branch below, which adopts the new URL itself.
        let baseChanged = config.baseURL != self.config.baseURL
        // A token is a credential for the host that issued it. Pointing the client
        // at a different origin while holding it means the very next request —
        // including the unauthenticated-looking ones — replays the user's JWT to a
        // machine that never saw it. Same host, different path, is the same server.
        if Self.origin(config.baseURL) != Self.origin(self.config.baseURL) {
            // Before the new URL is adopted, so this clears the OLD host's jar:
            // the Keychain is not the only place a session lives.
            clearCookies()
            // Forgetting the session and adopting the new URL are ONE step. A
            // refresh snapshots its credentials and the URL under this same lock
            // (`performRefresh`); with the two apart it could read the old pair
            // and the new server and send one to the other (Auth review #5).
            authLock.lock()
            clearSessionLocked()
            originGeneration &+= 1
            self.config = config
            authLock.unlock()
            tokens.clear()
        }
        // What the *previous* server said about itself is not an answer about this
        // one. `ensureServerInfo` sets its flag before its await, so a version left
        // behind here would never be asked for again — and the merge gate would go
        // on answering for the old server. On a 0.10 server that answer omits a
        // node from a write, and omitting a node there deletes the message.
        if baseChanged {
            serverVersion = nil
            serverInfoFetched = false
            configGeneration &+= 1
        }
        authLock.withLock { self.config = config }
    }

    /// Forgets the cookies the configured server set.
    ///
    /// Open WebUI issues a `token` cookie alongside the bearer token, both
    /// sessions here share `HTTPCookieStorage.shared`, and nothing in this
    /// client ever emptied it. `signOut` sends its request with `try?` — a user
    /// on a plane still means it — so offline the Keychain was cleared while a
    /// live cookie for the server's host stayed on disk, ready to sign them
    /// straight back in. Switching servers left it behind for the same reason.
    ///
    /// A cookie set for `example.com` is stored with the domain `.example.com`,
    /// so the match is on the bare domain: the host itself, or any host under
    /// it. `notexample.com` is a different host, not a suffix of one.
    func clearCookies() {
        guard let host = config.baseURL.host?.lowercased(), !host.isEmpty else { return }
        let jar = HTTPCookieStorage.shared
        for cookie in jar.cookies ?? [] {
            let domain = cookie.domain.lowercased()
            let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            guard !bare.isEmpty else { continue }
            if host == bare || host.hasSuffix("." + bare) { jar.deleteCookie(cookie) }
        }
    }

    /// True when `url` lives on the configured server. Anything the server hands
    /// us as an image or file location is data, not instruction — it may be an
    /// absolute URL to somewhere else entirely.
    func isSameOrigin(_ url: URL) -> Bool {
        Self.origin(url) == Self.origin(config.baseURL)
    }

    static func origin(_ url: URL) -> String {
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let scheme = (c?.scheme ?? "").lowercased()
        let host = (c?.host ?? "").lowercased()
        let port = c?.port.map(String.init) ?? (scheme == "http" ? "80" : "443")
        return "\(scheme)://\(host):\(port)"
    }

    /// Internal, not private: `ChatCompletionsClient.stream` holds `longSession`
    /// directly and never passes through `send`, so it has to run this hop
    /// itself. Deliberately NOT called from the image loader — a 401 on one
    /// picture must not log anyone out.
    ///
    /// - Parameter generation: when given, the drop happens only if the session
    ///   is still the one the caller saw. A refresh that learns, late, that the
    ///   OLD session is dead must not wipe the one that replaced it. Returns
    ///   whether it acted.
    @discardableResult
    func dropSession(ifGeneration generation: Int? = nil) -> Bool {
        authLock.lock()
        if let generation, generation != sessionGeneration { authLock.unlock(); return false }
        let quiet = signingOut
        clearSessionLocked()
        // Inside the lock: a session adopted right after must not find its
        // Keychain items deleted by the drop of the one before it.
        tokens.save(token: nil)
        tokens.save(credentials: nil)
        tokens.save(pendingRefresh: nil)
        authLock.unlock()
        if !quiet { NotificationCenter.default.post(name: Self.sessionEndedNotification, object: nil) }
        return true
    }

    /// Clears what the process holds for the session; returns whether a sign-out
    /// in progress asked for silence.
    @discardableResult
    func forgetSessionInMemory() -> Bool {
        authLock.lock(); defer { authLock.unlock() }
        clearSessionLocked()
        return signingOut
    }

    /// The one place the session is forgotten. The caller holds `authLock`.
    /// Cancelling and releasing the refresh in flight is what keeps it from being
    /// joined by whoever signs in next (it would hand them the old session's
    /// token) — and, with `sessionGeneration`, from writing anything back.
    func clearSessionLocked() {
        token = nil
        credentials = nil
        credentialsReceivedAt = nil
        pendingRefresh = nil
        credentialsUnsaved = false
        sessionGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Takes on a session that has no refresh token — the JWT a password, LDAP,
    /// OAuth-exchange or MFA sign-in returned, or one adopted from the web view.
    /// A browser session's pair, if there was one, goes: a refresh token left
    /// behind a token that is no longer its own would renew the wrong session.
    ///
    /// - Parameter origin: the `originGeneration` the sign-in began under. If the
    ///   client was pointed at another server since, the token belongs to the
    ///   old one and is not adopted (returns false) — Auth review #11.
    @discardableResult
    func adoptLegacyToken(_ t: String, ifOrigin origin: Int? = nil) -> Bool {
        authLock.lock()
        if let origin, origin != originGeneration { authLock.unlock(); return false }
        clearSessionLocked()
        token = t
        tokens.save(credentials: nil)
        tokens.save(pendingRefresh: nil)
        tokens.save(token: t)
        authLock.unlock()
        return true
    }

    func currentOriginGeneration() -> Int { authLock.withLock { originGeneration } }

    public var isAuthenticated: Bool { token != nil }

    // MARK: - Request helpers (internal so sibling clients can reuse them)

    func request(_ path: String, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: config.url(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    /// Percent-encodes a server-supplied id for safe use as a single URL path
    /// segment (escapes `/ ? #`), so a malicious chat/note/file id can't smuggle
    /// path/query separators into an authenticated request.
    func encPath(_ s: String) -> String { encPathSegment(s) }

    func encPathSegment(_ s: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    func jsonRequest(_ path: String, method: String, body: Encodable) throws -> URLRequest {
        var req = request(path, method: method)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        return req
    }

    /// Plain `http://` leaves only for a local address or for the one server the
    /// person confirmed (`OWConfig.permits`). The system's own check is relaxed so
    /// that confirmation can exist at all; this is what stands in for it.
    func permit(_ req: URLRequest) throws {
        guard let url = req.url, !config.permits(url) else { return }
        throw OWError.transport(L("Conexão HTTP sem confirmação para %@. Abra Servidor e confirme o uso de HTTP.",
                                  url.host ?? ""))
    }

    /// Opens a connection to the host only to learn how the Local Network prompt
    /// was answered: `true` once the path is usable, `false` if the permission was
    /// refused (the path says so at once) or nothing was answered in `seconds`.
    static func localNetworkAnswered(_ url: URL, within seconds: TimeInterval) async -> Bool {
        guard let host = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? (url.scheme == "https" ? 443 : 80)))
        else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = Once()
            let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            let finish: @Sendable (Bool) -> Void = { answer in
                guard once.first() else { return }
                conn.cancel()
                cont.resume(returning: answer)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed: finish(false)
                case .waiting:
                    if conn.currentPath?.unsatisfiedReason == .localNetworkDenied { finish(false) }
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { finish(false) }
        }
    }

    @discardableResult
    func send(_ req: URLRequest, long: Bool = false) async throws -> Data {
        try await send(req, long: long, mayRenew: true, mayWaitForLocalNetwork: true)
    }

    /// `mayRenew` is the retry budget: a 401 for a session made through the
    /// browser is answered with one refresh and one more try, never a loop.
    private func send(_ original: URLRequest, long: Bool, mayRenew: Bool,
                      mayWaitForLocalNetwork: Bool) async throws -> Data {
        do {
            // Whatever token the request was built with, it leaves with a live one.
            let req = try await withFreshToken(original)
            try permit(req)
            let (data, resp) = try await (long ? longSession : session).data(for: req)
            guard let http = resp as? HTTPURLResponse else { return data }
            // 401 is "this token is dead"; 403 is "this account may not do that"
            // — Open WebUI answers 403 for a non-admin hitting an admin route, a
            // model outside the user's access control, or a feature permission it
            // lacks. Folding the two together logged the user out over a mere
            // permission denial and showed "Sessão expirada" for it. Only 401
            // drops the session.
            if http.statusCode == 401 {
                // Open WebUI also answers 401 for a chat that does not exist or is
                // not the caller's (routers/chats.py `get_chat_by_id` raises 401
                // with ERROR_MESSAGES.NOT_FOUND) — the same number it uses for a
                // dead token. Opening a conversation deleted on the web therefore
                // logged the user out. Only the token case ends the session; the
                // other is a 404 wearing the wrong number, and is reported as one.
                let detail = Self.detail(from: data)
                if detail == Self.serverNotFoundSentence { throw OWError.http(404, detail) }
                // `check_notes_access` (routers/notes.py) answers 401 with
                // ERROR_MESSAGES.UNAUTHORIZED when the admin took the notes
                // permission away mid-session: a 403 wearing the wrong number.
                // A dead token never says that — it says 'Not authenticated' or
                // 'Invalid token' — so on the notes routes this sentence is a
                // permission refusal: no rotation spent, nobody signed out
                // (Auth review #12). The notes tool reports it to the model.
                if Self.isNotesPermissionRefusal(path: req.url?.path, detail: detail) {
                    throw OWError.http(403, detail)
                }
                // A browser session's access token lives minutes, so a 401 is
                // usually just its age: renew and ask again, once. (Nil for every
                // other kind of session, which falls through exactly as before.)
                if mayRenew, let retry = try await renewedRequest(after: req) {
                    return try await send(retry, long: long, mayRenew: false, mayWaitForLocalNetwork: mayWaitForLocalNetwork)
                }
                dropSession()
                throw OWError.notAuthenticated
            }
            guard (200..<300).contains(http.statusCode) else {
                throw OWError.http(http.statusCode, Self.detail(from: data))
            }
            return data
        } catch let e as OWError {
            throw e
        } catch {
            if error.isCancellation {
                throw CancellationError()
            }
            // First contact with a local server: iOS fails the request while its
            // "find devices on your local network" prompt is still on screen, and
            // the person's answer arrives a moment too late for it. Wait for the
            // answer once and ask again; if it was "Don't Allow" the wait ends at
            // once and the message below says where the switch is.
            if mayWaitForLocalNetwork, (error as? URLError)?.isLocalNetworkProhibited == true,
               let url = original.url, await Self.localNetworkAnswered(url, within: 20) {
                return try await send(original, long: long, mayRenew: mayRenew, mayWaitForLocalNetwork: false)
            }
            // `OWFailure.msg`, not `localizedDescription`: the sentence chosen
            // here is the one the banner shows, and Foundation writes its own in
            // the device's language, not the app's.
            throw OWError.transport(OWFailure.msg(error))
        }
    }

    func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw OWError.decoding(String(describing: error)) }
    }

    /// Decodes a list endpoint: a bare `[T]`, or the array under `key` when the
    /// endpoint wraps it (`{ "data": [...] }`, `{ "items": [...] }`).
    ///
    /// It throws now, and that is the point. Every failure used to become an empty
    /// list with no error, so a login portal's HTML answered with 200, a truncated
    /// body or a shape change all rendered as "you have nothing" — the same screen
    /// a genuinely empty account gets, with nothing to tell them apart. Eleven
    /// endpoints shared that.
    ///
    /// What still returns `[]`, deliberately: an empty body, a literal `null`
    /// (0.11 answers 200 `null` from the image routes on real paths), `[]`, and
    /// `{}`. Those are answers, not failures.
    ///
    /// The old wrapper fallback — scan `obj.values` for anything array-shaped — is
    /// gone. `Dictionary.values` has no defined order, and an empty array under any
    /// key decodes as `[T]` for every `T`, so `{"items": […], "errors": []}` could
    /// return the wrong one, differently between runs. The key is named per
    /// endpoint instead, with the bare array still accepted for older servers.
    func decodeList<T: Decodable>(_ type: T.Type, _ data: Data, key: String? = nil) throws -> [T] {
        let trimmed = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if data.isEmpty || trimmed?.isEmpty == true { return [] }

        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { throw OWError.decoding(Self.notJSON(data)) }

        if root is NSNull { return [] }
        if let arr = root as? [Any] { return try Self.decodeElements(type, arr) }
        guard let obj = root as? [String: Any] else {
            throw OWError.decoding("unexpected root")
        }
        if obj.isEmpty { return [] }
        guard let key else { throw OWError.decoding("expected a list, got an object") }
        guard let inner = obj[key] as? [Any] else { throw OWError.decoding("missing `\(key)`") }
        return try Self.decodeElements(type, inner)
    }

    /// Per-element, so one exotic row doesn't erase the collection — but all of
    /// them failing means the body is something else entirely, not a stray row.
    private static func decodeElements<T: Decodable>(_ type: T.Type, _ raw: [Any]) throws -> [T] {
        guard !raw.isEmpty else { return [] }
        guard let d = try? JSONSerialization.data(withJSONObject: raw),
              let lossy = try? JSONDecoder().decode([OWLossy<T>].self, from: d) else {
            throw OWError.decoding("undecodable list")
        }
        let out = lossy.compactMap(\.value)
        if out.isEmpty { throw OWError.decoding("0 of \(raw.count) items decoded") }
        return out
    }

    /// A short, quotable head of a body that isn't JSON — an auth portal's HTML
    /// answered with 200 is the case worth naming.
    private static func notJSON(_ data: Data) -> String {
        let head = String(data: data.prefix(120), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ") ?? "\(data.count) bytes"
        return head.isEmpty ? "\(data.count) bytes" : head
    }

    /// `ERROR_MESSAGES.NOT_FOUND` in the server's constants.py — verbatim, because
    /// it is the only thing that tells this 401 from a real one.
    static let serverNotFoundSentence = "We could not find what you're looking for :/"

    /// `ERROR_MESSAGES.UNAUTHORIZED` in constants.py.
    static let serverUnauthorizedSentence = "401 Unauthorized"

    static func isNotesPermissionRefusal(path: String?, detail: String?) -> Bool {
        guard let path, path == "/api/v1/notes" || path.hasPrefix("/api/v1/notes/") else { return false }
        return detail?.trimmingCharacters(in: .whitespacesAndNewlines) == serverUnauthorizedSentence
    }

    /// What of a non-JSON body may be shown as the server's sentence. An HTML
    /// page — a captive portal, a proxy's error page — is not one, and neither is
    /// anything long: it would land verbatim in the login and MFA screens
    /// (Auth review #7). A short plain-text line such as '502 Bad Gateway' is
    /// still more useful than 'Erro 502'.
    static let plainDetailLimit = 200

    static func detail(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let s = OWErrorSentence.sentence(data) { return s }
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("<") { return nil }
            return trimmed.count > plainDetailLimit ? String(trimmed.prefix(plainDetailLimit)) + "…" : text
        }
        // FastAPI validation errors: detail = [{ loc, msg, … }]
        if let arr = obj["detail"] as? [[String: Any]] {
            let msgs = arr.compactMap { e -> String? in
                let field = (e["loc"] as? [Any])?.compactMap { "\($0)" }.last { $0 != "body" }
                let msg = e["msg"] as? String
                switch (field, msg) {
                case let (f?, m?): return "\(f): \(m)"
                case let (_, m?):  return m
                default:           return nil
                }
            }
            if !msgs.isEmpty { return msgs.joined(separator: " · ") }
        }
        return OWErrorSentence.sentence(in: obj)
    }

    // MARK: - Auth

    /// POST /api/v1/auths/signin — stores the bearer token on success.
    ///
    /// Throws `OWError.mfaRequired` / `.pendingApproval` when the server answers
    /// with a step instead of a session; `signInResult` returns those as values
    /// for a caller that has a screen for them.
    @discardableResult
    public func signIn(email: String, password: String) async throws -> OWUser {
        try user(from: try await signInResult(email: email, password: password))
    }

    public func signInResult(email: String, password: String) async throws -> OWSignInResult {
        var req = request("/api/v1/auths/signin", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(OWSignInForm(email: email, password: password))
        let origin = currentOriginGeneration()
        try permit(req)
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw OWError.http(http.statusCode, Self.detail(from: data))
        }
        return try accept(try OWSignInResult.decode(data), origin: origin)
    }

    /// A session is taken on (token stored); a step is returned untouched, with
    /// nothing stored — a challenge is not a session.
    ///
    /// `origin` is what `currentOriginGeneration()` said before the request went
    /// out: an answer from a server the client no longer points at is dropped
    /// (as a cancellation) instead of becoming the new server's session.
    private func accept(_ result: OWSignInResult, origin: Int) throws -> OWSignInResult {
        if case .session(let s) = result {
            guard adoptLegacyToken(s.token, ifOrigin: origin) else { throw CancellationError() }
        }
        return result
    }

    /// The user a finished sign-in names, or the step it stopped at as an error.
    private func user(from result: OWSignInResult) throws -> OWUser {
        switch result {
        case .session(let s): return OWUser(session: s)
        case .mfa(let challenge): throw OWError.mfaRequired(challenge)
        case .pending: throw OWError.pendingApproval
        }
    }

    /// GET /api/v1/auths/ — current user; throws `.notAuthenticated` if the
    /// persisted token is no longer valid.
    public func me() async throws -> OWUser {
        try decode(OWUser.self, try await send(request("/api/v1/auths/")))
    }

    /// Where the browser flow starts. The server redirects to the identity
    /// provider from here and handles the code exchange itself
    /// (backend main.py:2794).
    public func oauthLoginURL(provider: String) -> URL {
        config.url("/oauth/\(encPathSegment(provider))/login")
    }

    /// Whether a URL the browser flow landed on is where Open WebUI finishes.
    ///
    /// The callback ends with a redirect to `{WEBUI_URL or base}/auth` carrying
    /// the session in a cookie (oauth.py:2155).
    ///
    /// The path has to be `/auth` exactly, unless the host is the server's own.
    /// A bare `hasSuffix("/auth")` — added so a server mounted under a sub-path
    /// would still be recognised — matched
    /// `accounts.google.com/o/oauth2/v2/auth`, which is Google's authorization
    /// endpoint and the *first* place the flow goes. Signing in with Google
    /// cancelled itself on the way out and reported no session, every time.
    public func isOAuthCompletion(_ url: URL) -> Bool {
        Self.isOAuthCompletion(url, serverHost: config.baseURL.host)
    }

    static func isOAuthCompletion(_ url: URL, serverHost: String?) -> Bool {
        let path = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
        if path == "/auth" { return true }
        // A sub-path install only counts on the server's own host — never on an
        // identity provider's.
        guard let serverHost, let host = url.host,
              host.caseInsensitiveCompare(serverHost) == .orderedSame else { return false }
        return path.hasSuffix("/auth")
    }

    /// The failure the server redirected with, if it did (`/auth?error=…`).
    public static func oauthError(in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "error" }?.value
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Takes on a token obtained outside the password flow — the cookie the SSO
    /// callback set, or an API key the user pasted — and only keeps it if the
    /// server agrees it is a session.
    ///
    /// Deliberately built by hand instead of going through `send`: a rejected
    /// candidate would otherwise trip the 401 path and throw away the perfectly
    /// good session the user already had.
    @discardableResult
    public func adopt(token candidate: String) async throws -> OWUser {
        var req = URLRequest(url: config.url("/api/v1/auths/"))
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(candidate)", forHTTPHeaderField: "Authorization")
        let origin = currentOriginGeneration()
        try permit(req)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw OWError.transport("no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw OWError.http(http.statusCode, Self.detail(from: data))
        }
        let user = try decode(OWUser.self, data)
        guard adoptLegacyToken(candidate, ifOrigin: origin) else { throw CancellationError() }
        return user
    }

    /// Trades an identity provider's access token for an Open WebUI session.
    ///
    /// `POST /api/v1/auths/oauth/{provider}/token/exchange` (auths.py:1588). The
    /// server validates the token by calling the provider's own `userinfo`, then
    /// answers with the JWT **in the body** — no cookie. That is what makes the
    /// system sign-in sheet usable at all: everything it can hand back is a URL,
    /// and the server's own flow ends in a cookie.
    ///
    /// Two refusals worth telling apart, because neither is the user's fault and
    /// only one is fixable by them:
    /// - 403 `Token exchange is disabled` — the admin has not set
    ///   `ENABLE_OAUTH_TOKEN_EXCHANGE` (auths.py:1600).
    /// - 403 `User not found. Please sign in via the web interface first.` — this
    ///   endpoint never creates accounts (auths.py:1712), so the first sign-in for
    ///   a person has to happen in a browser.
    @discardableResult
    public func exchangeOAuthToken(provider: String, providerToken: String) async throws -> OWUser {
        try user(from: try await exchangeOAuthTokenResult(provider: provider, providerToken: providerToken))
    }

    /// The same exchange, answering with the step the server stopped at instead
    /// of throwing for it: with MFA on and no OAuth bypass the exchange returns a
    /// challenge (utils/auth.py:693), and a pending account returns `pending`.
    public func exchangeOAuthTokenResult(provider: String, providerToken: String) async throws -> OWSignInResult {
        struct Form: Encodable { var token: String }
        var req = request("/api/v1/auths/oauth/\(encPathSegment(provider))/token/exchange",
                          method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Form(token: providerToken))
        let origin = currentOriginGeneration()
        try permit(req)
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw OWError.http(http.statusCode, Self.detail(from: data))
        }
        return try accept(try OWSignInResult.decode(data), origin: origin)
    }

    /// POST /api/v1/auths/ldap — same session response as `signin`, different
    /// credential store. Offered only when `/api/config` says the server has LDAP.
    @discardableResult
    public func signInLDAP(user name: String, password: String) async throws -> OWUser {
        try user(from: try await signInLDAPResult(user: name, password: password))
    }

    public func signInLDAPResult(user name: String, password: String) async throws -> OWSignInResult {
        struct Form: Encodable { var user: String; var password: String }
        var req = request("/api/v1/auths/ldap", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Form(user: name, password: password))
        let origin = currentOriginGeneration()
        try permit(req)
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw OWError.http(http.statusCode, Self.detail(from: data))
        }
        return try accept(try OWSignInResult.decode(data), origin: origin)
    }

    public func signOut() async {
        if credentials != nil {
            await revokeBrowserSession()
        } else {
            _ = try? await send(request("/api/v1/auths/signout"))
        }
        forgetSessionInMemory()
        tokens.clear()
        clearCookies()
    }

    /// GET /api/config. Reports what this server actually offers (login form,
    /// LDAP, OAuth providers, signup), which is how the login screen decides what
    /// to draw instead of assuming email+password.
    ///
    /// Public, but it answers more to a signed-in request: `enable_notes`,
    /// `enable_memories` and `enable_web_search` are only in the `features` the
    /// server builds `if user is not None` (main.py:2521). So the token goes
    /// along when there is one. A server that refuses it (401 "Invalid token")
    /// gets the same request without — the public answer is still the answer the
    /// login screen needs — and the session is left to `me()`, which is the call
    /// that decides whether the token is dead.
    public func serverConfig() async throws -> OWServerConfig {
        var req = URLRequest(url: config.url("/api/config"))
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let asked = configGeneration
        var body: Data?
        // `freshToken`, not `token`: a browser session's access token lives 15
        // minutes, and a cold launch is the moment it is most likely to be dead.
        // This answer is the one that carries `enable_notes`/`enable_memories`;
        // sent with an expired token the server answers as for nobody, the
        // public config is used, and the two features stayed off until the next
        // launch (Auth review #8). A refresh the server refuses has already
        // ended the session by now; the public answer is still the right one.
        if authLock.withLock({ token }) != nil, let live = try? await freshToken() {
            var signedIn = req
            signedIn.setValue("Bearer \(live)", forHTTPHeaderField: "Authorization")
            if let (data, resp) = try? await session.data(for: signedIn),
               let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                body = data
            }
        }
        let data: Data
        if let body { data = body } else { data = try await send(req) }
        let cfg = try decode(OWServerConfig.self, data)
        if asked == configGeneration {
            serverVersion = cfg.version
            serverInfoFetched = true
        }
        return cfg
    }

    /// Reads `/api/config` once per server, swallowing failure — callers use this
    /// only to choose between two safe behaviours, never to gate the request.
    func ensureServerInfo() async {
        guard !serverInfoFetched else { return }
        serverInfoFetched = true
        _ = try? await serverConfig()
    }

    /// True when this server merges an incoming `history` by message id instead of
    /// replacing the whole chat blob — `Chats.update_chat_by_id` gained
    /// `merge_history` in 0.11.0 (backend models/chats.py:894).
    ///
    /// It decides whether omitting a message from a write is safe. On 0.11 omitting
    /// **preserves** the server's copy, which is how this client refuses to
    /// overwrite a reply someone else is still streaming. On 0.10 and earlier the
    /// same omission **deletes** the message, so those servers must keep receiving
    /// every node back. Unknown version is treated as old: never delete on a guess.
    var mergesHistoryServerSide: Bool { Self.mergesHistory(version: serverVersion) }

    /// Split out as a pure function so the rule can be tested without a server.
    static func mergesHistory(version: String?) -> Bool {
        guard let version else { return false }
        let parts = version.split(separator: ".").prefix(2).map { part -> Int? in
            let digits = part.prefix(while: \.isNumber)
            return digits.isEmpty ? nil : Int(digits)
        }
        guard parts.count == 2, let major = parts[0], let minor = parts[1] else { return false }
        return (major, minor) >= (0, 11)
    }

    // MARK: - Models

    /// GET /api/models → `{ data: [...] }`.
    public func models() async throws -> [OWModel] {
        try decodeList(OWModel.self, try await send(request("/api/models")), key: "data")
    }

    // MARK: - Chats

    /// GET /api/v1/chats/?page=N — the user's chat list (most-recent first).
    ///
    /// `include_pinned` is false by server default, which is why `pinnedChats()`
    /// exists and gets merged in. `include_folders` stays at its default too:
    /// chats filed in a folder belong to the folder section (`chats(inFolder:)`),
    /// exactly as on the web. Until 1.13 this asked for them flat because the app
    /// had no folder UI to put them behind; with one, asking for them made every
    /// moved chat show up twice (report from 1.14).
    ///
    /// Still one page of 60. There is no "load more" yet.
    public func chats(page: Int = 1) async throws -> [OWChatSummary] {
        let data = try await send(request("/api/v1/chats/?page=\(page)"))
        return try decodeList(OWChatSummary.self, data)
    }

    /// GET /api/v1/chats/pinned — the user's pinned chats (kept out of the main list).
    public func pinnedChats() async throws -> [OWChatSummary] {
        let data = try await send(request("/api/v1/chats/pinned"))
        return try decodeList(OWChatSummary.self, data)
    }

    /// GET /api/v1/chats/{id} — full chat with messages.
    public func chat(_ id: String) async throws -> OWChat {
        try decode(OWChat.self, try await send(request("/api/v1/chats/\(encPath(id))")))
    }

    public func deleteChat(_ id: String) async throws {
        _ = try await send(request("/api/v1/chats/\(encPath(id))", method: "DELETE"))
    }

    // NOTE: persisting new turns (POST /api/v1/chats/new and POST
    // /api/v1/chats/{id}) lands with the chat send-flow — the exact message-object
    // shape (history map + parentId chain) is worth verifying against the live
    // 0.9.6 instance first to avoid corrupting the branching history.
}

/// Type-erased Encodable so `jsonRequest` accepts any Encodable body.
struct AnyEncodable: Encodable {
    private let encodeFunc: (Encoder) throws -> Void
    init(_ wrapped: Encodable) { encodeFunc = wrapped.encode }
    func encode(to encoder: Encoder) throws { try encodeFunc(encoder) }
}

/// True exactly once: the guard that lets several callbacks race to resume one
/// continuation.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func first() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
