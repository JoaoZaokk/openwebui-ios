import XCTest
@testable import OpenWebUIKit

/// Open WebUI answers 401 for "no such chat" with the same status it uses for a
/// dead token. Only the token case may end the session.
final class NotFoundAs401Tests: XCTestCase {

    private let store = OWKeychainStore(service: "tests.notfound")

    override func setUp() { StubTransport.reset(); store.clear(); store.save(token: "good") }
    override func tearDown() { StubTransport.reset(); store.clear() }

    private func client() -> OpenWebUIClient {
        OpenWebUIClient(config: OWConfig(baseURL: URL(string: "https://seam.test")!),
                        tokens: store, protocolClasses: [StubTransport.self])
    }

    func testNotFoundWearing401IsA404AndKeepsTheSession() async {
        StubTransport.route("/api/v1/chats/gone",
                            .json(#"{"detail":"We could not find what you're looking for :/"}"#, status: 401))
        let ended = XCTNSNotificationExpectation(name: OpenWebUIClient.sessionEndedNotification)
        ended.isInverted = true
        let c = client()
        do {
            _ = try await c.chat("gone")
            XCTFail("a missing chat decoded")
        } catch OWError.http(let code, let detail) {
            XCTAssertEqual(code, 404)
            XCTAssertEqual(detail, OpenWebUIClient.serverNotFoundSentence)
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertTrue(c.isAuthenticated, "the token is still good")
        XCTAssertEqual(store.loadToken(), "good")
        await fulfillment(of: [ended], timeout: 0.3)
    }

    func testAPlain401StillEndsTheSession() async {
        StubTransport.route("/api/v1/chats/any", .json(#"{"detail":"Not authenticated"}"#, status: 401))
        let ended = XCTNSNotificationExpectation(name: OpenWebUIClient.sessionEndedNotification)
        let c = client()
        do {
            _ = try await c.chat("any")
            XCTFail("decoded")
        } catch OWError.notAuthenticated {
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertFalse(c.isAuthenticated)
        XCTAssertNil(store.loadToken())
        await fulfillment(of: [ended], timeout: 1)
    }

    func testCacheOwnerNormalizesTheOrigin() {
        XCTAssertEqual(OpenWebUIClient.cacheOwner(origin: URL(string: "HTTPS://A.Example/some/path")!, userID: "u1"),
                       "https://a.example:443|u1")
        XCTAssertNotEqual(OpenWebUIClient.cacheOwner(origin: URL(string: "https://a.example")!, userID: "u1"),
                          OpenWebUIClient.cacheOwner(origin: URL(string: "https://a.example")!, userID: "u2"))
    }
}
