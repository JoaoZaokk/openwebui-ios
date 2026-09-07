import XCTest
@testable import OpenWebUIKit

/// Everything `send` does between a URL and a decoded value, over the transport
/// seam: the 401 hop, the 2xx guard, `decodeList` and `detail(from:)`.
///
/// The distinction the whole file exists for is 401 versus 403. Open WebUI
/// answers 403 for a non-admin on an admin route, a model outside the user's
/// access control, or a feature permission the account lacks — none of which
/// means the session died. Folding the two together logged the user out over a
/// permission denial, and the only place that rule lives is one comparison
/// inside `send`. It was reachable only with a live server until the seam.
final class RequestStackTests: XCTestCase {

    /// Never the default service: these tests write a token, and the default
    /// store is the developer's own signed-in session.
    private let store = OWKeychainStore(service: "tests.requeststack")

    override func setUp() {
        super.setUp()
        StubTransport.reset()
        store.clear()
    }

    override func tearDown() {
        StubTransport.reset()
        store.clear()
        super.tearDown()
    }

    /// A client that already holds a session, built the way a cold launch builds
    /// one — the token comes back out of the store inside `init`, which is also
    /// what makes "the store still has it" a meaningful assertion afterwards.
    private func signedInClient() -> OpenWebUIClient {
        store.save(token: "token-vivo")
        let client = OpenWebUIClient(config: OWConfig(baseURL: URL(string: "https://wire.test")!),
                                     tokens: store, protocolClasses: [StubTransport.self])
        XCTAssertTrue(client.isAuthenticated, "the fixture never had a session to lose")
        return client
    }

    private func sessionEnded() -> XCTNSNotificationExpectation {
        XCTNSNotificationExpectation(name: OpenWebUIClient.sessionEndedNotification)
    }

    // MARK: - 401 versus 403

    /// A dead token has to be forgotten in all three places at once. Leaving it
    /// in memory keeps every screen retrying with it; leaving it in the Keychain
    /// brings it back on the next cold launch; skipping the notification leaves
    /// the user staring at "Sessão expirada" on a screen with no way to log in.
    func testA401ForgetsTheTokenInMemoryInTheStoreAndTellsTheApp() async {
        StubTransport.route("/api/models", .json(#"{"detail":"Not authenticated"}"#, status: 401))
        let client = signedInClient()
        let ended = sessionEnded()

        let err = await owError { try await client.models() }
        guard case .notAuthenticated? = err else {
            return XCTFail("expected .notAuthenticated, got \(String(describing: err))")
        }

        XCTAssertNil(client.token)
        XCTAssertFalse(client.isAuthenticated)
        XCTAssertNil(store.loadToken(), "a token the server rejected must not survive a relaunch")
        await fulfillment(of: [ended], timeout: 1)
    }

    /// The counterpart, and the reason the comparison is `==` and not `>=`: the
    /// server said what this account may not do, and the session it said it with
    /// is still perfectly good.
    func testA403IsAPermissionDenialAndKeepsTheSession() async {
        StubTransport.route("/api/models",
                            .json(#"{"detail":"Model not found or access denied"}"#, status: 403))
        let client = signedInClient()
        let ended = sessionEnded()
        ended.isInverted = true

        let err = await owError { try await client.models() }
        guard case .http(let code, let detail)? = err else {
            return XCTFail("expected .http, got \(String(describing: err))")
        }
        XCTAssertEqual(code, 403)
        XCTAssertEqual(detail, "Model not found or access denied",
                       "the server's own sentence is the only thing that says which permission")

        XCTAssertEqual(client.token, "token-vivo")
        XCTAssertTrue(client.isAuthenticated)
        XCTAssertEqual(store.loadToken(), "token-vivo")
        await fulfillment(of: [ended], timeout: 0.3)
    }

    /// `adopt` builds its request by hand precisely so a bad candidate cannot
    /// reach the 401 hop. The user pasting a stale API key, or an SSO callback
    /// handing back a cookie the server has already rotated, must not cost them
    /// the session they were signed in with.
    func testARejectedCandidateTokenDoesNotTakeTheGoodSessionWithIt() async {
        // `URL.path` drops a trailing slash, so the route is the endpoint minus it.
        StubTransport.route("/api/v1/auths", .json(#"{"detail":"Invalid token"}"#, status: 401))
        let client = signedInClient()
        let ended = sessionEnded()
        ended.isInverted = true

        let err = await owError { try await client.adopt(token: "colado-pelo-usuario") }
        guard case .http(let code, let detail)? = err else {
            return XCTFail("expected .http, got \(String(describing: err))")
        }
        XCTAssertEqual(code, 401, "a 401 here is a verdict on the candidate, not on the session")
        XCTAssertEqual(detail, "Invalid token")

        XCTAssertEqual(client.token, "token-vivo")
        XCTAssertEqual(store.loadToken(), "token-vivo")
        await fulfillment(of: [ended], timeout: 0.3)
    }

    // MARK: - decodeList, per endpoint, on the wire

    /// `/api/models` wraps its array under `data`; servers old enough to predate
    /// the wrapper answer with the bare array. Both are answers.
    func testModelsAcceptsTheWrappedListAndTheBareOne() async throws {
        let client = signedInClient()

        StubTransport.route("/api/models", .json(#"{"data":[{"id":"llama3.1:8b","name":"Llama 3.1"}]}"#))
        let wrapped = try await client.models()
        XCTAssertEqual(wrapped.map(\.id), ["llama3.1:8b"])

        StubTransport.route("/api/models", .json(#"[{"id":"gpt-4o","name":"GPT-4o"}]"#))
        let bare = try await client.models()
        XCTAssertEqual(bare.map(\.id), ["gpt-4o"])
    }

    /// The failure that motivated `decodeList` throwing at all: a reverse proxy
    /// or an SSO portal answers the API with its own login page under HTTP 200.
    /// As an empty list that was indistinguishable from an account with no
    /// models — the same screen, and nothing to tell them apart.
    func testALoginPortalAnsweredWith200IsAFailureNotAnEmptyList() async {
        StubTransport.route("/api/models",
                            .text("<!DOCTYPE html><html><head><title>Sign in</title></head><body>…</body></html>"))
        let client = signedInClient()

        let err = await owError { try await client.models() }
        guard case .decoding(let what)? = err else {
            return XCTFail("expected .decoding, got \(String(describing: err))")
        }
        XCTAssertTrue(what.contains("<!DOCTYPE html"),
                      "the head of the body is what lets a human recognise a login page: \(what)")
    }

    /// The chat list has no wrapper key at all, so `decodeList` is called without
    /// one — a different branch from `/api/models`, and the one that must not
    /// start demanding `data`.
    func testTheChatListDecodesAsABareArray() async throws {
        StubTransport.route("/api/v1/chats",
                            .json(#"[{"id":"c1","title":"Primeira"},{"id":"c2","title":""}]"#))
        let client = signedInClient()

        let chats = try await client.chats()
        XCTAssertEqual(chats.map(\.id), ["c1", "c2"])
        XCTAssertEqual(chats[1].title, "Nova conversa", "an empty title is a placeholder, not a blank row")
    }

    // MARK: - What the server said, in one sentence

    /// FastAPI answers a rejected body with `detail` as a list of per-field
    /// objects. `loc` starts with "body" on every one of them, which says
    /// nothing, so it is dropped and the fields are joined — otherwise the UI
    /// shows a Swift dictionary description to the user.
    func testFastAPIValidationErrorsBecomeOneReadableSentence() {
        let body = Data(#"""
        {"detail":[{"loc":["body","title"],"msg":"field required"},
                   {"loc":["body","models"],"msg":"not a list"}]}
        """#.utf8)
        XCTAssertEqual(OpenWebUIClient.detail(from: body),
                       "title: field required · models: not a list")
    }

    /// The three keys Open WebUI and the stacks in front of it name a refusal
    /// with, plus the two bodies that are not JSON at all.
    func testEveryShapeAServerNamesARefusalWith() {
        XCTAssertEqual(OpenWebUIClient.detail(from: Data(#"{"detail":"Token exchange is disabled"}"#.utf8)),
                       "Token exchange is disabled")
        XCTAssertEqual(OpenWebUIClient.detail(from: Data(#"{"message":"quota exceeded"}"#.utf8)),
                       "quota exceeded")
        XCTAssertEqual(OpenWebUIClient.detail(from: Data(#"{"error":"upstream refused"}"#.utf8)),
                       "upstream refused")
        // A gateway's plain-text page is still more useful than "Erro 502".
        XCTAssertEqual(OpenWebUIClient.detail(from: Data("502 Bad Gateway".utf8)), "502 Bad Gateway")
        XCTAssertNil(OpenWebUIClient.detail(from: Data()), "an empty body says nothing; don't invent a sentence")
    }
}

extension XCTestCase {
    /// `XCTAssertThrowsError` has no async form, and what these tests assert is
    /// the *case* of the `OWError` — not merely that something threw.
    func owError<T>(file: StaticString = #filePath, line: UInt = #line,
                    _ body: () async throws -> T) async -> OWError? {
        do {
            _ = try await body()
            XCTFail("the call was supposed to fail", file: file, line: line)
            return nil
        } catch let e as OWError {
            return e
        } catch {
            XCTFail("not an OWError: \(error)", file: file, line: line)
            return nil
        }
    }
}
