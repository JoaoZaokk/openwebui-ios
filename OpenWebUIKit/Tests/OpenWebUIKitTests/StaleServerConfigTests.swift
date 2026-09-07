import XCTest
@testable import OpenWebUIKit

/// A slow `/api/config` from the server the app just left must not describe
/// the server it now points at.
final class StaleServerConfigTests: XCTestCase {

    override func setUp() { StubTransport.reset() }
    override func tearDown() { StubTransport.reset() }

    func testAnAnswerFromThePreviousServerDoesNotArmTheMergeGate() async throws {
        var slow = StubTransport.Reply.json(#"{"version":"0.11.3"}"#)
        slow.delay = 0.3
        StubTransport.route("/api/config", slow)
        let client = OpenWebUIClient(config: OWConfig(baseURL: URL(string: "https://old.test")!),
                                     tokens: OWKeychainStore(service: "tests.stale"),
                                     protocolClasses: [StubTransport.self])
        async let stale = client.serverConfig()
        try await Task.sleep(nanoseconds: 50_000_000)
        client.updateConfig(OWConfig(baseURL: URL(string: "https://new.test")!))

        let cfg = try await stale
        XCTAssertEqual(cfg.version, "0.11.3", "the caller still gets the answer it asked for")
        XCTAssertNil(client.serverVersion, "but the client does not adopt it as the new server's")
        XCTAssertFalse(client.mergesHistoryServerSide)

        // The new server's own answer is what counts.
        StubTransport.route("/api/config", .json(#"{"version":"0.10.6"}"#))
        _ = try await client.serverConfig()
        XCTAssertEqual(client.serverVersion, "0.10.6")
        XCTAssertFalse(client.mergesHistoryServerSide)
    }

    func testTheCurrentServersAnswerIsAdopted() async throws {
        StubTransport.route("/api/config", .json(#"{"version":"0.11.3"}"#))
        let client = OpenWebUIClient(config: OWConfig(baseURL: URL(string: "https://one.test")!),
                                     tokens: OWKeychainStore(service: "tests.stale"),
                                     protocolClasses: [StubTransport.self])
        _ = try await client.serverConfig()
        XCTAssertEqual(client.serverVersion, "0.11.3")
        XCTAssertTrue(client.mergesHistoryServerSide)
    }
}
