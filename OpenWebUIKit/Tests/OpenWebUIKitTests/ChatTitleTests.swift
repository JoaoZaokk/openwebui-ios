import XCTest
@testable import OpenWebUIKit

/// Who names a conversation, and what the app is allowed to make of the answer.
///
/// `POST /api/v1/tasks/title/completions` (backend routers/tasks.py
/// `generate_title`) is the whole feature: the server picks the task model, fills
/// the admin's template — which asks for a raw JSON object `{ "title": "…" }` and
/// reads only `{{MESSAGES:END:2}}` — and answers 200 `{"detail": "Title
/// generation is disabled"}` when the admin switched it off. That "disabled" is
/// an answer, not an error, and the app's response to it is to do nothing.
///
/// Everything below pins the two halves the app owns: sending exactly the last
/// two messages, and refusing to turn a model's prose into a title when the
/// template was ignored.
final class ChatTitleTests: XCTestCase {

    private let store = OWKeychainStore(service: "tests.title")
    private let path = "/api/v1/tasks/title/completions"

    override func setUp() { StubTransport.reset(); store.clear(); store.save(token: "t") }
    override func tearDown() { StubTransport.reset(); store.clear() }

    private func client() -> OpenWebUIClient {
        OpenWebUIClient(config: OWConfig(baseURL: URL(string: "https://title.test")!),
                        tokens: store, protocolClasses: [StubTransport.self])
    }

    /// A normal non-streamed completion carrying `content`, built through
    /// `JSONSerialization` so the content may hold quotes and newlines freely.
    private static func completion(_ content: String) -> String {
        let obj: [String: Any] = ["id": "task-1",
                                  "choices": [["index": 0,
                                               "message": ["role": "assistant", "content": content]]]]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(decoding: data, as: UTF8.self)
    }

    private static func parse(_ content: String) -> String? {
        OpenWebUIClient.title(fromTaskResponse: Data(completion(content).utf8))
    }

    // MARK: - The parser (the web client's, mirrored)

    func testTheRawObjectTheTemplateAsksFor() {
        XCTAssertEqual(Self.parse(#"{"title":"Stock Trends"}"#), "Stock Trends")
    }

    func testAFencedObjectWithProseAroundIt() {
        let content = """
        Sure! Here is the title you asked for:

        ```json
        { "title": "Tendências do Mercado" }
        ```

        Let me know if you want another one.
        """
        XCTAssertEqual(Self.parse(content), "Tendências do Mercado")
    }

    /// Small models quote JSON the way they quote prose. The web client rewrites
    /// `'`, `‘`, `’` and a backtick to `"` before parsing, so this is a title.
    func testSingleAndCurlyQuotesAreNormalized() {
        XCTAssertEqual(Self.parse("{'title': 'Receita de pão'}"), "Receita de pão")
        XCTAssertEqual(Self.parse("{\u{2018}title\u{2019}: \u{2018}Curly\u{2019}}"), "Curly")
        XCTAssertEqual(Self.parse("{`title`: `Backtick`}"), "Backtick")
    }

    /// A reasoning model prepends its thinking. No stripping is needed: the first
    /// `{` is already past it.
    func testAThinkBlockBeforeTheObjectIsSkipped() {
        let content = """
        <think>
        The user asked about the Selic rate and inflation. A short Portuguese title fits.
        </think>
        {"title": "Selic e inflação"}
        """
        XCTAssertEqual(Self.parse(content), "Selic e inflação")
    }

    // MARK: - Everything that is not a title

    /// The admin switched title generation off. 200, no `choices` — and the only
    /// correct reaction is to keep the stub title, which nil is how the kit says.
    func testTheDisabledAnswerIsNilAndNotAnError() {
        XCTAssertNil(OpenWebUIClient.title(
            fromTaskResponse: Data(#"{"detail":"Title generation is disabled"}"#.utf8)))
    }

    /// The model ignored the template and just wrote a line. Installing that as the
    /// chat's name is exactly the guessing this feature exists to stop.
    func testPlainProseWithNoObjectIsNil() {
        XCTAssertNil(Self.parse("Sure — how about Stock Trends?"))
    }

    func testAnEmptyTitleIsNil() {
        XCTAssertNil(Self.parse(#"{"title": ""}"#))
        XCTAssertNil(Self.parse(#"{"title": "   "}"#))
    }

    /// The tags task's answer, which shares this parser's shape but not its key.
    func testADifferentObjectIsNil() {
        XCTAssertNil(Self.parse(#"{"tags":["finance","stocks"]}"#))
    }

    func testAMalformedObjectIsNil() {
        XCTAssertNil(Self.parse(#"{"title": "unclosed}"#))
    }

    // MARK: - The wire

    private static let fourTurns = [
        OWChatMessageInput(role: "user", text: "Oi"),
        OWChatMessageInput(role: "assistant", text: "Olá! Em que posso ajudar?"),
        OWChatMessageInput(role: "user", text: "Explique a Selic", imageURLs: ["data:image/png;base64,AAA"]),
        OWChatMessageInput(role: "assistant", text: "A Selic é a taxa básica de juros…")
    ]

    /// `{{MESSAGES:END:2}}`: the template reads the last two messages, so those are
    /// the two that go — as plain text, with the image parts dropped. Sending the
    /// whole conversation, or an OpenAI parts array, would reach the task model as
    /// noise inside a string template.
    func testItSendsTheLastTwoMessagesAsPlainText() async throws {
        StubTransport.route(path, .json(Self.completion(#"{"title":"Selic explicada"}"#)))

        let title = try await client().generateTitle(model: "llama3", messages: Self.fourTurns,
                                                     chatID: "c1")
        XCTAssertEqual(title, "Selic explicada")

        let sent = try XCTUnwrap(StubTransport.sentJSON(path))
        XCTAssertEqual(sent["model"] as? String, "llama3")
        XCTAssertEqual(sent["chat_id"] as? String, "c1")
        let msgs = try XCTUnwrap(sent["messages"] as? [[String: Any]])
        XCTAssertEqual(msgs.count, 2, "only the last two, whatever the conversation's length")
        XCTAssertEqual(msgs[0]["role"] as? String, "user")
        XCTAssertEqual(msgs[0]["content"] as? String, "Explique a Selic")
        XCTAssertEqual(msgs[1]["role"] as? String, "assistant")
        XCTAssertEqual(msgs[1]["content"] as? String, "A Selic é a taxa básica de juros…")
        XCTAssertEqual(Set(msgs[0].keys), ["role", "content"], "no image parts, no extra keys")
    }

    /// A chat that isn't saved yet has no id, and the key is simply absent.
    func testAnImageOnlyUserTurnStillGoesAndTheChatIdIsOptional() async throws {
        StubTransport.route(path, .json(Self.completion(#"{"title":"Foto do recibo"}"#)))

        let turn = [OWChatMessageInput(role: "user", text: "", imageURLs: ["data:image/png;base64,AAA"]),
                    OWChatMessageInput(role: "assistant", text: "É um recibo de energia de R$ 180.")]
        let title = try await client().generateTitle(model: "gpt-4o", messages: turn, chatID: nil)
        XCTAssertEqual(title, "Foto do recibo")

        let sent = try XCTUnwrap(StubTransport.sentJSON(path))
        XCTAssertNil(sent["chat_id"])
        let msgs = try XCTUnwrap(sent["messages"] as? [[String: Any]])
        XCTAssertEqual(msgs[0]["content"] as? String, "",
                       "an image-only turn is an empty string; the reply carries the topic")
    }

    func testTheDisabledSwitchReturnsNilWithoutThrowing() async throws {
        StubTransport.route(path, .json(#"{"detail":"Title generation is disabled"}"#))
        let title = try await client().generateTitle(model: "llama3", messages: Self.fourTurns,
                                                     chatID: "c1")
        XCTAssertNil(title, "disabled is an answer: the stub title stays, nothing is invented")
    }

    func testAServerErrorSurfacesAsAnHTTPError() async {
        StubTransport.route(path, .json(#"{"detail":"Model not found"}"#, status: 400))
        do {
            _ = try await client().generateTitle(model: "ghost", messages: Self.fourTurns, chatID: "c1")
            XCTFail("a 400 was swallowed")
        } catch OWError.http(let code, let detail) {
            XCTAssertEqual(code, 400)
            XCTAssertEqual(detail, "Model not found")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
