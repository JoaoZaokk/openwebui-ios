import Foundation

// Browser sessions (Open WebUI 0.13 `/api/v1/auths/sessions`) and the MFA step.
//
// The access token of such a session lives at most 15 minutes, and its refresh
// token is single-use: every refresh returns the next one. Everything in the
// first half of this file exists so that a client which may have a dozen
// requests in flight, a phone that drops off the network mid-rotation, and a
// process that can be killed between any two lines, never ends up holding a
// refresh token the server has already spent.

extension OpenWebUIClient {

    // MARK: - The one entry point for "a token that works"

    /// The bearer token to use right now, renewed first if it expires within
    /// `OWAuthSessionCredentials.refreshLeeway`.
    ///
    /// Every place that puts a token on a request goes through this (or through
    /// `withFreshToken`, which wraps it): `send` (so every REST call, uploads,
    /// speech and image generation included), the chat stream, and the image
    /// loader. For a session that has no refresh token it is just `token`.
    ///
    /// A renewal that merely could not be done — no network, a 5xx — is not
    /// fatal while the token still has time on it: the request goes out with the
    /// token in hand. Once the token has expired there is nothing to send, so the
    /// failure is thrown. A refresh the server answers with 401 means the session
    /// is gone, and that is thrown (after the sign-out path has run) either way.
    public func freshToken() async throws -> String? {
        let held = snapshotCredentials()
        guard let held else { return authToken() }
        guard held.expires(within: OWAuthSessionCredentials.refreshLeeway, now: now()) else { return held.token }
        do {
            return try await refreshSingleFlight().token
        } catch OWError.notAuthenticated {
            throw OWError.notAuthenticated
        } catch {
            if error is CancellationError || error.isCancellation { throw CancellationError() }
            if held.isExpired(now: now()) { throw error }
            return snapshotCredentials()?.token ?? held.token
        }
    }

    /// The request with its `Authorization` header replaced by a live token — a
    /// request is built (with the token of that moment) before it is sent, and
    /// the wait in between is exactly when a token ages.
    func withFreshToken(_ req: URLRequest) async throws -> URLRequest {
        guard snapshotCredentials() != nil, req.value(forHTTPHeaderField: "Authorization") != nil,
              let t = try await freshToken() else { return req }
        var r = req
        r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        return r
    }

    /// What to send after the server answered `req` with 401: the same request
    /// with a new token — or nil when no renewal applies (no refresh token, or
    /// `minimumAge` says the token is too new to be merely old), in which case a
    /// 401 means what it always meant.
    ///
    /// If the token the request carried is no longer the current one, someone
    /// else has already renewed it: that renewal is used and nothing is spent.
    /// Throws what the refresh throws; its 401 has already ended the session.
    func renewedRequest(after req: URLRequest, minimumAge: TimeInterval = 0) async throws -> URLRequest? {
        guard let header = req.value(forHTTPHeaderField: "Authorization"), header.hasPrefix("Bearer ") else { return nil }
        let rejected = String(header.dropFirst("Bearer ".count))
        guard let t = try await renewToken(rejected: rejected, minimumAge: minimumAge) else { return nil }
        var r = req
        r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        return r
    }

    func renewToken(rejected: String, minimumAge: TimeInterval) async throws -> String? {
        guard let held = snapshotCredentials() else { return nil }
        if held.token != rejected { return held.token }
        if minimumAge > 0, let at = authReceivedAt(), now().timeIntervalSince(at) < minimumAge {
            return nil
        }
        return try await refreshSingleFlight().token
    }

    // MARK: - Refresh, single flight

    private func refreshSingleFlight() async throws -> OWAuthSessionCredentials {
        let task: Task<OWAuthSessionCredentials, Error> = authLock.withLock {
            if let running = refreshTask { return running }
            let started = Task<OWAuthSessionCredentials, Error> { [self] in
                defer { authLock.withLock { refreshTask = nil } }
                return try await performRefresh()
            }
            refreshTask = started
            return started
        }
        // The shared task is not the caller's child: one caller giving up must
        // not cancel the rotation the others are waiting on.
        return try await task.value
    }

    private func performRefresh() async throws -> OWAuthSessionCredentials {
        guard let held = snapshotCredentials() else { throw OWError.notAuthenticated }
        let requestID: UUID = authLock.withLock {
            if let p = pendingRefresh, p.refreshToken == held.refreshToken { return p.requestID }
            let id = UUID()
            pendingRefresh = (held.refreshToken, id)
            return id
        }

        struct Form: Encodable { var refresh_token: String; var request_id: String }
        var req = URLRequest(url: config.url("/api/v1/auths/sessions/refresh"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Form(refresh_token: held.refreshToken,
                                                     request_id: requestID.uuidString))
        let data: Data
        do {
            data = try await post(req)
        } catch OWError.http(401, _) {
            // The server says this session is over: revoked, idle past its
            // expiry, or the refresh token already spent. The only answer that
            // signs anyone out.
            dropSession()
            throw OWError.notAuthenticated
        }
        let fresh = try decode(OWAuthSessionCredentials.self, data)
        // The server has spent the old refresh token by now. The new pair goes to
        // the Keychain BEFORE anything uses it: killed between the two, the next
        // launch must find the pair that works.
        tokens.save(credentials: fresh)
        authLock.withLock {
            credentials = fresh
            token = fresh.token
            credentialsReceivedAt = now()
            pendingRefresh = nil
        }
        return fresh
    }

    // MARK: - Small shared pieces

    func snapshotCredentials() -> OWAuthSessionCredentials? { authLock.withLock { credentials } }
    private func authToken() -> String? { authLock.withLock { token } }
    private func authReceivedAt() -> Date? { authLock.withLock { credentialsReceivedAt } }

    /// One request through `session`, with the failure shapes the rest of the
    /// client uses: HTTP errors carry the server's own sentence, cancellation is
    /// `CancellationError`, and a transport failure is `OWError.transport`.
    /// Deliberately not `send`: these are the calls that have no session to lose
    /// or are the ones that renew it.
    func post(_ req: URLRequest) async throws -> Data {
        do {
            let (data, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw OWError.http(http.statusCode, Self.detail(from: data))
            }
            return data
        } catch let e as OWError {
            throw e
        } catch {
            if error.isCancellation { throw CancellationError() }
            throw OWError.transport(OWFailure.msg(error))
        }
    }

    private func jsonPOST(_ path: String, _ body: Encodable) throws -> URLRequest {
        var req = URLRequest(url: config.url(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        return req
    }

    // MARK: - Signing out

    /// Best effort, and quiet: DELETE the server's row so the session ends there
    /// too, not only here. An expired access token is renewed first or the
    /// revocation would be refused — and if even that is refused the session is
    /// gone already, which is what was wanted.
    func revokeBrowserSession() async {
        guard let held = snapshotCredentials() else { return }
        authLock.withLock { signingOut = true }
        defer { authLock.withLock { signingOut = false } }
        let access: String?
        do { access = try await freshToken() }
        catch OWError.notAuthenticated { access = nil }
        catch { access = held.token }
        guard let access else { return }
        var req = URLRequest(url: config.url("/api/v1/auths/sessions/\(encPathSegment(held.sessionID))"))
        req.httpMethod = "DELETE"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: req)
    }

    // MARK: - The browser sign-in

    /// POST /api/v1/auths/sessions/requests → the id of the login request. Public:
    /// nobody is signed in yet, and the server throttles it per address.
    public func createBrowserRequest(name: String, redirectURI: String,
                                     state: String, codeChallenge: String) async throws -> String {
        struct Reply: Decodable { var session_id: String }
        let req = try jsonPOST("/api/v1/auths/sessions/requests", OWBrowserSignIn.RequestBody(
            name: name, redirectURI: redirectURI, state: state, codeChallenge: codeChallenge))
        let reply = try decode(Reply.self, try await post(req))
        // It is about to be opened in a browser: only a UUID is.
        guard OWBrowserSignIn.isValidSessionID(reply.session_id) else {
            throw OWError.decoding("session_id")
        }
        return reply.session_id
    }

    /// POST /api/v1/auths/sessions/exchange — redeems the code the browser page
    /// ended with, proving possession of the PKCE verifier.
    public func exchangeBrowserSession(sessionID: String, code: String, codeVerifier: String,
                                       redirectURI: String) async throws -> OWAuthSessionCredentials {
        let req = try jsonPOST("/api/v1/auths/sessions/exchange", OWBrowserSignIn.ExchangeBody(
            sessionID: sessionID, code: code, codeVerifier: codeVerifier, redirectURI: redirectURI))
        return try decode(OWAuthSessionCredentials.self, try await post(req))
    }

    /// Takes on a browser session — only if the server confirms it.
    ///
    /// Built by hand for the same reason `adopt(token:)` is: a candidate the
    /// server refuses must not trip the 401 path and throw away the session the
    /// user already had. Persisted before it is used, like every rotation.
    @discardableResult
    public func adopt(credentials candidate: OWAuthSessionCredentials) async throws -> OWUser {
        var req = URLRequest(url: config.url("/api/v1/auths/"))
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(candidate.token)", forHTTPHeaderField: "Authorization")
        let user = try decode(OWUser.self, try await post(req))
        tokens.save(credentials: candidate)
        authLock.withLock {
            credentials = candidate
            token = candidate.token
            credentialsReceivedAt = now()
            pendingRefresh = nil
        }
        return user
    }

    /// The whole browser sign-in; see `OWBrowserSignInHost`.
    ///
    /// The listener comes up first because the request has to name its port. The
    /// PKCE verifier never leaves memory until the exchange; only its hash goes
    /// out with the request, so a code intercepted on the way back is useless
    /// without it. The host is stopped on every way out.
    ///
    /// - Parameter provider: the key from `/api/config`'s `oauth.providers` when
    ///   the person tapped one provider's button, nil for "sign in with the
    ///   browser" in general (passkeys, the password form, anything the page has).
    @discardableResult
    public func signInThroughBrowser(host: OWBrowserSignInHost, deviceName: String,
                                     provider: String?) async throws -> OWUser {
        var stopped = false
        do {
            let port = try await host.startListener()
            let redirectURI = OWBrowserSignIn.redirectURI(port: port)
            let state = OWBrowserSignIn.newState()
            let pkce = OWNativeOAuth.PKCE()
            let sessionID = try await createBrowserRequest(
                name: deviceName, redirectURI: redirectURI, state: state, codeChallenge: pkce.challenge)
            let page = OWBrowserSignIn.pageURL(config: config, sessionID: sessionID, provider: provider)
            let code = try await host.present(pageURL: page, expectedState: state)
            // The browser sheet is done with; the exchange needs nothing from it.
            await host.stop()
            stopped = true
            let credentials = try await exchangeBrowserSession(
                sessionID: sessionID, code: code, codeVerifier: pkce.verifier, redirectURI: redirectURI)
            return try await adopt(credentials: credentials)
        } catch {
            if !stopped { await host.stop() }
            throw error
        }
    }

    // MARK: - MFA

    /// POST /api/v1/auths/mfa/verify — answers a `verify` challenge with an
    /// authenticator code, or with a recovery code (`recovery: true`).
    ///
    /// A 401 here is a wrong code, never a dead session, so this does not go
    /// through `send`. Failures the server names arrive as `OWMFAError`; the
    /// network failing stays what it is.
    @discardableResult
    public func verifyMFA(challenge: OWMFAChallenge, code: String, recovery: Bool) async throws -> OWUser {
        struct Form: Encodable { var challenge_token: String; var code: String; var recovery: Bool }
        let req = try jsonPOST("/api/v1/auths/mfa/verify", Form(
            challenge_token: challenge.challengeToken,
            code: OWMFAChallenge.normalizedCode(code, recovery: recovery), recovery: recovery))
        let data: Data
        do { data = try await post(req) }
        catch OWError.http(let status, let detail) {
            throw OWMFAError(failure: OWMFAFailure.classify(status: status, detail: detail))
        }
        let s = try decode(OWSession.self, data)
        adoptLegacyToken(s.token)
        return OWUser(session: s)
    }
}
