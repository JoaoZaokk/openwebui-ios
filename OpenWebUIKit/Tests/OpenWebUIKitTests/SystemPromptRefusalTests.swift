import XCTest
@testable import OpenWebUIKit

/// Gemma served through Google's API takes no system role: a request carrying
/// one is refused with "Developer instruction is not enabled for
/// models/gemma-…". The voice mode and the image prompt helper both open with a
/// system message, so on a Gemma model neither ever produced a word.
///
/// The client now retries once with the instruction folded into the first user
/// turn — the same text reaches the model, in the only place it accepts it.
final class SystemPromptRefusalTests: XCTestCase {

    private let store = OWKeychainStore(service: "tests.systemrefusal")
    private static let completions = "/api/chat/completions"

    override func setUp() { super.setUp(); StubTransport.reset(); store.clear() }
    override func tearDown() { StubTransport.reset(); store.clear(); super.tearDown() }

    private func client() -> OpenWebUIClient {
        store.save(token: "t")
        return OpenWebUIClient(config: OWConfig(baseURL: URL(string: "https://gemma.test")!),
                               tokens: store, protocolClasses: [StubTransport.self])
    }

    private let refusal = #"[{"error":{"code":400,"message":"Developer instruction is not enabled for models/gemma-3-27b-it","status":"INVALID_ARGUMENT"}}]"#

    private func run(_ messages: [OWChatMessageInput]) async throws -> String {
        var text = ""
        for try await u in ChatCompletionsClient(client: client()).stream(model: "models/gemma-3-27b-it",
                                                                           messages: messages) {
            switch u {
            case .textDelta(let t): text += t
            case .error(let e): text += "ERROR(\(e))"
            default: break
            }
        }
        return text
    }

    private func sentMessages(_ index: Int) throws -> [[String: Any]] {
        let bodies = try XCTUnwrap(StubTransport.allBodies[Self.completions])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: bodies[index]) as? [String: Any])
        return try XCTUnwrap(obj["messages"] as? [[String: Any]])
    }

    func testARefusedSystemRoleIsRetriedInsideTheFirstUserTurn() async throws {
        StubTransport.routeSequence(Self.completions, [
            .json(refusal, status: 400),
            .sse([#"{"choices":[{"delta":{"content":"Olá!"}}]}"#, "[DONE]"]),
        ])
        let text = try await run([
            OWChatMessageInput(role: "system", text: "Responda em português."),
            OWChatMessageInput(role: "user", text: "Oi"),
        ])
        XCTAssertEqual(text, "Olá!")
        XCTAssertEqual(StubTransport.allBodies[Self.completions]?.count, 2)
        let retried = try sentMessages(1)
        XCTAssertEqual(retried.map { $0["role"] as? String }, ["user"])
        XCTAssertEqual(retried.first?["content"] as? String, "Responda em português.\n\nOi")
    }

    func testTheRefusalArrivingAsAStreamFrameIsRetriedToo() async throws {
        StubTransport.routeSequence(Self.completions, [
            .sse([#"{"error":{"message":"Developer instruction is not enabled for models/gemma-3-27b-it"}}"#]),
            .sse([#"{"choices":[{"delta":{"content":"Pronto"}}]}"#, "[DONE]"]),
        ])
        let text = try await run([
            OWChatMessageInput(role: "system", text: "Seja breve."),
            OWChatMessageInput(role: "user", text: "Resuma"),
            OWChatMessageInput(role: "assistant", text: "Ok"),
            OWChatMessageInput(role: "user", text: "Agora"),
        ])
        XCTAssertEqual(text, "Pronto")
        let retried = try sentMessages(1)
        XCTAssertEqual(retried.map { $0["role"] as? String }, ["user", "assistant", "user"])
        XCTAssertEqual(retried.first?["content"] as? String, "Seja breve.\n\nResuma")
    }

    func testWithoutASystemMessageTheRefusalIsShownAsIs() async throws {
        StubTransport.routeSequence(Self.completions, [.json(refusal, status: 400)])
        do {
            _ = try await run([OWChatMessageInput(role: "user", text: "Oi")])
            XCTFail("expected the refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription,
                           "Developer instruction is not enabled for models/gemma-3-27b-it")
        }
        XCTAssertEqual(StubTransport.allBodies[Self.completions]?.count, 1, "no retry without a system turn")
    }

    func testAnUnrelatedRefusalIsNotRetried() async throws {
        StubTransport.routeSequence(Self.completions, [
            .json(#"[{"error":{"code":400,"message":"API key not valid. Please pass a valid API key."}}]"#, status: 400),
        ])
        do {
            _ = try await run([OWChatMessageInput(role: "system", text: "x"),
                               OWChatMessageInput(role: "user", text: "Oi")])
            XCTFail("expected the refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription, "API key not valid. Please pass a valid API key.")
        }
        XCTAssertEqual(StubTransport.allBodies[Self.completions]?.count, 1)
    }
}
