import XCTest
@testable import OpenWebUIKit

/// Which server a credential belongs to, and what happens to it when the app is
/// pointed somewhere else.
///
/// A token is a credential for the host that issued it. Every URL the server
/// hands back — an image, a file, a share link — is data, not instruction, and
/// may be absolute and point anywhere. `origin(_:)` is the one comparison both
/// of those rest on, so it is worth pinning at the level of ports and case
/// rather than trusting `==` on a URL.
final class SessionOriginTests: XCTestCase {

    private let store = OWKeychainStore(service: "tests.rotate")
    /// `HTTPCookieStorage.shared` is process-wide, so whatever is seeded here is
    /// put back on the way out.
    private var seededCookies: [HTTPCookie] = []

    override func setUp() {
        super.setUp()
        StubTransport.reset()
        store.clear()
    }

    override func tearDown() {
        StubTransport.reset()
        store.clear()
        for c in seededCookies { HTTPCookieStorage.shared.deleteCookie(c) }
        seededCookies = []
        super.tearDown()
    }

    /// A live session cookie for `host`, the way Open WebUI sets one alongside
    /// the bearer token.
    private func seedCookie(for host: String) {
        guard let c = HTTPCookie(properties: [
            .name: "token", .value: "cookie-de-\(host)", .domain: host, .path: "/",
            .expires: Date().addingTimeInterval(3600),
        ]) else { return XCTFail("could not build a cookie for \(host)") }
        HTTPCookieStorage.shared.setCookie(c)
        seededCookies.append(c)
    }

    /// A cookie for `example.com` is stored with the domain `.example.com`, so
    /// both spellings count as the same host.
    private func hasCookie(for host: String) -> Bool {
        (HTTPCookieStorage.shared.cookies ?? []).contains {
            let d = $0.domain.lowercased()
            return d == host || d == "." + host
        }
    }

    private func client(at base: String) -> OpenWebUIClient {
        OpenWebUIClient(config: OWConfig(baseURL: URL(string: base)!),
                        tokens: store, protocolClasses: [StubTransport.self])
    }

    private func origin(_ s: String) -> String {
        OpenWebUIClient.origin(URL(string: s)!)
    }

    // MARK: - What counts as the same server

    /// The default port is written in, so a URL that states it and one that does
    /// not are the same server; scheme and host are compared case-insensitively,
    /// because a URL typed by a human may be neither.
    func testTheDefaultPortAndLetterCaseDoNotMakeADifferentServer() {
        XCTAssertEqual(origin("https://a.example"), origin("https://a.example:443"))
        XCTAssertEqual(origin("https://a.example"), origin("HTTPS://A.EXAMPLE"))
        XCTAssertEqual(origin("http://a.example"), origin("http://a.example:80"))
    }

    /// A path is not part of an origin: Open WebUI can be mounted under a
    /// sub-path, and the same install answering at `/` and at `/openwebui` is
    /// still the machine that issued the token.
    func testAPathIsNotPartOfAnOrigin() {
        XCTAssertEqual(origin("https://a.example"), origin("https://a.example/openwebui/api/config"))
    }

    /// The three ways two URLs are genuinely different servers. Downgrading
    /// https to http is the one that matters most: the token would go out in
    /// cleartext to a host that may not be the same one at all.
    func testSchemeHostAndAnExplicitPortAllMakeADifferentServer() {
        XCTAssertNotEqual(origin("https://a.example"), origin("http://a.example"))
        XCTAssertNotEqual(origin("https://a.example"), origin("https://b.example"))
        XCTAssertNotEqual(origin("https://a.example"), origin("https://a.example:8443"))
    }

    /// `isSameOrigin` is the same rule read from the client's own configuration
    /// — it is what decides whether a URL the server sent us is fetched with the
    /// user's `Authorization` header attached.
    func testIsSameOriginAnswersForTheConfiguredServer() {
        let c = client(at: "https://a.example/openwebui")
        XCTAssertTrue(c.isSameOrigin(URL(string: "https://a.example/api/v1/files/1/content")!))
        XCTAssertTrue(c.isSameOrigin(URL(string: "https://A.Example:443/x")!))
        XCTAssertFalse(c.isSameOrigin(URL(string: "https://cdn.evil.example/api/v1/files/1/content")!))
        XCTAssertFalse(c.isSameOrigin(URL(string: "http://a.example/x")!))
    }

    // MARK: - Repointing the app

    /// Pointing the client at another origin while holding a token means the
    /// very next request replays the user's JWT to a machine that never issued
    /// it — including the requests that look unauthenticated. So the credential
    /// goes, from memory and from the Keychain both.
    func testSwitchingServersForgetsTheCredentialForTheOldOne() {
        store.save(token: "token-do-servidor-a")
        store.saveCredentials(email: "joao@example.com", password: "hunter2")
        seedCookie(for: "a.example")
        seedCookie(for: "b.example")
        let c = client(at: "https://a.example")
        XCTAssertTrue(c.isAuthenticated, "the fixture never had a session to lose")

        c.updateConfig(OWConfig(baseURL: URL(string: "https://b.example")!))

        XCTAssertNil(c.token)
        XCTAssertNil(store.loadToken())
        XCTAssertNil(store.loadEmail(), "'keep me signed in' is for the server it was typed at")
        XCTAssertNil(store.loadPassword())
        // The jar is cleared before the new URL is adopted, so it is the OLD
        // host that is emptied. Doing it after would have cleared the wrong one.
        XCTAssertFalse(hasCookie(for: "a.example"))
        XCTAssertTrue(hasCookie(for: "b.example"), "the new server's own cookies are not ours to drop")
    }

    /// The same server behind a different path is not a different server —
    /// forgetting the token there would sign the user out for correcting a URL.
    func testCorrectingThePathKeepsTheSession() {
        store.save(token: "token-do-servidor-a")
        let c = client(at: "https://a.example")

        c.updateConfig(OWConfig(baseURL: URL(string: "https://a.example/openwebui")!))

        XCTAssertEqual(c.token, "token-do-servidor-a")
        XCTAssertEqual(store.loadToken(), "token-do-servidor-a")
    }

    // MARK: - Taking on a token, and giving one up

    /// The accepting half of `adopt`, whose refusing half is in
    /// `RequestStackTests`: the candidate is only kept once the server agrees it
    /// is a session, and it is the *candidate* — not the token already held —
    /// that is offered for that verdict.
    func testAnAcceptedCandidateReplacesTheTokenAndIsWhatWasOffered() async throws {
        store.save(token: "token-antigo")
        StubTransport.route("/api/v1/auths",
                            .json(#"{"id":"u1","email":"joao@example.com","name":"João"}"#))
        let c = client(at: "https://a.example")

        let user = try await c.adopt(token: "candidato")

        XCTAssertEqual(user.email, "joao@example.com")
        XCTAssertEqual(c.token, "candidato")
        XCTAssertEqual(store.loadToken(), "candidato")
        XCTAssertEqual(StubTransport.sentHeaders["/api/v1/auths"]?["Authorization"], "Bearer candidato",
                       "the old token must not be what the server was asked about")
    }

    /// Two refusals share this status code and neither is the user's fault, so
    /// the server's own sentence has to arrive verbatim: only it says whether
    /// the admin has left token exchange off, or whether this person simply has
    /// to sign in through a browser once first.
    func testATokenExchangeRefusalReachesTheCallerInTheServersOwnWords() async {
        StubTransport.route("/api/v1/auths/oauth/google/token/exchange",
                            .json(#"{"detail":"Token exchange is disabled"}"#, status: 403))
        let c = client(at: "https://a.example")

        let err = await owError {
            try await c.exchangeOAuthToken(provider: "google", providerToken: "ya29.a0")
        }
        guard case .http(let code, let detail)? = err else {
            return XCTFail("expected .http, got \(String(describing: err))")
        }
        XCTAssertEqual(code, 403)
        XCTAssertEqual(detail, "Token exchange is disabled")
    }

    /// Signing out is a local decision. The server is told as a courtesy — with
    /// `try?`, because a user on a plane still means it — so a refusal, or no
    /// answer at all, must not leave the credential on the device.
    func testSigningOutClearsTheDeviceEvenWhenTheServerRefuses() async {
        store.save(token: "token-vivo")
        store.saveCredentials(email: "joao@example.com", password: "hunter2")
        StubTransport.route("/api/v1/auths/signout", .json(#"{"detail":"boom"}"#, status: 500))
        let c = client(at: "https://a.example")

        await c.signOut()

        XCTAssertNil(c.token)
        XCTAssertFalse(c.isAuthenticated)
        XCTAssertNil(store.loadToken())
        XCTAssertNil(store.loadEmail())
        XCTAssertNil(store.loadPassword())
    }

    /// The Keychain is not the only place a session lives. Open WebUI sets a
    /// `token` cookie alongside the bearer token, both of this client's sessions
    /// share the process-wide jar, and nothing here ever emptied it — so
    /// offline, where `try?` swallows the signout entirely, the user was signed
    /// out of the app and straight back in by the cookie on the next request.
    func testSigningOutRemovesThisServersCookiesAndNobodyElses() async {
        seedCookie(for: "a.example")
        seedCookie(for: "b.example")
        store.save(token: "token-vivo")
        StubTransport.route("/api/v1/auths/signout", .json(#"{"detail":"boom"}"#, status: 500))
        let c = client(at: "https://a.example")

        await c.signOut()

        XCTAssertFalse(hasCookie(for: "a.example"), "a refused signout still has to empty the device")
        XCTAssertTrue(hasCookie(for: "b.example"), "another host's cookies are not this server's to drop")
    }

    /// What the previous server said about itself is not an answer about this
    /// one. `ensureServerInfo` sets its flag *before* its await, so a version
    /// left behind at a switch is never asked for again: if server B's
    /// `/api/config` then fails, the merge gate goes on answering for server A —
    /// and on a 0.10 server that answer omits a node from a write, which deletes
    /// the message.
    func testSwitchingServersForgetsWhatTheOldOneSaidAboutItself() async throws {
        StubTransport.route("/api/config", .json(#"{"version":"0.11.1"}"#))
        let c = client(at: "https://a.example")
        _ = try await c.serverConfig()
        XCTAssertTrue(c.mergesHistoryServerSide, "the fixture never learned a version to forget")

        c.updateConfig(OWConfig(baseURL: URL(string: "https://b.example")!))

        XCTAssertNil(c.serverVersion)
        XCTAssertFalse(c.mergesHistoryServerSide,
                       "an unknown version must be treated as old — never delete on a guess")

        // And it is asked again, rather than being stuck on the safe answer.
        await c.ensureServerInfo()
        XCTAssertEqual(c.serverVersion, "0.11.1")
        XCTAssertTrue(c.mergesHistoryServerSide)
    }
}
