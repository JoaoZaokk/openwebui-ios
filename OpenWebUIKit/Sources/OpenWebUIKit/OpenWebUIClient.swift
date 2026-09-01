import Foundation

/// Talks to the Open WebUI REST API. Auth is a JWT bearer token: a successful
/// `signIn` returns a long-lived token that we persist (Keychain) and replay on
/// every request as `Authorization: Bearer …`. A `401` drops the token and posts
/// `sessionEndedNotification` so the host app can route back to login.
public final class OpenWebUIClient: @unchecked Sendable {
    public private(set) var config: OWConfig
    public let tokens: OWKeychainStore
    public private(set) var token: String?
    public let session: URLSession
    /// Session for long transfers (SSE streams, generation, uploads) — no 30s resource cap.
    public let longSession: URLSession

    public init(config: OWConfig = .default, tokens: OWKeychainStore = OWKeychainStore()) {
        self.config = config
        self.tokens = tokens
        self.token = tokens.loadToken()
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = .shared           // OWUI also sets a cookie; harmless to keep
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 30   // cap the whole request — never hang forever
        cfg.waitsForConnectivity = false      // fail fast with an error instead of waiting endlessly
        self.session = URLSession(configuration: cfg)
        // Long transfers (SSE chat streams, image generation, uploads, TTS/STT).
        // `timeoutIntervalForResource` caps the WHOLE transfer regardless of the
        // per-request `timeoutInterval` — on the 30s session a chat reply
        // streaming past 30s wall-clock was killed mid-stream and a slow image
        // generation could never finish. (Same fix as Odysseus 9fe0712.)
        let longCfg = URLSessionConfiguration.default
        longCfg.httpCookieStorage = .shared
        longCfg.httpCookieAcceptPolicy = .always
        longCfg.httpShouldSetCookies = true
        longCfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        longCfg.timeoutIntervalForRequest = 300    // idle gap between bytes
        longCfg.timeoutIntervalForResource = 7200  // total wall-clock
        longCfg.waitsForConnectivity = false
        self.longSession = URLSession(configuration: longCfg)
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

    public func updateConfig(_ config: OWConfig) {
        // A token is a credential for the host that issued it. Pointing the client
        // at a different origin while holding it means the very next request —
        // including the unauthenticated-looking ones — replays the user's JWT to a
        // machine that never saw it. Same host, different path, is the same server.
        if Self.origin(config.baseURL) != Self.origin(self.config.baseURL) {
            token = nil
            tokens.clear()
        }
        self.config = config
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

    private func dropSession() {
        token = nil
        tokens.save(token: nil)
        NotificationCenter.default.post(name: Self.sessionEndedNotification, object: nil)
    }

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

    @discardableResult
    func send(_ req: URLRequest, long: Bool = false) async throws -> Data {
        do {
            let (data, resp) = try await (long ? longSession : session).data(for: req)
            guard let http = resp as? HTTPURLResponse else { return data }
            // 401 is "this token is dead"; 403 is "this account may not do that"
            // — Open WebUI answers 403 for a non-admin hitting an admin route, a
            // model outside the user's access control, or a feature permission it
            // lacks. Folding the two together logged the user out over a mere
            // permission denial and showed "Sessão expirada" for it. Only 401
            // drops the session.
            if http.statusCode == 401 {
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
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw OWError.transport(error.localizedDescription)
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

    static func detail(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
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
        return obj["detail"] as? String ?? obj["message"] as? String ?? obj["error"] as? String
    }

    // MARK: - Auth

    /// POST /api/v1/auths/signin — stores the bearer token on success.
    @discardableResult
    public func signIn(email: String, password: String) async throws -> OWUser {
        var req = request("/api/v1/auths/signin", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(OWSignInForm(email: email, password: password))
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw OWError.http(http.statusCode, Self.detail(from: data))
        }
        let s = try decode(OWSession.self, data)
        token = s.token
        tokens.save(token: s.token)
        return OWUser(session: s)
    }

    /// GET /api/v1/auths/ — current user; throws `.notAuthenticated` if the
    /// persisted token is no longer valid.
    public func me() async throws -> OWUser {
        try decode(OWUser.self, try await send(request("/api/v1/auths/")))
    }

    public func signOut() async {
        _ = try? await send(request("/api/v1/auths/signout"))
        token = nil
        tokens.clear()
    }

    /// GET /api/config — public, no `Authorization`. Reports what this server
    /// actually offers (login form, LDAP, OAuth providers, signup), which is how
    /// the login screen decides what to draw instead of assuming email+password.
    public func serverConfig() async throws -> OWServerConfig {
        var req = URLRequest(url: config.url("/api/config"))
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let cfg = try decode(OWServerConfig.self, try await send(req))
        serverVersion = cfg.version
        serverInfoFetched = true
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
    /// Two server defaults hide conversations from this list, and both have to be
    /// answered or the chat is simply unreachable from the app. `include_pinned`
    /// is false, which is why `pinnedChats()` exists and gets merged in.
    /// `include_folders` is false too (`get_chat_title_id_list_by_user_id` filters
    /// `folder_id=None`), so filing a chat into a folder in the web UI made it
    /// vanish from the phone entirely — same failure as the pinned one, and this
    /// client has no folder UI to put it back behind, so it asks for them flat.
    ///
    /// Still one page of 60. There is no "load more" yet.
    public func chats(page: Int = 1) async throws -> [OWChatSummary] {
        let data = try await send(request("/api/v1/chats/?page=\(page)&include_folders=true"))
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
