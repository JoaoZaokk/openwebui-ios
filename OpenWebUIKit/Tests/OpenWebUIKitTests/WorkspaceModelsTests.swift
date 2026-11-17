import XCTest
@testable import OpenWebUIKit

/// Report from 1.14 (TestFlight): "In Workspace it shows the one I created and
/// also every other model Open WebUI sees from the API. The browser only shows
/// the workspace model I created." The browser's Workspace › Models page reads
/// `GET /api/v1/models/list` (paginated, only models defined in the workspace);
/// the app read `/api/models`, which is every model the chat picker can use.
final class WorkspaceModelsTests: XCTestCase {
    private static let store = OWKeychainStore(service: "tests.wsmodels")
    override func setUp() { StubTransport.reset(); Self.store.clear() }
    override func tearDown() { StubTransport.reset(); Self.store.clear() }

    private func client() -> OpenWebUIClient {
        OpenWebUIClient(config: OWConfig(baseURL: URL(string: "https://ws.test")!),
                        tokens: Self.store, protocolClasses: [StubTransport.self])
    }

    func testOnlyTheModelsDefinedInTheWorkspaceAreListed() async throws {
        StubTransport.route("/api/v1/models/list",
            .json(#"{"items":[{"id":"fotos","name":"Fotos Gerador","base_model_id":"glm-5.3","is_active":true}],"total":1}"#))
        StubTransport.route("/api/models",
            .json(#"{"data":[{"id":"fotos","name":"Fotos Gerador"},{"id":"glm-5.3","name":"glm"},{"id":"mimo","name":"mimo"}]}"#))
        let list = try await client().workspaceModels()
        XCTAssertEqual(list.map(\.id), ["fotos"])
        XCTAssertEqual(list.first?.ownedBy, "glm-5.3", "the base model is what tells two apart")
    }

    func testPagesAreFollowedUntilTheTotalIsReached() async throws {
        let page1 = (1...30).map { #"{"id":"m\#($0)","name":"M\#($0)"}"# }.joined(separator: ",")
        let page2 = (31...32).map { #"{"id":"m\#($0)","name":"M\#($0)"}"# }.joined(separator: ",")
        StubTransport.routeSequence("/api/v1/models/list", [
            .json(#"{"items":[\#(page1)],"total":32}"#),
            .json(#"{"items":[\#(page2)],"total":32}"#),
        ])
        let list = try await client().workspaceModels()
        XCTAssertEqual(list.count, 32)
    }

    func testAServerWithoutTheListRouteFallsBackToWhatItHasAlways() async throws {
        StubTransport.route("/api/v1/models/list", .json(#"{"detail":"Not Found"}"#, status: 404))
        StubTransport.route("/api/models", .json(#"{"data":[{"id":"a","name":"A"}]}"#))
        let list = try await client().workspaceModels()
        XCTAssertEqual(list.map(\.id), ["a"])
    }
}
