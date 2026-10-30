import XCTest
@testable import OpenWebUIKit

/// A request past the model's context, sent through the owner's Open WebUI
/// on 2026-10-28 (~1.15M tokens). glm-5.3-flash answered HTTP 400 "Prompt
/// exceeds max length"; mimo-v2.6-flash raised nothing at all — it opened the
/// reply and closed it at once with `finish_reason: "length"`, having written
/// nothing. The app showed that as "(no response)", never as a full context.
final class ContextFullStreamTests: XCTestCase {

    private let store = OWKeychainStore(service: "tests.contextfull")
    private static let completions = "/api/chat/completions"

    override func setUp() { super.setUp(); StubTransport.reset(); store.clear() }
    override func tearDown() { StubTransport.reset(); store.clear(); super.tearDown() }

    private func updates() async throws -> (text: String, errors: [String]) {
        store.save(token: "t")
        let c = OpenWebUIClient(config: OWConfig(baseURL: URL(string: "https://full.test")!),
                                tokens: store, protocolClasses: [StubTransport.self])
        var text = "", errors: [String] = []
        for try await u in ChatCompletionsClient(client: c).stream(model: "m", messages: [OWChatMessageInput(role: "user", text: "x")]) {
            switch u {
            case .textDelta(let t): text += t
            case .error(let e): errors.append(e)
            default: break
            }
        }
        return (text, errors)
    }

    /// Frames as mimo-v2.6-flash sent them.
    func testAReplyClosedForLengthBeforeAWordIsAFullContext() async throws {
        StubTransport.route(Self.completions, .sse([
            #"{"choices":[{"delta":{"content":"","role":"assistant","tool_calls":null,"reasoning_content":null},"finish_reason":null,"index":0}],"model":"mimo-v2.6-flash","object":"chat.completion.chunk"}"#,
            #"{"choices":[{"delta":{"content":null,"role":null,"tool_calls":null,"reasoning_content":null},"finish_reason":"length","index":0}],"model":"mimo-v2.6-flash","object":"chat.completion.chunk"}"#,
            #"{"choices":[],"model":"mimo-v2.6-flash","object":"chat.completion.chunk"}"#,
            "[DONE]",
        ]))
        let r = try await updates()
        XCTAssertEqual(r.text, "")
        XCTAssertEqual(r.errors, [OWStreamUpdate.contextFull])
    }

    func testAReplyCutForLengthAfterWritingIsJustLong() async throws {
        StubTransport.route(Self.completions, .sse([
            #"{"choices":[{"delta":{"content":"Uma resposta comprida"},"finish_reason":null,"index":0}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"length","index":0}]}"#,
            "[DONE]",
        ]))
        let r = try await updates()
        XCTAssertEqual(r.text, "Uma resposta comprida")
        XCTAssertEqual(r.errors, [])
    }

    func testThinkingThatRanOutIsNotAFullContext() async throws {
        StubTransport.route(Self.completions, .sse([
            #"{"choices":[{"delta":{"reasoning_content":"pensando muito"},"finish_reason":null,"index":0}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"length","index":0}]}"#,
            "[DONE]",
        ]))
        let r = try await updates()
        XCTAssertEqual(r.errors, [])
    }
}
