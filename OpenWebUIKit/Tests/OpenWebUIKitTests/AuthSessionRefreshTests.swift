import XCTest
@testable import OpenWebUIKit

/// Sessions the browser sign-in hands out are short-lived on purpose.
///
/// `POST /api/v1/auths/sessions/exchange` answers with an access token that
/// lives at most 15 minutes and a **rotating** refresh token (routers/sessions.py
/// `credentials`, `refresh`). Every refresh invalidates the refresh token it was
/// given and returns the next one, so a client that loses a response, refreshes
/// twice at once, or uses a pair it has not yet saved, signs itself out.
///
/// These tests drive the client against the stub transport with a clock the test
/// owns, so "the token expires in 100 seconds" is a sentence, not a sleep.
final class AuthSessionRefreshTests: XCTestCase {

    private let store = OWKeychainStore(service: "tests.authsessions")
    private let refreshPath = "/api/v1/auths/sessions/refresh"
    private let mePath = "/api/v1/auths"
    private let sid = "0b3a1c2e-4d5f-4a6b-8c7d-9e0f1a2b3c4d"

    /// What "now" is, for the client under test.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ d: Date) { value = d }
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ s: TimeInterval) { lock.lock(); value = value.addingTimeInterval(s); lock.unlock() }
    }
    private let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
    private var t0: Int { Int(clock.now.timeIntervalSince1970) }

    private var ended = 0
    private var endedObserver: NSObjectProtocol?
    private let endedLock = NSLock()
    private var endedCount: Int { endedLock.lock(); defer { endedLock.unlock() }; return ended }

    override func setUp() {
        super.setUp()
        StubTransport.reset(); store.clear(); ended = 0
        endedObserver = NotificationCenter.default.addObserver(
            forName: OpenWebUIClient.sessionEndedNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.endedLock.lock(); self.ended += 1; self.endedLock.unlock()
        }
    }

    override func tearDown() {
        endedObserver.map(NotificationCenter.default.removeObserver)
        StubTransport.reset(); store.clear()
        super.tearDown()
    }

    // MARK: Fixtures

    private func credentials(access: String = "acc-1", refresh: String = "ref-1",
                             accessLife: Int = 900) -> OWAuthSessionCredentials {
        OWAuthSessionCredentials(sessionID: sid, token: access, expiresAt: t0 + accessLife,
                                 refreshToken: refresh, refreshExpiresAt: t0 + 86_400)
    }

    private func body(access: String, refresh: String, accessLife: Int = 900) -> String {
        #"{"session_id":"\#(sid)","token":"\#(access)","token_type":"Bearer","expires_at":\#(t0 + accessLife),"refresh_token":"\#(refresh)","refresh_expires_at":\#(t0 + 86_400)}"#
    }

    private func client(_ c: OWAuthSessionCredentials?) -> OpenWebUIClient {
        if let c { store.save(credentials: c) }
        let client = OpenWebUIClient(config: OWConfig(baseURL: URL(string: "https://sessions.test")!),
                                     tokens: store, protocolClasses: [StubTransport.self])
        let clock = self.clock
        client.now = { clock.now }
        return client
    }

    private func routeMe() { StubTransport.route(mePath, .json(#"{"id":"u1","email":"a@b.c","name":"A","role":"user"}"#)) }
    private func routeRefresh(access: String = "acc-2", refresh: String = "ref-2", delay: TimeInterval = 0) {
        var r = StubTransport.Reply.json(body(access: access, refresh: refresh))
        r.delay = delay
        StubTransport.route(refreshPath, r)
    }
    private func calls(_ path: String) -> Int { StubTransport.seen.filter { $0 == path }.count }
    private func bearer(_ path: String, call: Int = 0) -> String? {
        StubTransport.allHeaders[path]?[safe: call]?["Authorization"]
    }

    // MARK: - The credentials themselves

    func testTheServersBodyDecodesIntoCredentials() throws {
        let c = try JSONDecoder().decode(OWAuthSessionCredentials.self, from: Data(body(access: "a", refresh: "r").utf8))
        XCTAssertEqual(c.sessionID, sid)
        XCTAssertEqual(c.token, "a")
        XCTAssertEqual(c.tokenType, "Bearer")
        XCTAssertEqual(c.refreshToken, "r")
        XCTAssertEqual(c.expiresAt, t0 + 900)
        XCTAssertEqual(c.refreshExpiresAt, t0 + 86_400)
    }

    /// Everything but the tokens is optional: a missing `token_type` is Bearer, a
    /// missing expiry is "unknown" (never refreshed proactively, still refreshed
    /// on a 401).
    func testAMissingExpiryOrTypeIsTolerated() throws {
        let raw = #"{"session_id":"\#(sid)","token":"a","refresh_token":"r"}"#
        let c = try JSONDecoder().decode(OWAuthSessionCredentials.self, from: Data(raw.utf8))
        XCTAssertEqual(c.tokenType, "Bearer")
        XCTAssertNil(c.expiresAt)
        XCTAssertFalse(c.expires(within: 120, now: clock.now))
    }

    func testTheRenewalThresholdIsOneHundredAndTwentySeconds() {
        XCTAssertEqual(OWAuthSessionCredentials.refreshLeeway, 120)
        let c = credentials(accessLife: 120)
        XCTAssertTrue(c.expires(within: 120, now: clock.now), "120 s left is inside the window")
        XCTAssertFalse(credentials(accessLife: 121).expires(within: 120, now: clock.now))
        XCTAssertTrue(credentials(accessLife: 0).expires(within: 120, now: clock.now))
        XCTAssertTrue(credentials(accessLife: -30).expires(within: 120, now: clock.now), "already expired")
    }

    func testCredentialsSurviveTheKeychainAndTheTokenMirrorsTheAccessToken() {
        store.save(credentials: credentials())
        XCTAssertEqual(store.loadCredentials(), credentials())
        XCTAssertEqual(store.loadToken(), "acc-1", "older code reading session.token must still find the live one")
        store.save(credentials: credentials(access: "acc-9", refresh: "ref-9"))
        XCTAssertEqual(store.loadCredentials()?.refreshToken, "ref-9")
        XCTAssertEqual(store.loadToken(), "acc-9")
        store.clear()
        XCTAssertNil(store.loadCredentials())
        XCTAssertNil(store.loadToken())
    }

    func testALaunchWithStoredCredentialsStartsSignedIn() {
        let c = client(credentials())
        XCTAssertTrue(c.isAuthenticated)
        XCTAssertEqual(c.token, "acc-1")
        XCTAssertEqual(c.credentials?.sessionID, sid)
    }

    // MARK: - Proactive renewal

    func testATokenWithTimeLeftIsUsedAsIs() async throws {
        routeMe()
        let c = client(credentials(accessLife: 600))
        _ = try await c.me()
        XCTAssertEqual(calls(refreshPath), 0)
        XCTAssertEqual(bearer(mePath), "Bearer acc-1")
    }

    func testATokenWithinTheWindowIsRenewedBeforeTheRequestGoesOut() async throws {
        routeMe(); routeRefresh()
        let c = client(credentials(accessLife: 100))
        _ = try await c.me()
        XCTAssertEqual(StubTransport.seen, [refreshPath, mePath], "renewed first, then asked")
        XCTAssertEqual(bearer(mePath), "Bearer acc-2")
        XCTAssertEqual(c.token, "acc-2")
        XCTAssertEqual(c.credentials?.refreshToken, "ref-2")
    }

    func testTheRefreshBodyIsTheRefreshTokenAndARequestID() async throws {
        routeMe(); routeRefresh()
        let c = client(credentials(accessLife: 10))
        _ = try await c.me()
        let sent = try XCTUnwrap(StubTransport.sentJSON(refreshPath))
        XCTAssertEqual(Set(sent.keys), ["refresh_token", "request_id"])
        XCTAssertEqual(sent["refresh_token"] as? String, "ref-1")
        XCTAssertNotNil(UUID(uuidString: sent["request_id"] as? String ?? ""), "a UUID, as the server's form declares")
        XCTAssertNil(StubTransport.sentHeaders[refreshPath]?["Authorization"],
                     "the refresh token is the credential; the expired access token goes nowhere")
    }

    /// The token a request carried when it was BUILT is the one that is old; what
    /// it goes out with is decided at send time.
    func testARequestBuiltBeforeTheRenewalGoesOutWithTheNewToken() async throws {
        routeMe(); routeRefresh()
        let c = client(credentials(accessLife: 100))
        let req = c.request(mePath)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer acc-1")
        _ = try await c.send(req)
        XCTAssertEqual(bearer(mePath), "Bearer acc-2")
    }

    // MARK: - Single flight

    func testTwoRequestsAtOnceShareOneRefresh() async throws {
        routeMe(); routeRefresh(delay: 0.3)
        let c = client(credentials(accessLife: 5))
        async let a = c.me()
        async let b = c.me()
        _ = try await (a, b)
        XCTAssertEqual(calls(refreshPath), 1, "the second request waited for the first one's rotation")
        XCTAssertEqual(calls(mePath), 2)
        XCTAssertEqual(bearer(mePath, call: 0), "Bearer acc-2")
        XCTAssertEqual(bearer(mePath, call: 1), "Bearer acc-2")
    }

    func testManyRequestsAtOnceStillRefreshOnce() async throws {
        routeMe(); routeRefresh(delay: 0.2)
        let c = client(credentials(accessLife: 5))
        try await withThrowingTaskGroup(of: Void.self) { g in
            for _ in 0..<8 { g.addTask { _ = try await c.me() } }
            try await g.waitForAll()
        }
        XCTAssertEqual(calls(refreshPath), 1)
    }

    // MARK: - 401 → refresh → retry

    func testA401IsAnsweredByOneRefreshAndOneRetry() async throws {
        StubTransport.routeSequence(mePath, [
            .json(#"{"detail":"Not authenticated"}"#, status: 401),
            .json(#"{"id":"u1","email":"a@b.c"}"#),
        ])
        routeRefresh()
        let c = client(credentials(accessLife: 600))
        let user = try await c.me()
        XCTAssertEqual(user.id, "u1")
        XCTAssertEqual(StubTransport.seen, [mePath, refreshPath, mePath])
        XCTAssertEqual(bearer(mePath, call: 0), "Bearer acc-1")
        XCTAssertEqual(bearer(mePath, call: 1), "Bearer acc-2")
        XCTAssertEqual(endedCount, 0, "nobody was signed out")
    }

    /// One retry, not a loop: a fresh token the server still refuses is not a
    /// token problem.
    func testASecond401AfterTheRenewalEndsTheSession() async {
        StubTransport.routeSequence(mePath, [
            .json(#"{"detail":"Not authenticated"}"#, status: 401),
            .json(#"{"detail":"Not authenticated"}"#, status: 401),
        ])
        routeRefresh()
        let c = client(credentials(accessLife: 600))
        let e = await owError { try await c.me() }
        guard case .notAuthenticated? = e else { return XCTFail("\(String(describing: e))") }
        XCTAssertEqual(calls(refreshPath), 1)
        XCTAssertEqual(calls(mePath), 2)
        XCTAssertEqual(endedCount, 1)
        XCTAssertNil(store.loadCredentials())
    }

    /// 401s that arrive together, all for the token that has just been replaced,
    /// must not each spend a rotation: the first renews, the rest see that the
    /// token they were refused with is no longer the current one.
    func testSeveral401sForTheSameStaleTokenRefreshOnce() async throws {
        StubTransport.routeSequence(mePath, [
            .json(#"{"detail":"Not authenticated"}"#, status: 401),
            .json(#"{"detail":"Not authenticated"}"#, status: 401),
            .json(#"{"id":"u1"}"#), .json(#"{"id":"u1"}"#),
        ])
        routeRefresh(delay: 0.3)
        let c = client(credentials(accessLife: 600))
        async let a = c.me()
        async let b = c.me()
        _ = try await (a, b)
        XCTAssertEqual(calls(refreshPath), 1)
    }

    /// Open WebUI answers 401 for a chat that is not there. That is a 404 wearing
    /// the wrong number and must neither refresh nor sign out.
    func testAMissingChatIsNotAReasonToRefresh() async {
        StubTransport.route("/api/v1/chats/c1", .json(
            "{\"detail\":\"\(OpenWebUIClient.serverNotFoundSentence)\"}", status: 401))
        let c = client(credentials(accessLife: 600))
        let e = await owError { try await c.chat("c1") }
        guard case .http(404, _)? = e else { return XCTFail("\(String(describing: e))") }
        XCTAssertEqual(calls(refreshPath), 0)
        XCTAssertEqual(endedCount, 0)
    }

    func testALegacyTokenKeepsTheOldBehaviourAndNeverTouchesTheRefreshRoute() async {
        store.save(token: "legacy-jwt")
        StubTransport.route(mePath, .json(#"{"detail":"Not authenticated"}"#, status: 401))
        let c = client(nil)
        XCTAssertNil(c.credentials)
        let e = await owError { try await c.me() }
        guard case .notAuthenticated? = e else { return XCTFail("\(String(describing: e))") }
        XCTAssertEqual(calls(refreshPath), 0)
        XCTAssertFalse(c.isAuthenticated)
        XCTAssertEqual(endedCount, 1)
    }

    // MARK: - When the refresh itself fails

    /// 401 from the refresh route is the server saying the session is gone —
    /// revoked, idle past its expiry, or the refresh token already spent.
    func testARefreshRefusedWith401IsTheSessionEnding() async {
        StubTransport.route(refreshPath, .json(#"{"detail":"Invalid refresh token. Sign in again."}"#, status: 401))
        routeMe()
        let c = client(credentials(accessLife: 10))
        let e = await owError { try await c.me() }
        guard case .notAuthenticated? = e else { return XCTFail("\(String(describing: e))") }
        XCTAssertEqual(endedCount, 1)
        XCTAssertFalse(c.isAuthenticated)
        XCTAssertNil(c.credentials)
        XCTAssertNil(store.loadCredentials())
        XCTAssertNil(store.loadToken())
        XCTAssertEqual(calls(mePath), 0, "a request is not sent with a token known to be dead")
    }

    /// A phone in a lift is not a revoked session. The credentials stay, nothing
    /// is posted, and the request that needed the renewal says why it failed.
    func testANetworkFailureOnRefreshDoesNotSignOut() async {
        StubTransport.route(refreshPath, .failing(.notConnectedToInternet))
        StubTransport.route(mePath, .json(#"{"detail":"Not authenticated"}"#, status: 401))
        let c = client(credentials(accessLife: 600))
        let e = await owError { try await c.me() }
        guard case .transport? = e else { return XCTFail("\(String(describing: e))") }
        XCTAssertEqual(endedCount, 0)
        XCTAssertTrue(c.isAuthenticated)
        XCTAssertEqual(store.loadCredentials(), credentials(accessLife: 600))
    }

    /// When the renewal is merely early, the token in hand may still be good: the
    /// request goes with it instead of failing on a refresh it did not need yet.
    func testAnEarlyRenewalThatCannotBeDoneStillSendsTheRequestWithTheTokenInHand() async throws {
        StubTransport.route(refreshPath, .failing(.timedOut))
        routeMe()
        let c = client(credentials(accessLife: 60))
        _ = try await c.me()
        XCTAssertEqual(bearer(mePath), "Bearer acc-1")
        XCTAssertEqual(endedCount, 0)
        XCTAssertTrue(c.isAuthenticated)
    }

    func testAServerErrorOnRefreshDoesNotSignOutEither() async {
        for status in [429, 500, 503] {
            StubTransport.reset(); store.clear()
            StubTransport.route(refreshPath, .json(#"{"detail":"Authentication is temporarily unavailable."}"#, status: status))
            StubTransport.route(mePath, .json(#"{"detail":"Not authenticated"}"#, status: 401))
            let c = client(credentials(accessLife: 600))
            let e = await owError { try await c.me() }
            guard case .http(let code, _)? = e else { return XCTFail("\(status): \(String(describing: e))") }
            XCTAssertEqual(code, status)
            XCTAssertEqual(endedCount, 0, "\(status)")
            XCTAssertTrue(c.isAuthenticated, "\(status)")
        }
    }

    /// A 403 is "account approval is required" (`verify_proof`): the role
    /// changed, the session did not die.
    func testAnApprovalRefusalOnRefreshIsReportedNotASignOut() async {
        StubTransport.route(refreshPath, .json(#"{"detail":"Account approval is required."}"#, status: 403))
        routeMe()
        let c = client(credentials(accessLife: 10))
        _ = try? await c.me()
        XCTAssertEqual(endedCount, 0)
        XCTAssertTrue(c.isAuthenticated)
    }

    // MARK: - Rotation

    /// The server has already spent the old refresh token when it answers. If
    /// the new pair is only in memory when the app is killed, the next launch
    /// holds a dead one. So the pair is saved first, and only then used.
    func testTheNewPairIsInTheKeychainBeforeTheRequestThatNeedsItGoesOut() async throws {
        routeMe(); routeRefresh()
        let persisted = Box<String?>(nil)
        let store = self.store, mePath = self.mePath
        StubTransport.onRequest = { req in
            if req.url?.path == mePath { persisted.value = store.loadCredentials()?.refreshToken }
        }
        let c = client(credentials(accessLife: 10))
        _ = try await c.me()
        XCTAssertEqual(persisted.value, "ref-2")
        XCTAssertEqual(store.loadToken(), "acc-2")
    }

    /// The first refresh was answered, but the answer never arrived. The server
    /// may or may not have rotated; retrying the SAME request id with the SAME
    /// refresh token is what the server's `refresh_retry` window recognises.
    func testARetryOfTheSameRotationReusesItsRequestID() async throws {
        let c = client(credentials(accessLife: 600))
        StubTransport.route(refreshPath, .failing(.networkConnectionLost))
        StubTransport.route(mePath, .json(#"{"detail":"Not authenticated"}"#, status: 401))
        _ = await owError { try await c.me() }
        _ = await owError { try await c.me() }
        let ids = (StubTransport.allBodies[refreshPath] ?? []).compactMap {
            (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["request_id"] as? String
        }
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, 1, "same rotation, same id")

        StubTransport.reset()
        routeMe(); routeRefresh(access: "acc-2", refresh: "ref-2")
        clock.advance(850)
        _ = try await c.me()
        let id1 = (StubTransport.sentJSON(refreshPath))?["request_id"] as? String
        XCTAssertEqual(id1, ids.first, "still the same rotation: the refresh token did not change until now")

        // The next rotation is a different one.
        StubTransport.reset()
        routeMe(); routeRefresh(access: "acc-3", refresh: "ref-3")
        clock.advance(850)
        _ = try await c.me()
        let id2 = (StubTransport.sentJSON(refreshPath))?["request_id"] as? String
        XCTAssertNotNil(id2)
        XCTAssertNotEqual(id2, id1)
    }

    func testTheRefreshedExpiryIsTheOneTheNextRenewalIsJudgedBy() async throws {
        routeMe(); routeRefresh()
        let c = client(credentials(accessLife: 10))
        _ = try await c.me()
        XCTAssertEqual(calls(refreshPath), 1)
        _ = try await c.me()
        XCTAssertEqual(calls(refreshPath), 1, "acc-2 has 900 s")
        clock.advance(800)
        routeRefresh(access: "acc-3", refresh: "ref-3")
        _ = try await c.me()
        XCTAssertEqual(calls(refreshPath), 2, "100 s left is inside the window")
        XCTAssertEqual(bearer(mePath, call: 2), "Bearer acc-3")
    }

    // MARK: - The other places a token is read

    private func completionsClient(_ c: OpenWebUIClient) -> ChatCompletionsClient { ChatCompletionsClient(client: c) }

    private func drain(_ s: AsyncThrowingStream<OWStreamUpdate, Error>) async throws -> String {
        var text = ""
        for try await u in s { if case .textDelta(let t) = u { text += t } }
        return text
    }

    private let chunk = #"{"choices":[{"delta":{"content":"oi"},"finish_reason":null,"index":0}]}"#

    func testAChatStreamStartsWithARenewedToken() async throws {
        StubTransport.route("/api/chat/completions", .sse([chunk, "[DONE]"]))
        routeRefresh()
        let c = client(credentials(accessLife: 30))
        let text = try await drain(completionsClient(c).stream(model: "m", messages: [OWChatMessageInput(role: "user", text: "x")]))
        XCTAssertEqual(text, "oi")
        XCTAssertEqual(StubTransport.seen, [refreshPath, "/api/chat/completions"])
        XCTAssertEqual(bearer("/api/chat/completions"), "Bearer acc-2")
    }

    func testAChatStreamRefusedWith401IsRenewedAndRetriedOnce() async throws {
        StubTransport.routeSequence("/api/chat/completions", [
            .json(#"{"detail":"Not authenticated"}"#, status: 401),
            .sse([chunk, "[DONE]"]),
        ])
        routeRefresh()
        let c = client(credentials(accessLife: 600))
        let text = try await drain(completionsClient(c).stream(model: "m", messages: [OWChatMessageInput(role: "user", text: "x")]))
        XCTAssertEqual(text, "oi")
        XCTAssertEqual(StubTransport.seen, ["/api/chat/completions", refreshPath, "/api/chat/completions"])
        XCTAssertEqual(bearer("/api/chat/completions", call: 1), "Bearer acc-2")
        XCTAssertEqual(endedCount, 0)
    }

    func testAChatStreamRefusedTwiceEndsTheSession() async {
        StubTransport.routeSequence("/api/chat/completions", [
            .json(#"{"detail":"Not authenticated"}"#, status: 401),
            .json(#"{"detail":"Not authenticated"}"#, status: 401),
        ])
        routeRefresh()
        let c = client(credentials(accessLife: 600))
        do {
            _ = try await drain(completionsClient(c).stream(model: "m", messages: [OWChatMessageInput(role: "user", text: "x")]))
            XCTFail("should have failed")
        } catch {}
        XCTAssertEqual(endedCount, 1)
        XCTAssertFalse(c.isAuthenticated)
    }

    func testAnImageFetchGoesOutWithARenewedTokenToTheServerOnly() async throws {
        StubTransport.route("/api/v1/files/f1/content", .init(200, Data([1, 2, 3])))
        StubTransport.route("/elsewhere.png", .init(200, Data([9])))
        routeRefresh()
        let c = client(credentials(accessLife: 30))
        let d = try await c.fetchImage(path: "/api/v1/files/f1/content")
        XCTAssertEqual(d, Data([1, 2, 3]))
        XCTAssertEqual(bearer("/api/v1/files/f1/content"), "Bearer acc-2")

        StubTransport.reset(); routeRefresh()
        StubTransport.route("/elsewhere.png", .init(200, Data([9])))
        _ = try await c.fetchImage(path: "https://cdn.example/elsewhere.png")
        XCTAssertNil(StubTransport.sentHeaders["/elsewhere.png"]?["Authorization"], "another host never sees the session")
        XCTAssertEqual(calls(refreshPath), 0, "and does not cause a rotation for itself")
    }

    func testAnImageRefusedWith401IsRenewedAndRetriedOnce() async throws {
        let path = "/api/v1/files/f2/content"
        StubTransport.routeSequence(path, [.json("{}", status: 401), .init(200, Data([7]))])
        routeRefresh()
        let c = client(credentials(accessLife: 600))
        clock.advance(100)   // the token has had time to age: this is plausibly expiry
        let d = try await c.fetchImage(path: path)
        XCTAssertEqual(d, Data([7]))
        XCTAssertEqual(bearer(path, call: 1), "Bearer acc-2")
    }

    /// A picture the server will not give is not a reason to spend a rotation on
    /// every one of them, nor to sign anyone out.
    func testAnImageRefusedRightAfterARenewalDoesNotRenewAgain() async {
        let path = "/api/v1/files/f3/content"
        StubTransport.route(path, .json("{}", status: 401))
        routeRefresh()
        let c = client(credentials(accessLife: 20))   // renewed proactively just now
        let e = await owError { try await c.fetchImage(path: path) }
        guard case .http(401, _)? = e else { return XCTFail("\(String(describing: e))") }
        XCTAssertEqual(calls(refreshPath), 1)
        XCTAssertEqual(endedCount, 0)
        XCTAssertTrue(c.isAuthenticated)
    }

    func testBuildRequestStillCarriesTheTokenInHandForTheWireFormatTests() throws {
        let c = client(credentials())
        let req = try completionsClient(c).buildRequest(model: "m", messages: [], files: [], options: OWStreamOptions())
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer acc-1")
    }

    // MARK: - Signing out

    func testSigningOutRevokesTheSessionAndForgetsEverything() async {
        StubTransport.route("/api/v1/auths/sessions/\(sid)", .json(#"{"status":true}"#))
        let methods = Box<[String]>([])
        StubTransport.onRequest = { req in
            methods.value.append("\(req.httpMethod ?? "?") \(req.url?.path ?? "")")
        }
        let c = client(credentials(accessLife: 600))
        await c.signOut()
        XCTAssertEqual(methods.value, ["DELETE /api/v1/auths/sessions/\(sid)"])
        XCTAssertEqual(bearer("/api/v1/auths/sessions/\(sid)"), "Bearer acc-1")
        XCTAssertNil(c.token); XCTAssertNil(c.credentials)
        XCTAssertNil(store.loadCredentials()); XCTAssertNil(store.loadToken())
        XCTAssertEqual(endedCount, 0, "the user signing out is not a session ending on them")
    }

    func testSigningOutWorksWhenTheRevocationCannotBeSent() async {
        StubTransport.route("/api/v1/auths/sessions/\(sid)", .failing(.notConnectedToInternet))
        let c = client(credentials(accessLife: 600))
        await c.signOut()
        XCTAssertNil(c.token)
        XCTAssertNil(store.loadCredentials())
    }

    /// An expired access token cannot revoke anything; renewing it first is what
    /// lets "sign out" actually end the session on the server — and if even that
    /// is refused, the sign-out still completes, quietly.
    func testSigningOutWithAnExpiredTokenRenewsItFirst() async {
        StubTransport.route("/api/v1/auths/sessions/\(sid)", .json(#"{"status":true}"#))
        routeRefresh()
        let c = client(credentials(accessLife: -10))
        await c.signOut()
        XCTAssertEqual(StubTransport.seen, [refreshPath, "/api/v1/auths/sessions/\(sid)"])
        XCTAssertEqual(bearer("/api/v1/auths/sessions/\(sid)"), "Bearer acc-2")
        XCTAssertNil(store.loadCredentials())
        XCTAssertEqual(endedCount, 0)
    }

    func testSigningOutWhenTheRefreshIsRefusedStillSignsOutWithoutAnAlarm() async {
        StubTransport.route(refreshPath, .json(#"{"detail":"Invalid refresh token. Sign in again."}"#, status: 401))
        let c = client(credentials(accessLife: -10))
        await c.signOut()
        XCTAssertNil(store.loadCredentials())
        XCTAssertEqual(endedCount, 0)
        XCTAssertFalse(c.isAuthenticated)
    }

    func testSigningOutOfALegacyTokenStillUsesTheOldRoute() async {
        store.save(token: "legacy")
        StubTransport.route("/api/v1/auths/signout", .json(#"{"status":true}"#))
        let c = client(nil)
        await c.signOut()
        XCTAssertTrue(StubTransport.requested("/api/v1/auths/signout"))
        XCTAssertNil(store.loadToken())
    }

    func testPointingTheAppAtAnotherServerForgetsTheCredentials() {
        let c = client(credentials())
        c.updateConfig(OWConfig(baseURL: URL(string: "https://elsewhere.test")!))
        XCTAssertNil(c.credentials)
        XCTAssertNil(c.token)
        XCTAssertNil(store.loadCredentials())
    }
}

/// A mutable cell a `@Sendable` closure may write: the stub calls its observer
/// off the test's thread.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ v: T) { stored = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
