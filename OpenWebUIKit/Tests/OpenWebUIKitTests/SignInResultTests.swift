import XCTest
@testable import OpenWebUIKit

/// Open WebUI 0.13 can answer a sign-in with a step instead of a session.
///
/// `POST /api/v1/auths/signin`, the LDAP sign-in and the OAuth token exchange all
/// end in `create_signin_response` (utils/auth.py:671), which returns one of
/// three bodies: a session, an MFA challenge `{next_step: verify|enroll|recover,
/// challenge_token, expires_in}`, or `{next_step: "pending"}` for an account
/// awaiting approval. The client decoded only the first, so an account with
/// two-step verification failed with "Resposta inesperada do servidor".
final class SignInResultTests: XCTestCase {

    private let store = OWKeychainStore(service: "tests.signinresult")
    private let session = #"{"token":"jwt-1","token_type":"Bearer","expires_at":null,"id":"u1","email":"a@b.c","name":"A","role":"user","profile_image_url":"/p","permissions":{}}"#
    private let challengeToken = "u1.\(String(repeating: "k", count: 43))"

    override func setUp() { super.setUp(); StubTransport.reset(); store.clear() }
    override func tearDown() { StubTransport.reset(); store.clear(); super.tearDown() }

    private func client() -> OpenWebUIClient {
        OpenWebUIClient(config: OWConfig(baseURL: URL(string: "https://mfa.test")!),
                        tokens: store, protocolClasses: [StubTransport.self])
    }

    // MARK: - Decoding the three answers

    func testASessionIsASession() throws {
        guard case .session(let s) = try OWSignInResult.decode(Data(session.utf8)) else {
            return XCTFail("a body with a token is a session")
        }
        XCTAssertEqual(s.token, "jwt-1")
        XCTAssertEqual(s.email, "a@b.c")
    }

    func testEachMFAStepCarriesItsChallenge() throws {
        for (raw, kind) in [("verify", OWMFAKind.verify), ("enroll", .enroll), ("recover", .recover)] {
            let body = #"{"next_step":"\#(raw)","challenge_token":"\#(challengeToken)","expires_in":300}"#
            guard case .mfa(let c) = try OWSignInResult.decode(Data(body.utf8)) else {
                return XCTFail("\(raw) is a challenge")
            }
            XCTAssertEqual(c.kind, kind)
            XCTAssertEqual(c.challengeToken, challengeToken)
            XCTAssertEqual(c.expiresIn, 300)
        }
    }

    func testPendingIsAnAccountAwaitingApproval() throws {
        guard case .pending = try OWSignInResult.decode(Data(#"{"next_step":"pending"}"#.utf8)) else {
            return XCTFail("pending has no token and no challenge")
        }
    }

    /// A step this client does not know is not a session and not a guess: it is
    /// reported as what it is, so a newer server's extra step reads as a version
    /// problem instead of a wrong password.
    func testAStepWeDoNotKnowIsADecodingError() {
        XCTAssertThrowsError(try OWSignInResult.decode(Data(#"{"next_step":"passkey","challenge_token":"x"}"#.utf8)))
        XCTAssertThrowsError(try OWSignInResult.decode(Data(#"{"next_step":"verify"}"#.utf8)),
                             "a challenge with no challenge_token cannot be answered")
        XCTAssertThrowsError(try OWSignInResult.decode(Data(#"{"hello":1}"#.utf8)))
        XCTAssertThrowsError(try OWSignInResult.decode(Data("<html>login portal</html>".utf8)))
    }

    /// The expiry the server states is a hint; a missing one means the server's
    /// 300 seconds, not "never".
    func testAChallengeWithoutAnExpiryGetsTheServersDefault() throws {
        let body = #"{"next_step":"verify","challenge_token":"\#(challengeToken)"}"#
        guard case .mfa(let c) = try OWSignInResult.decode(Data(body.utf8)) else { return XCTFail() }
        XCTAssertEqual(c.expiresIn, 300)
    }

    // MARK: - Through the client

    func testSigningInWithTheStepsAnswerStoresNothing() async throws {
        StubTransport.route("/api/v1/auths/signin", .json(
            #"{"next_step":"verify","challenge_token":"\#(challengeToken)","expires_in":300}"#))
        let c = client()
        let r = try await c.signInResult(email: "a@b.c", password: "pw")
        guard case .mfa(let ch) = r else { return XCTFail("expected a challenge") }
        XCTAssertEqual(ch.kind, .verify)
        XCTAssertNil(c.token, "a challenge is not a session")
        XCTAssertNil(store.loadToken())
        XCTAssertFalse(c.isAuthenticated)
    }

    func testSigningInWithASessionStoresTheToken() async throws {
        StubTransport.route("/api/v1/auths/signin", .json(session))
        let c = client()
        guard case .session = try await c.signInResult(email: "a@b.c", password: "pw") else { return XCTFail() }
        XCTAssertEqual(c.token, "jwt-1")
        XCTAssertEqual(store.loadToken(), "jwt-1")
    }

    func testPendingStoresNothingEither() async throws {
        StubTransport.route("/api/v1/auths/signin", .json(#"{"next_step":"pending"}"#))
        let c = client()
        guard case .pending = try await c.signInResult(email: "a@b.c", password: "pw") else { return XCTFail() }
        XCTAssertFalse(c.isAuthenticated)
    }

    /// The old entry point still returns a user for a session, and now says WHY
    /// when it cannot, instead of failing to decode.
    func testTheOldSignInStillReturnsAUserAndNamesTheStepItStoppedAt() async throws {
        StubTransport.route("/api/v1/auths/signin", .json(session))
        let u = try await client().signIn(email: "a@b.c", password: "pw")
        XCTAssertEqual(u.id, "u1")

        StubTransport.route("/api/v1/auths/signin", .json(#"{"next_step":"pending"}"#))
        let pending = await owError { try await self.client().signIn(email: "a@b.c", password: "pw") }
        guard case .pendingApproval? = pending else { return XCTFail("\(String(describing: pending))") }

        StubTransport.route("/api/v1/auths/signin", .json(
            #"{"next_step":"enroll","challenge_token":"\#(challengeToken)","expires_in":300}"#))
        let mfa = await owError { try await self.client().signIn(email: "a@b.c", password: "pw") }
        guard case .mfaRequired(let ch)? = mfa else { return XCTFail("\(String(describing: mfa))") }
        XCTAssertEqual(ch.kind, .enroll)
    }

    func testLDAPAndTheOAuthExchangeAnswerInTheSameThreeShapes() async throws {
        StubTransport.route("/api/v1/auths/ldap", .json(#"{"next_step":"pending"}"#))
        guard case .pending = try await client().signInLDAPResult(user: "u", password: "p") else { return XCTFail() }

        StubTransport.route("/api/v1/auths/oauth/google/token/exchange", .json(
            #"{"next_step":"verify","challenge_token":"\#(challengeToken)","expires_in":300}"#))
        guard case .mfa = try await client().exchangeOAuthTokenResult(provider: "google", providerToken: "t")
        else { return XCTFail() }

        StubTransport.route("/api/v1/auths/oauth/google/token/exchange", .json(session))
        let c = client()
        guard case .session = try await c.exchangeOAuthTokenResult(provider: "google", providerToken: "t")
        else { return XCTFail() }
        XCTAssertEqual(c.token, "jwt-1")
    }

    /// 409 from the server: the password or the session stamp changed under the
    /// sign-in. It reaches the caller as an HTTP error, which the screen maps.
    func testAConflictIsPassedThrough() async {
        StubTransport.route("/api/v1/auths/signin", .json(
            #"{"detail":"Authentication changed. Please sign in again."}"#, status: 409))
        let e = await owError { try await self.client().signInResult(email: "a@b.c", password: "pw") }
        guard case .http(409, let why?)? = e else { return XCTFail("\(String(describing: e))") }
        XCTAssertEqual(why, "Authentication changed. Please sign in again.")
        XCTAssertEqual(OWMFAFailure.classify(status: 409, detail: why), .authenticationChanged)
    }

    // MARK: - Answering the challenge

    func testVerifyPostsTheChallengeTheCodeAndTheRecoveryFlag() async throws {
        StubTransport.route("/api/v1/auths/mfa/verify", .json(session))
        let c = client()
        let u = try await c.verifyMFA(
            challenge: OWMFAChallenge(kind: .verify, challengeToken: challengeToken, expiresIn: 300),
            code: "123456", recovery: false)
        XCTAssertEqual(u.id, "u1")
        let body = try XCTUnwrap(StubTransport.sentJSON("/api/v1/auths/mfa/verify"))
        XCTAssertEqual(Set(body.keys), ["challenge_token", "code", "recovery"], "the model forbids extra fields")
        XCTAssertEqual(body["challenge_token"] as? String, challengeToken)
        XCTAssertEqual(body["code"] as? String, "123456")
        XCTAssertEqual(body["recovery"] as? Bool, false)
        XCTAssertEqual(c.token, "jwt-1")
        XCTAssertEqual(store.loadToken(), "jwt-1")
        XCTAssertNil(store.loadCredentials(), "a verified password session has no refresh token")
    }

    func testARecoveryCodeIsSentAsOneAndTrimmed() async throws {
        StubTransport.route("/api/v1/auths/mfa/verify", .json(session))
        _ = try await client().verifyMFA(
            challenge: OWMFAChallenge(kind: .verify, challengeToken: challengeToken, expiresIn: 300),
            code: "  ABCD-1234  ", recovery: true)
        let body = try XCTUnwrap(StubTransport.sentJSON("/api/v1/auths/mfa/verify"))
        XCTAssertEqual(body["recovery"] as? Bool, true)
        XCTAssertEqual(body["code"] as? String, "ABCD-1234")
    }

    /// Authenticator apps show "123 456"; the server wants six digits.
    func testSpacesInsideACodeAreDroppedForTOTPOnly() {
        XCTAssertEqual(OWMFAChallenge.normalizedCode("123 456", recovery: false), "123456")
        XCTAssertEqual(OWMFAChallenge.normalizedCode(" 123456\n", recovery: false), "123456")
        XCTAssertEqual(OWMFAChallenge.normalizedCode(" ab cd ", recovery: true), "ab cd")
    }

    func testAWrongCodeSignsNobodyOutAndIsReadable() async {
        StubTransport.route("/api/v1/auths/mfa/verify", .json(
            #"{"detail":"Invalid or already used code."}"#, status: 401))
        store.save(token: "existing")
        let c = client()
        let e = await owErrorAny { try await c.verifyMFA(
            challenge: OWMFAChallenge(kind: .verify, challengeToken: self.challengeToken, expiresIn: 300),
            code: "000000", recovery: false) }
        let failure = (e as? OWMFAError)?.failure
        XCTAssertEqual(failure, .invalidCode)
        XCTAssertEqual(c.token, "existing", "a 401 from the verify step is a wrong code, not a dead session")
        XCTAssertNotNil(store.loadToken())
    }

    func testTheNetworkFailingDuringVerifyIsNotAMFAFailure() async {
        StubTransport.route("/api/v1/auths/mfa/verify", .failing(.notConnectedToInternet))
        let e = await owErrorAny { try await self.client().verifyMFA(
            challenge: OWMFAChallenge(kind: .verify, challengeToken: self.challengeToken, expiresIn: 300),
            code: "000000", recovery: false) }
        XCTAssertNil(e as? OWMFAError)
        XCTAssertNotNil(e)
    }

    // MARK: - What the failures say

    func testEveryDetailTheVerifyRouteAnswersWithIsClassified() {
        let table: [(Int, String, OWMFAFailure)] = [
            (401, "Invalid or already used code.", .invalidCode),
            (401, "This authentication step expired. Please start again.", .expired),
            (403, "Account is awaiting approval.", .awaitingApproval),
            (403, "MFA is disabled. Please sign in again.", .mfaDisabled),
            (429, "Too many codes. Please sign in again.", .tooManyCodes),
            (429, "Too many attempts. Please try again later.", .tooManyAttempts),
            (409, "Authentication changed. Please sign in again.", .authenticationChanged),
            (409, "Authentication is busy. Try again.", .busy),
            (503, "Authentication is temporarily unavailable.", .unavailable),
            (422, "Invalid authentication request.", .other("Invalid authentication request.")),
        ]
        for (status, detail, expected) in table {
            XCTAssertEqual(OWMFAFailure.classify(status: status, detail: detail), expected, "\(status) \(detail)")
        }
        XCTAssertEqual(OWMFAFailure.classify(status: 418, detail: "teapot"), .other("teapot"))
        XCTAssertEqual(OWMFAFailure.classify(status: 401, detail: nil), .invalidCode)
        XCTAssertEqual(OWMFAFailure.classify(status: 429, detail: nil), .tooManyAttempts)
    }

    /// Which failures leave the challenge alive: the user may try the next code
    /// only for these; every other one needs a fresh sign-in.
    func testOnlyAWrongCodeOrABusyServerLeavesTheChallengeAlive() {
        XCTAssertFalse(OWMFAFailure.invalidCode.endsChallenge)
        XCTAssertFalse(OWMFAFailure.busy.endsChallenge)
        XCTAssertFalse(OWMFAFailure.unavailable.endsChallenge)
        XCTAssertFalse(OWMFAFailure.tooManyAttempts.endsChallenge, "wait and retry the same challenge")
        for f in [OWMFAFailure.expired, .mfaDisabled, .tooManyCodes, .authenticationChanged, .awaitingApproval] {
            XCTAssertTrue(f.endsChallenge, "\(f)")
        }
    }

    func testEveryFailureHasASentenceOfItsOwn() {
        let all: [OWMFAFailure] = [.invalidCode, .expired, .awaitingApproval, .mfaDisabled, .tooManyCodes,
                                   .tooManyAttempts, .authenticationChanged, .busy, .unavailable, .other("x")]
        let sentences = all.map(\.message)
        XCTAssertEqual(Set(sentences).count, all.count)
        XCTAssertTrue(sentences.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(OWMFAFailure.other("o servidor disse isto").message, "o servidor disse isto")
    }
}

extension XCTestCase {
    /// Like `owError`, for a call whose failure is not an `OWError`.
    func owErrorAny<T>(file: StaticString = #filePath, line: UInt = #line,
                       _ body: () async throws -> T) async -> Error? {
        do {
            _ = try await body()
            XCTFail("the call was supposed to fail", file: file, line: line)
            return nil
        } catch {
            return error
        }
    }
}
