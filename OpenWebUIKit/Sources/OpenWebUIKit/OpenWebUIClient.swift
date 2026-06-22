import Foundation

/// Talks to the Open WebUI REST API. Auth is a JWT bearer token: a successful
/// `signIn` returns a long-lived token that we persist (Keychain) and replay on
/// every request as `Authorization: Bearer …`. A `401/403` drops the token so
/// the host app can route back to login.
public final class OpenWebUIClient: @unchecked Sendable {
    public private(set) var config: OWConfig
    public let tokens: OWKeychainStore
    public private(set) var token: String?
    public let session: URLSession

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
    }

    public func updateConfig(_ config: OWConfig) { self.config = config }
    public var isAuthenticated: Bool { token != nil }

    // MARK: - Request helpers (internal so sibling clients can reuse them)

    func request(_ path: String, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: config.url(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    func jsonRequest(_ path: String, method: String, body: Encodable) throws -> URLRequest {
        var req = request(path, method: method)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        return req
    }

    @discardableResult
    func send(_ req: URLRequest) async throws -> Data {
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return data }
            if http.statusCode == 401 || http.statusCode == 403 {
                token = nil
                tokens.save(token: nil)
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

    /// Decodes either a bare `[T]` array or a single-key wrapper whose value is
    /// the array (e.g. `{ "data": [...] }`).
    func decodeList<T: Decodable>(_ type: T.Type, _ data: Data) -> [T] {
        if let arr = try? JSONDecoder().decode([T].self, from: data) { return arr }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for v in obj.values {
                if let inner = v as? [Any],
                   let d = try? JSONSerialization.data(withJSONObject: inner),
                   let arr = try? JSONDecoder().decode([T].self, from: d) {
                    return arr
                }
            }
        }
        return []
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

    // MARK: - Models

    /// GET /api/models → `{ data: [...] }`.
    public func models() async throws -> [OWModel] {
        struct Wrap: Decodable { var data: [OWModel] }
        let data = try await send(request("/api/models"))
        if let w = try? JSONDecoder().decode(Wrap.self, from: data) { return w.data }
        return decodeList(OWModel.self, data)
    }

    // MARK: - Chats

    /// GET /api/v1/chats/?page=N — the user's chat list (most-recent first).
    /// NOTE: this list **excludes pinned chats**; fetch those via `pinnedChats()`.
    public func chats(page: Int = 1) async throws -> [OWChatSummary] {
        let data = try await send(request("/api/v1/chats/?page=\(page)"))
        return decodeList(OWChatSummary.self, data)
    }

    /// GET /api/v1/chats/pinned — the user's pinned chats (kept out of the main list).
    public func pinnedChats() async throws -> [OWChatSummary] {
        let data = try await send(request("/api/v1/chats/pinned"))
        return decodeList(OWChatSummary.self, data)
    }

    /// GET /api/v1/chats/{id} — full chat with messages.
    public func chat(_ id: String) async throws -> OWChat {
        try decode(OWChat.self, try await send(request("/api/v1/chats/\(id)")))
    }

    public func deleteChat(_ id: String) async throws {
        _ = try await send(request("/api/v1/chats/\(id)", method: "DELETE"))
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
