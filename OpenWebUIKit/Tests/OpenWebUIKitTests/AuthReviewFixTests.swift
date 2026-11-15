import XCTest
@testable import OpenWebUIKit

/// 1.13 review fixes (prefix Auth): one test per confirmed finding, named after
/// what must hold, not after the diff.
///
/// These run against the stub transport with a clock the test owns, like
/// `AuthSessionRefreshTests`, which they extend: that file covers the refresh
/// protocol, this one the ways it could be cut short, raced or left half done.
final class AuthReviewFixTests: XCTestCase {

    private let store = OWKeychainStore(service: "tests.authreviewfix")
    private let refreshPath = "/api/v1/auths/sessions/refresh"
    private let mePath = "/api/v1/auths"
    private let sid = "0b3a1c2e-4d5f-4a6b-8c7d-9e0f1a2b3c4d"
    private let home = URL(string: "https://sessions.test")!
    private let elsewhere = URL(string: "https://elsewhere.test")!

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
        StubTransport.reset(); store.clear(); store.writeFault = nil; ended = 0
        endedObserver = NotificationCenter.default.addObserver(
            forName: OpenWebUIClient.sessionEndedNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.endedLock.lock(); self.ended += 1; self.endedLock.unlock()
        }
    }

    override func tearDown() {
        endedObserver.map(NotificationCenter.default.removeObserver)
        store.writeFault = nil
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
        let client = OpenWebUIClient(config: OWConfig(baseURL: home), tokens: store,
                                     protocolClasses: [StubTransport.self])
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
        let all = StubTransport.allHeaders[path] ?? []
        return all.indices.contains(call) ? all[call]["Authorization"] : nil
    }
    private func requestIDs() -> [String] {
        (StubTransport.allBodies[refreshPath] ?? []).compactMap {
            (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["request_id"] as? String
        }
    }

    /// Waits (briefly) for the stub to have been asked for `path`: the point at
    /// which a delayed answer is "in flight".
    private func waitUntilRequested(_ path: String) async {
        for _ in 0..<200 {
            if StubTransport.requested(path) { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - #0 a refresh the server refuses for good ends the session

    /// `verify_proof` answers 403 'Account approval is required.' for a user who
    /// was deactivated or set back to pending; 400/422 mean the server will never
    /// accept this refresh token. None of them is going to get better, and
    /// treating them as "try again later" left the app signed in on a dead
    /// session, throwing on every screen and asking the server again on every
    /// request.
    func testARefreshTheServerRefusesForGoodEndsTheSession() async {
        for status in [401, 403, 400, 422] {
            StubTransport.reset(); store.clear(); ended = 0
            StubTransport.route(refreshPath, .json(#"{"detail":"Account approval is required."}"#, status: status))
            routeMe()
            let c = client(credentials(accessLife: 10))
            let e = await owError { try await c.me() }
            guard case .notAuthenticated? = e else { XCTFail("\(status): \(String(describing: e))"); continue }
            XCTAssertEqual(endedCount, 1, "\(status)")
            XCTAssertFalse(c.isAuthenticated, "\(status)")
            XCTAssertNil(store.loadCredentials(), "\(status)")
            XCTAssertEqual(calls(refreshPath), 1, "\(status): and not asked again on every request")
        }
    }

    /// A busy or broken server is still not a dead session.
    func testATransientRefreshFailureStillDoesNotEndTheSession() async {
        for status in [429, 500, 502, 503] {
            StubTransport.reset(); store.clear(); ended = 0
            StubTransport.route(refreshPath, .json(#"{"detail":"later"}"#, status: status))
            StubTransport.route(mePath, .json(#"{"detail":"Not authenticated"}"#, status: 401))
            let c = client(credentials(accessLife: 600))
            _ = await owError { try await c.me() }
            XCTAssertEqual(endedCount, 0, "\(status)")
            XCTAssertTrue(c.isAuthenticated, "\(status)")
        }
    }

    // MARK: - #1 the refresh request id survives a kill

    /// The refresh reached the server and rotated the token; the answer was lost
    /// and the process was killed before the retry. The retry has to carry the
    /// SAME request id or the server cannot tell it from a replayed, spent token
    /// and signs the user out of a session that was alive and recoverable.
    func testALostRefreshAnswerIsRecoveredAfterTheProcessWasKilled() async throws {
        let first = client(credentials(accessLife: 10))
        StubTransport.route(refreshPath, .failing(.networkConnectionLost))
        routeMe()
        _ = try await first.me()                       // token has 10 s left: goes out anyway
        let lost = requestIDs()
        XCTAssertEqual(lost.count, 1)

        // Relaunch: a new process, the same Keychain.
        StubTransport.reset()
        routeMe(); routeRefresh()
        let second = client(nil)
        clock.advance(20)                              // now it IS expired
        _ = try await second.me()
        XCTAssertEqual(requestIDs(), lost, "same rotation, same id, across the kill")
        XCTAssertEqual(second.credentials?.refreshToken, "ref-2")
        XCTAssertNil(store.loadPendingRefresh(), "a rotation that completed is not pending any more")
    }

    /// The id belongs to one refresh token. A pending id left for a token that
    /// has since been replaced must not be sent with the new one.
    func testAPendingIDForAnotherRefreshTokenIsNotReused() async throws {
        store.save(pendingRefresh: OWPendingRefresh(refreshToken: "some-older-token",
                                                    requestID: UUID().uuidString))
        let c = client(credentials(accessLife: 10))
        routeMe(); routeRefresh()
        _ = try await c.me()
        XCTAssertEqual(requestIDs().count, 1)
        XCTAssertNotEqual(requestIDs().first, store.loadPendingRefresh()?.requestID)
    }

    func testSigningOutForgetsAPendingRefreshToo() async {
        let c = client(credentials(accessLife: 10))
        StubTransport.route(refreshPath, .failing(.networkConnectionLost))
        StubTransport.route("/api/v1/auths/sessions/\(sid)", .json(#"{"status":true}"#))
        routeMe()
        _ = try? await c.me()
        XCTAssertNotNil(store.loadPendingRefresh(), "persisted before the request went out")
        await c.signOut()
        XCTAssertNil(store.loadPendingRefresh(), "a spent refresh token must not outlive the sign-out")
    }

    // MARK: - #2 / #5 an in-flight refresh cannot outlive its session

    /// A request meets a 401 and starts a (slow) refresh; the user signs out
    /// meanwhile. When the answer lands it must not write the pair back — that
    /// undid the sign-out and put a refresh token in the Keychain again.
    func testARefreshThatLandsAfterSignOutDoesNotResurrectTheSession() async throws {
        StubTransport.routeSequence(mePath, [.json(#"{"detail":"Not authenticated"}"#, status: 401)])
        routeMe()
        routeRefresh(delay: 0.5)
        StubTransport.route("/api/v1/auths/sessions/\(sid)", .json(#"{"status":true}"#))
        let c = client(credentials(accessLife: 600))
        let pending = Task { try? await c.me() }
        await waitUntilRequested(refreshPath)
        await c.signOut()
        _ = await pending.value
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertNil(c.token); XCTAssertNil(c.credentials)
        XCTAssertNil(store.loadCredentials(), "the sign-out stays done")
        XCTAssertNil(store.loadToken())
        XCTAssertNil(store.loadPendingRefresh())
        XCTAssertEqual(endedCount, 0)
    }

    /// The same race with a server switch, where it also leaked: the old server's
    /// pair, written back under the new server's config, was then replayed to it.
    func testARefreshThatLandsAfterAServerSwitchIsDiscarded() async throws {
        StubTransport.routeSequence(mePath, [.json(#"{"detail":"Not authenticated"}"#, status: 401)])
        routeRefresh(delay: 0.5)
        let c = client(credentials(accessLife: 600))
        let pending = Task { try? await c.me() }
        await waitUntilRequested(refreshPath)
        c.updateConfig(OWConfig(baseURL: elsewhere))
        _ = await pending.value
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertNil(c.token); XCTAssertNil(c.credentials)
        XCTAssertNil(store.loadCredentials())
        XCTAssertNil(store.loadToken())
        routeMe()
        _ = try? await c.me()
        XCTAssertNil(StubTransport.sentHeaders[mePath]?["Authorization"],
                     "nothing of the old server is sent to the new one")
    }

    /// A stale 401 from the old server must not wipe a session adopted since.
    func testAStale401FromTheOldServerDoesNotDropTheNewSession() async throws {
        StubTransport.routeSequence(mePath, [.json(#"{"detail":"Not authenticated"}"#, status: 401)])
        var late = StubTransport.Reply.json(#"{"detail":"Invalid refresh token. Sign in again."}"#, status: 401)
        late.delay = 0.5
        StubTransport.route(refreshPath, late)
        let c = client(credentials(accessLife: 600))
        let pending = Task { try? await c.me() }
        await waitUntilRequested(refreshPath)
        c.updateConfig(OWConfig(baseURL: elsewhere))
        routeMe()
        _ = try await c.adopt(token: "new-jwt")
        _ = await pending.value
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(c.token, "new-jwt")
        XCTAssertEqual(store.loadToken(), "new-jwt")
        XCTAssertEqual(endedCount, 0, "the old server's verdict is not about this session")
    }

    /// A refresh asked for by the NEW session must not join the stale task and
    /// come back with the other server's token.
    func testANewSessionDoesNotJoinTheStaleRefresh() async throws {
        StubTransport.routeSequence(mePath, [.json(#"{"detail":"Not authenticated"}"#, status: 401)])
        var stale = StubTransport.Reply.json(body(access: "acc-OLD", refresh: "ref-OLD"))
        stale.delay = 0.5
        StubTransport.routeSequence(refreshPath, [stale, .json(body(access: "acc-NEW", refresh: "ref-NEW"))])
        let c = client(credentials(accessLife: 600))
        let pending = Task { try? await c.me() }
        await waitUntilRequested(refreshPath)
        c.updateConfig(OWConfig(baseURL: elsewhere))
        routeMe()
        _ = try await c.adopt(credentials: credentials(access: "n-1", refresh: "n-ref", accessLife: 5))
        _ = try await c.me()
        XCTAssertEqual(calls(refreshPath), 2, "its own refresh, not the stale one")
        XCTAssertEqual(c.token, "acc-NEW")
        _ = await pending.value
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(c.token, "acc-NEW", "the stale answer changed nothing")
        XCTAssertEqual(store.loadCredentials()?.refreshToken, "ref-NEW")
    }

    // MARK: - #3 a session the sign-in could not take on is not left behind

    func testAnExchangedSessionThatCannotBeConfirmedIsRevokedOnTheServer() async {
        let requests = "/api/v1/auths/sessions/requests", exchange = "/api/v1/auths/sessions/exchange"
        StubTransport.route(requests, .json(#"{"session_id":"\#(sid)"}"#))
        StubTransport.route(exchange, .json(body(access: "acc-X", refresh: "ref-X")))
        StubTransport.route(mePath, .json(#"{"detail":"boom"}"#, status: 502))
        StubTransport.route("/api/v1/auths/sessions/\(sid)", .json(#"{"status":true}"#))
        let c = client(nil)
        let e = await owError { try await c.signInThroughBrowser(host: QuietHost(), deviceName: "n", provider: nil) }
        guard case .http(502, _)? = e else { return XCTFail("\(String(describing: e))") }
        XCTAssertTrue(StubTransport.requested("/api/v1/auths/sessions/\(sid)"), "the orphan is revoked")
        XCTAssertEqual(bearer("/api/v1/auths/sessions/\(sid)"), "Bearer acc-X")
        XCTAssertFalse(c.isAuthenticated)
        XCTAssertNil(store.loadCredentials())
    }

    func testAFailedExchangeHasNothingToRevoke() async {
        StubTransport.route("/api/v1/auths/sessions/requests", .json(#"{"session_id":"\#(sid)"}"#))
        StubTransport.route("/api/v1/auths/sessions/exchange", .json(#"{"detail":"nope"}"#, status: 401))
        let c = client(nil)
        _ = await owError { try await c.signInThroughBrowser(host: QuietHost(), deviceName: "n", provider: nil) }
        XCTAssertFalse(StubTransport.requested("/api/v1/auths/sessions/\(sid)"))
    }

    private final class QuietHost: OWBrowserSignInHost, @unchecked Sendable {
        func startListener() async throws -> Int { 51234 }
        func present(pageURL: URL, expectedState: String) async throws -> String { "code" }
        func stop() async {}
    }

    // MARK: - #4 a Keychain write that fails is not forgotten

    /// A write that fails once is retried at once.
    func testATransientKeychainFailureIsRetriedOnTheSpot() async throws {
        routeMe(); routeRefresh()
        let c = client(credentials(accessLife: 10))
        let failures = Counter()
        store.writeFault = { key in key == "session.credentials" && failures.next() == 1 }
        _ = try await c.me()
        XCTAssertEqual(store.loadCredentials()?.refreshToken, "ref-2")
        XCTAssertNil(store.loadPendingRefresh())
    }

    /// A write that keeps failing leaves the old pair in the Keychain with its
    /// request id (so a cold launch can still recover the rotation), keeps the
    /// new pair in memory, and is tried again on the next request.
    func testAKeychainThatKeepsFailingIsRetriedOnTheNextRequest() async throws {
        routeMe(); routeRefresh()
        let c = client(credentials(accessLife: 10))
        store.writeFault = { key in key == "session.credentials" }
        _ = try await c.me()
        XCTAssertEqual(c.credentials?.refreshToken, "ref-2", "memory has the pair that works")
        XCTAssertEqual(store.loadCredentials()?.refreshToken, "ref-1", "the Keychain still has the old one")
        XCTAssertEqual(store.loadPendingRefresh()?.refreshToken, "ref-1", "so the rotation stays recoverable")

        store.writeFault = nil                          // the Keychain is back
        _ = try await c.me()
        XCTAssertEqual(store.loadCredentials()?.refreshToken, "ref-2")
        XCTAssertNil(store.loadPendingRefresh())
        XCTAssertEqual(calls(refreshPath), 1, "persisting again is not a refresh")
    }

    func testAColdLaunchAfterAFailedWriteRecoversTheRotationWithTheSameID() async throws {
        routeMe(); routeRefresh()
        let c = client(credentials(accessLife: 10))
        store.writeFault = { key in key == "session.credentials" }
        _ = try await c.me()
        let used = requestIDs()

        store.writeFault = nil
        StubTransport.reset(); routeMe(); routeRefresh()
        let relaunched = client(nil)
        clock.advance(20)
        _ = try await relaunched.me()
        XCTAssertEqual(requestIDs(), used, "the server recognises it as the rotation it already did")
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    }

    // MARK: - #7 a body that is not the server's sentence is not shown

    func testAnHTMLErrorPageIsNotASentence() {
        let page = "<!DOCTYPE html><html><body><h1>Sign in to the hotel wifi</h1></body></html>"
        XCTAssertNil(OpenWebUIClient.detail(from: Data(page.utf8)))
        XCTAssertNil(OpenWebUIClient.detail(from: Data("  \n<html>x</html>".utf8)))
    }

    func testAPlainTextBodyIsCapped() throws {
        let long = String(repeating: "a", count: 5_000)
        let d = try XCTUnwrap(OpenWebUIClient.detail(from: Data(long.utf8)))
        XCTAssertLessThanOrEqual(d.count, 201)
        XCTAssertEqual(OpenWebUIClient.detail(from: Data("502 Bad Gateway".utf8)), "502 Bad Gateway")
    }

    func testAPortalAnsweringTheMFAStepGetsTheGenericSentence() async {
        StubTransport.route("/api/v1/auths/mfa/verify",
                            .text("<html><body>Accept the terms to continue</body></html>", status: 500))
        let c = client(nil)
        let e = await owErrorAny { try await c.verifyMFA(
            challenge: OWMFAChallenge(kind: .verify, challengeToken: "t", expiresIn: 300),
            code: "123456", recovery: false) }
        XCTAssertEqual((e as? OWMFAError)?.failure, .other(nil))
    }

    // MARK: - #8 /api/config goes out with a live token

    func testTheSignedInConfigRequestIsRenewedFirst() async throws {
        StubTransport.route("/api/config", .json(#"{"version":"0.13.3","features":{"enable_notes":true}}"#))
        routeRefresh()
        let c = client(credentials(accessLife: -10))
        let cfg = try await c.serverConfig()
        XCTAssertEqual(StubTransport.seen, [refreshPath, "/api/config"], "renewed first, then asked once")
        XCTAssertEqual(bearer("/api/config"), "Bearer acc-2")
        XCTAssertEqual(cfg.version, "0.13.3")
    }

    func testTheConfigRequestOfAFreshTokenDoesNotRefresh() async throws {
        StubTransport.route("/api/config", .json(#"{"version":"0.13.3"}"#))
        let c = client(credentials(accessLife: 600))
        _ = try await c.serverConfig()
        XCTAssertEqual(calls(refreshPath), 0)
        XCTAssertEqual(bearer("/api/config"), "Bearer acc-1")
    }

    func testTheConfigRequestWithoutASessionStaysPublic() async throws {
        StubTransport.route("/api/config", .json(#"{"version":"0.13.3"}"#))
        let c = client(nil)
        _ = try await c.serverConfig()
        XCTAssertNil(StubTransport.sentHeaders["/api/config"]?["Authorization"])
    }

    // MARK: - #9 a challenge for an account that is gone is over

    func testAChallengeOfADeletedAccountEndsTheChallenge() {
        let f = OWMFAFailure.classify(status: 401, detail: "Invalid authentication request.")
        XCTAssertTrue(f.endsChallenge, "retrying cannot work: the account behind the challenge is gone")
        XCTAssertEqual(OWMFAFailure.classify(status: 401, detail: "Invalid or already used code."), .invalidCode)
        XCTAssertFalse(OWMFAFailure.classify(status: 401, detail: "Invalid or already used code.").endsChallenge)
    }

    // MARK: - #11 a sign-in answered by the old server is not adopted by the new

    func testAVerifyThatLandsAfterAServerSwitchIsNotAdopted() async throws {
        var late = StubTransport.Reply.json(#"{"token":"jwt-OLD","token_type":"Bearer","id":"u1","email":"a@b.c","name":"A","role":"user"}"#)
        late.delay = 0.4
        StubTransport.route("/api/v1/auths/mfa/verify", late)
        let c = client(nil)
        let verifying = Task { try await c.verifyMFA(
            challenge: OWMFAChallenge(kind: .verify, challengeToken: "t", expiresIn: 300),
            code: "123456", recovery: false) }
        await waitUntilRequested("/api/v1/auths/mfa/verify")
        c.updateConfig(OWConfig(baseURL: elsewhere))
        do { _ = try await verifying.value; XCTFail("must not complete as a sign-in") }
        catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertNil(c.token)
        XCTAssertNil(store.loadToken())
        XCTAssertFalse(c.isAuthenticated)
    }

    func testAPasswordSignInThatLandsAfterAServerSwitchIsNotAdopted() async throws {
        var late = StubTransport.Reply.json(#"{"token":"jwt-OLD","token_type":"Bearer","id":"u1","email":"a@b.c","name":"A","role":"user"}"#)
        late.delay = 0.4
        StubTransport.route("/api/v1/auths/signin", late)
        let c = client(nil)
        let signing = Task { try await c.signInResult(email: "a@b.c", password: "pw") }
        await waitUntilRequested("/api/v1/auths/signin")
        c.updateConfig(OWConfig(baseURL: elsewhere))
        do { _ = try await signing.value; XCTFail("must not complete as a sign-in") }
        catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertNil(store.loadToken())
    }

    /// The ordinary case still works, and a path correction on the same server is
    /// not a different server.
    func testASamePathCorrectionDuringVerifyKeepsTheSignIn() async throws {
        var late = StubTransport.Reply.json(#"{"token":"jwt-1","token_type":"Bearer","id":"u1","email":"a@b.c","name":"A","role":"user"}"#)
        late.delay = 0.3
        StubTransport.route("/api/v1/auths/mfa/verify", late)
        let c = client(nil)
        let verifying = Task { try await c.verifyMFA(
            challenge: OWMFAChallenge(kind: .verify, challengeToken: "t", expiresIn: 300),
            code: "123456", recovery: false) }
        await waitUntilRequested("/api/v1/auths/mfa/verify")
        c.updateConfig(OWConfig(baseURL: URL(string: "https://sessions.test/")!))
        _ = try await verifying.value
        XCTAssertEqual(c.token, "jwt-1")
    }

    // MARK: - #12 a permission refusal that wears a 401 is not a dead session

    /// `check_notes_access` answers 401 '401 Unauthorized' when the admin took the
    /// notes permission away mid-session. It is a 403 wearing the wrong number.
    func testANotesPermissionRefusalDoesNotRefreshOrSignOut() async {
        StubTransport.route("/api/v1/notes/search", .json(#"{"detail":"401 Unauthorized"}"#, status: 401))
        routeRefresh()
        let c = client(credentials(accessLife: 600))
        let e = await owError { try await c.send(c.request("/api/v1/notes/search")) }
        guard case .http(403, let why?)? = e else { return XCTFail("\(String(describing: e))") }
        XCTAssertEqual(why, "401 Unauthorized")
        XCTAssertEqual(calls(refreshPath), 0, "no rotation spent")
        XCTAssertEqual(endedCount, 0)
        XCTAssertTrue(c.isAuthenticated)
    }

    func testALegacySessionIsNotSignedOutByANotesPermissionRefusalEither() async {
        store.save(token: "legacy")
        StubTransport.route("/api/v1/notes/abc", .json(#"{"detail":"401 Unauthorized"}"#, status: 401))
        let c = client(nil)
        let e = await owError { try await c.send(c.request("/api/v1/notes/abc")) }
        guard case .http(403, _)? = e else { return XCTFail("\(String(describing: e))") }
        XCTAssertEqual(endedCount, 0)
        XCTAssertTrue(c.isAuthenticated)
    }

    /// A dead token on a notes route is still a dead token.
    func testADeadTokenOnANotesRouteStillRefreshesAndEnds() async {
        StubTransport.route("/api/v1/notes/search", .json(#"{"detail":"Not authenticated"}"#, status: 401))
        routeRefresh()
        let c = client(credentials(accessLife: 600))
        let e = await owError { try await c.send(c.request("/api/v1/notes/search")) }
        guard case .notAuthenticated? = e else { return XCTFail("\(String(describing: e))") }
        XCTAssertEqual(calls(refreshPath), 1)
        XCTAssertEqual(endedCount, 1)
    }

    /// The exception is the notes routes; the same sentence elsewhere keeps its
    /// old meaning.
    func testTheSameSentenceOutsideNotesStillEndsTheSession() async {
        StubTransport.route("/api/v1/chats/x", .json(#"{"detail":"401 Unauthorized"}"#, status: 401))
        store.save(token: "legacy")
        let c = client(nil)
        let e = await owError { try await c.send(c.request("/api/v1/chats/x")) }
        guard case .notAuthenticated? = e else { return XCTFail("\(String(describing: e))") }
        XCTAssertEqual(endedCount, 1)
    }

    /// The existing exception keeps working next to the new one.
    func testAMissingChatIsStillA404() async {
        StubTransport.route("/api/v1/chats/c1", .json(
            "{\"detail\":\"\(OpenWebUIClient.serverNotFoundSentence)\"}", status: 401))
        let c = client(credentials(accessLife: 600))
        let e = await owError { try await c.chat("c1") }
        guard case .http(404, _)? = e else { return XCTFail("\(String(describing: e))") }
        XCTAssertEqual(endedCount, 0)
    }
}
