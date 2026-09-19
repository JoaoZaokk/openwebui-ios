import XCTest
@testable import OpenWebUIKit

/// The seam itself: a client built with `protocolClasses: [StubTransport.self]`
/// talks to the stub, and a client built the way the app builds it does not.
final class TransportSeamTests: XCTestCase {

    override func setUp() { StubTransport.reset() }
    override func tearDown() { StubTransport.reset() }

    static func stubbed(service: String = "tests.seam") -> OpenWebUIClient {
        OpenWebUIClient(config: OWConfig(baseURL: URL(string: "https://seam.test")!),
                        tokens: OWKeychainStore(service: service),
                        protocolClasses: [StubTransport.self])
    }

    func testTheStubIsWhoAnswered() async throws {
        StubTransport.route("/api/config", .json(#"{"name":"stub","version":"0.11.3"}"#))
        let cfg = try await Self.stubbed().serverConfig()
        XCTAssertEqual(cfg.name, "stub")
        XCTAssertEqual(cfg.version, "0.11.3")
        XCTAssertEqual(StubTransport.seen, ["/api/config"])
        XCTAssertEqual(StubTransport.sentHeaders["/api/config"]?["Accept"], "application/json")
    }

    /// The client turns a transport failure into an `OWError` right at the
    /// boundary, and whatever sentence it puts in there is the one the banner
    /// shows. Taking `URLError.localizedDescription` there meant taking
    /// Foundation's sentence, written in the *device's* language: a phone in
    /// Portuguese put "Não foi possível conectar-se ao servidor." on the screen
    /// of an app the user had set to English, every time the server was asleep.
    func testATransportFailureIsDescribedInTheAppLanguage() async {
        StubTransport.route("/api/config", .failing(.cannotConnectToHost))
        do {
            _ = try await Self.stubbed().serverConfig()
            XCTFail("a failing transport answered")
        } catch {
            XCTAssertEqual(OWFailure.msg(error), L("Não consegui falar com o servidor. Ele está ligado?"))
        }
    }

    /// The production default is Foundation's own chain. This pins that `nil`
    /// really means "no interception" — otherwise a stub registered by one test
    /// could quietly answer the app's own requests in another.
    func testTheProductionDefaultDoesNotReachTheStub() async {
        StubTransport.route("/api/config", .json(#"{"version":"0.11.3"}"#))
        let client = OpenWebUIClient(config: OWConfig(baseURL: URL(string: "https://seam.invalid")!),
                                     tokens: OWKeychainStore(service: "tests.seam"))
        do {
            _ = try await client.serverConfig()
            XCTFail("a host that does not exist answered")
        } catch {
            XCTAssertFalse(StubTransport.requested("/api/config"))
        }
    }
}
