import XCTest
@testable import OpenWebUIKit

/// The whole browser sign-in, with the two things only a phone can do — a
/// loopback listener and the system browser — replaced by a host that plays the
/// part. What is under test is the order of the steps and what is sent at each
/// one: that the listener is up before the redirect URI is named, that the PKCE
/// pair that was announced is the one that is redeemed, that the listener is
/// stopped on every way out, and that nothing is stored unless the server
/// accepts the session it was just given.
final class BrowserSignInFlowTests: XCTestCase {

    private let store = OWKeychainStore(service: "tests.browsersignin")
    private let sid = "0b3a1c2e-4d5f-4a6b-8c7d-9e0f1a2b3c4d"
    private let requests = "/api/v1/auths/sessions/requests"
    private let exchange = "/api/v1/auths/sessions/exchange"
    private let mePath = "/api/v1/auths"

    override func setUp() { super.setUp(); StubTransport.reset(); store.clear() }
    override func tearDown() { StubTransport.reset(); store.clear(); super.tearDown() }

    private func client() -> OpenWebUIClient {
        OpenWebUIClient(config: OWConfig(baseURL: URL(string: "https://flow.test")!),
                        tokens: store, protocolClasses: [StubTransport.self])
    }

    private final class Host: OWBrowserSignInHost, @unchecked Sendable {
        private let lock = NSLock()
        private var _log: [String] = []
        var log: [String] { lock.lock(); defer { lock.unlock() }; return _log }
        var port = 51234
        var code = "code-from-browser"
        var failure: Error?
        var startFailure: Error?
        private(set) var presented: (url: URL, state: String)?
        private func add(_ s: String) { lock.lock(); _log.append(s); lock.unlock() }

        func startListener() async throws -> Int {
            add("start")
            if let startFailure { throw startFailure }
            return port
        }
        func present(pageURL: URL, expectedState: String) async throws -> String {
            add("present")
            presented = (pageURL, expectedState)
            if let failure { throw failure }
            return code
        }
        func stop() async { add("stop") }
    }

    private func routeHappyPath(access: String = "acc-1") {
        StubTransport.route(requests, .json(#"{"session_id":"\#(sid)"}"#))
        StubTransport.route(exchange, .json(
            #"{"session_id":"\#(sid)","token":"\#(access)","token_type":"Bearer","expires_at":\#(Int(Date().timeIntervalSince1970) + 900),"refresh_token":"ref-1","refresh_expires_at":\#(Int(Date().timeIntervalSince1970) + 86400)}"#))
        StubTransport.route(mePath, .json(#"{"id":"u1","email":"a@b.c","name":"A","role":"user"}"#))
    }

    func testTheWholeFlowInOrder() async throws {
        routeHappyPath()
        let host = Host()
        let c = client()
        let user = try await c.signInThroughBrowser(host: host, deviceName: "Open WebUI · iPhone", provider: nil)

        XCTAssertEqual(user.id, "u1")
        XCTAssertEqual(host.log, ["start", "present", "stop"])
        XCTAssertEqual(StubTransport.seen, [requests, exchange, mePath])
        XCTAssertEqual(c.token, "acc-1")
        XCTAssertEqual(store.loadCredentials()?.refreshToken, "ref-1")
        XCTAssertEqual(store.loadCredentials()?.sessionID, sid)
        XCTAssertEqual(store.loadToken(), "acc-1")
        XCTAssertEqual(StubTransport.sentHeaders[mePath]?["Authorization"], "Bearer acc-1",
                       "the session is checked with the token it brought")
        XCTAssertNil(StubTransport.sentHeaders[requests]?["Authorization"], "the request is made by nobody yet")
    }

    /// The listener has to be up before the request names its port; the request
    /// carries the redirect, the state and the challenge; the browser is sent to
    /// the page for the session the server created.
    func testWhatIsAnnouncedIsWhatIsListenedForAndOpened() async throws {
        routeHappyPath()
        let host = Host(); host.port = 40404
        _ = try await client().signInThroughBrowser(host: host, deviceName: "Open WebUI · iPhone", provider: nil)

        let req = try XCTUnwrap(StubTransport.sentJSON(requests))
        XCTAssertEqual(req["name"] as? String, "Open WebUI · iPhone")
        XCTAssertEqual(req["redirect_uri"] as? String, "http://127.0.0.1:40404/callback")
        let state = try XCTUnwrap(req["state"] as? String)
        XCTAssertTrue(OWBrowserSignIn.isValidState(state))
        let presented = try XCTUnwrap(host.presented)
        XCTAssertEqual(presented.state, state, "the listener waits for the state that was announced")
        XCTAssertEqual(presented.url.absoluteString, "https://flow.test/auth/sessions/\(sid)")
    }

    /// The challenge announced in the request and the verifier redeemed at the
    /// exchange are one PKCE pair: S256 of the second is the first.
    func testTheVerifierRedeemedIsTheOneWhoseChallengeWasAnnounced() async throws {
        routeHappyPath()
        _ = try await client().signInThroughBrowser(host: Host(), deviceName: "n", provider: nil)
        let req = try XCTUnwrap(StubTransport.sentJSON(requests))
        let ex = try XCTUnwrap(StubTransport.sentJSON(exchange))
        let verifier = try XCTUnwrap(ex["code_verifier"] as? String)
        XCTAssertEqual(OWNativeOAuth.challenge(for: verifier), req["code_challenge"] as? String)
        XCTAssertEqual(ex["session_id"] as? String, sid)
        XCTAssertEqual(ex["code"] as? String, "code-from-browser")
        XCTAssertEqual(ex["redirect_uri"] as? String, req["redirect_uri"] as? String)
        XCTAssertEqual(Set(ex.keys), ["session_id", "code", "code_verifier", "redirect_uri"])
    }

    func testATappedProviderRidesOnThePageURL() async throws {
        routeHappyPath()
        let host = Host()
        _ = try await client().signInThroughBrowser(host: host, deviceName: "n", provider: "oidc")
        XCTAssertEqual(host.presented?.url.absoluteString, "https://flow.test/auth/sessions/\(sid)?provider=oidc")
    }

    // MARK: - Every way out stops the listener

    func testTheUserClosingTheBrowserStopsTheListenerAndStoresNothing() async {
        routeHappyPath()
        let host = Host(); host.failure = CancellationError()
        let c = client()
        let e = await owErrorAny { try await c.signInThroughBrowser(host: host, deviceName: "n", provider: nil) }
        XCTAssertTrue(e is CancellationError)
        XCTAssertEqual(host.log, ["start", "present", "stop"])
        XCTAssertFalse(StubTransport.requested(exchange), "no code, nothing to redeem")
        XCTAssertFalse(c.isAuthenticated)
        XCTAssertNil(store.loadCredentials())
    }

    func testAListenerThatCannotStartNeverAsksTheServerForAnything() async {
        routeHappyPath()
        let host = Host(); host.startFailure = URLError(.cannotConnectToHost)
        let e = await owErrorAny { try await self.client().signInThroughBrowser(host: host, deviceName: "n", provider: nil) }
        XCTAssertNotNil(e)
        XCTAssertEqual(StubTransport.seen, [], "no request was made for a login that cannot be received")
        XCTAssertEqual(host.log, ["start", "stop"])
    }

    func testTheServerRefusingTheRequestStopsTheListener() async {
        StubTransport.route(requests, .json(#"{"detail":"Too many login attempts. Try again shortly."}"#, status: 429))
        let host = Host()
        let e = await owError { try await self.client().signInThroughBrowser(host: host, deviceName: "n", provider: nil) }
        guard case .http(429, _)? = e else { return XCTFail("\(String(describing: e))") }
        XCTAssertEqual(host.log, ["start", "stop"])
    }

    func testASessionIDThatIsNotAUUIDIsNeverOpened() async {
        StubTransport.route(requests, .json(#"{"session_id":"../../admin"}"#))
        let host = Host()
        let e = await owError { try await self.client().signInThroughBrowser(host: host, deviceName: "n", provider: nil) }
        guard case .decoding? = e else { return XCTFail("\(String(describing: e))") }
        XCTAssertEqual(host.log, ["start", "stop"], "present was never called")
    }

    func testAnExchangeTheServerRefusesStopsTheListenerAndStoresNothing() async {
        routeHappyPath()
        StubTransport.route(exchange, .json(#"{"detail":"Invalid or expired login code."}"#, status: 401))
        let host = Host()
        let c = client()
        let e = await owError { try await c.signInThroughBrowser(host: host, deviceName: "n", provider: nil) }
        guard case .http(401, let why?)? = e else { return XCTFail("\(String(describing: e))") }
        XCTAssertEqual(why, "Invalid or expired login code.")
        XCTAssertEqual(host.log, ["start", "present", "stop"])
        XCTAssertFalse(c.isAuthenticated)
        XCTAssertNil(store.loadCredentials())
    }

    /// The exchange spent the code. If the session it returned is then refused —
    /// by `GET /auths/` — it is not kept, and a session the user already had is
    /// not thrown away on its account.
    func testASessionTheServerWillNotConfirmIsNotKept() async {
        routeHappyPath()
        StubTransport.route(mePath, .json(#"{"detail":"Not authenticated"}"#, status: 401))
        store.save(token: "the-session-already-here")
        let c = client()
        let e = await owError { try await c.signInThroughBrowser(host: Host(), deviceName: "n", provider: nil) }
        guard case .http(401, _)? = e else { return XCTFail("\(String(describing: e))") }
        XCTAssertEqual(c.token, "the-session-already-here")
        XCTAssertEqual(store.loadToken(), "the-session-already-here")
        XCTAssertNil(store.loadCredentials())
    }

    // MARK: - Taking the session on

    /// A browser session replaces whatever kind the client held, and a password
    /// sign-in afterwards replaces it back: the two must not leave a refresh
    /// token behind a token that no longer matches it.
    func testPasswordSignInAfterABrowserOneDropsTheRefreshToken() async throws {
        routeHappyPath()
        let c = client()
        _ = try await c.signInThroughBrowser(host: Host(), deviceName: "n", provider: nil)
        XCTAssertNotNil(c.credentials)

        StubTransport.route("/api/v1/auths/signin", .json(#"{"token":"jwt-pw","token_type":"Bearer","id":"u1"}"#))
        _ = try await c.signIn(email: "a@b.c", password: "pw")
        XCTAssertNil(c.credentials)
        XCTAssertNil(store.loadCredentials())
        XCTAssertEqual(store.loadToken(), "jwt-pw")
    }

    func testAdoptingAPastedTokenDropsTheRefreshTokenToo() async throws {
        routeHappyPath()
        let c = client()
        _ = try await c.signInThroughBrowser(host: Host(), deviceName: "n", provider: nil)
        _ = try await c.adopt(token: "web-view-cookie")
        XCTAssertNil(c.credentials)
        XCTAssertNil(store.loadCredentials())
        XCTAssertEqual(c.token, "web-view-cookie")
    }

    // MARK: - What the server advertises

    func testTheConfigSaysWhetherTheBrowserFlowExists() throws {
        func cfg(_ json: String) throws -> OWServerConfig {
            try JSONDecoder().decode(OWServerConfig.self, from: Data(json.utf8))
        }
        XCTAssertTrue(try cfg(#"{"features":{"auth_sessions":true}}"#).browserSignInAvailable)
        XCTAssertFalse(try cfg(#"{"features":{"auth_sessions":false}}"#).browserSignInAvailable)
        XCTAssertFalse(try cfg(#"{"features":{}}"#).browserSignInAvailable, "an older server says nothing")
        XCTAssertFalse(try cfg(#"{}"#).browserSignInAvailable)
    }
}
