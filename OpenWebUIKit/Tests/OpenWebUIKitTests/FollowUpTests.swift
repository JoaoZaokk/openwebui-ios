import XCTest
@testable import OpenWebUIKit

/// The questions under an answer (issue #15).
///
/// `POST /api/v1/tasks/follow_up/completions` (backend routers/tasks.py
/// `generate_follow_ups`) is the web client's call: the server picks the task
/// model, fills the admin's template — which reads `{{MESSAGES:END:6}}` and asks
/// for `{ "follow_ups": ["…", …] }` — and answers 200 `{"detail": "Follow-up
/// generation is disabled"}` when the admin switched it off. The web keeps the
/// result on the reply's history node as `followUps`, so a chat reopened on
/// either side shows the same questions.
final class FollowUpTests: XCTestCase {

    private let store = OWKeychainStore(service: "tests.followups")
    private let taskPath = "/api/v1/tasks/follow_up/completions"

    override func setUp() { StubTransport.reset(); store.clear(); store.save(token: "t") }
    override func tearDown() { StubTransport.reset(); store.clear() }

    private static func completion(content: String?, reasoning: String? = nil) -> Data {
        var message: [String: Any] = ["role": "assistant"]
        if let content { message["content"] = content }
        if let reasoning { message["reasoning_content"] = reasoning }
        let obj: [String: Any] = ["id": "task-1", "choices": [["index": 0, "message": message]]]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    private static func parse(_ content: String?, reasoning: String? = nil) -> [String] {
        OpenWebUIClient.followUps(fromTaskResponse: completion(content: content, reasoning: reasoning))
    }

    // MARK: - The parser (the server's own, utils/middleware.py)

    func testTheObjectTheTemplateAsksFor() {
        XCTAssertEqual(Self.parse(#"{"follow_ups":["Why?","How so?","What's next?"]}"#),
                       ["Why?", "How so?", "What's next?"])
    }

    func testAnObjectInsideProseAndAFence() {
        let content = """
        Here you go:
        ```json
        { "follow_ups": ["Como isso funciona?", "Tem um exemplo?"] }
        ```
        """
        XCTAssertEqual(Self.parse(content), ["Como isso funciona?", "Tem um exemplo?"])
    }

    /// The title parser turns every `'` into `"` because titles come back in
    /// single-quoted pseudo-JSON. Questions are full of apostrophes; doing the
    /// same here would break "What's" into invalid JSON and lose all of them.
    func testApostrophesSurvive() {
        XCTAssertEqual(Self.parse(#"{"follow_ups":["What's the catch?","Isn't it slow?"]}"#),
                       ["What's the catch?", "Isn't it slow?"])
    }

    /// A reasoning model can leave `content` empty and put everything in
    /// `reasoning_content`; the server falls back to it, so the app does too.
    func testAnEmptyContentFallsBackToTheReasoning() {
        XCTAssertEqual(Self.parse("", reasoning: #"thinking… {"follow_ups":["E agora?"]}"#), ["E agora?"])
    }

    func testBlankEntriesAreDroppedAndTheRestTrimmed() {
        XCTAssertEqual(Self.parse(#"{"follow_ups":["  Por quê?  ","", "   ", 3, "Onde?"]}"#),
                       ["Por quê?", "Onde?"])
    }

    func testAnythingElseIsNoSuggestions() {
        XCTAssertEqual(Self.parse("Sure, ask me anything."), [])
        XCTAssertEqual(Self.parse(#"{"title":"not this"}"#), [])
        XCTAssertEqual(Self.parse(#"{"follow_ups": "one string"}"#), [])
        XCTAssertEqual(OpenWebUIClient.followUps(fromTaskResponse:
            Data(#"{"detail":"Follow-up generation is disabled"}"#.utf8)), [])
    }

    // MARK: - The request

    private func client() -> OpenWebUIClient {
        OpenWebUIClient(config: OWConfig(baseURL: URL(string: "https://followups.test")!),
                        tokens: store, protocolClasses: [StubTransport.self])
    }

    /// The default template reads the last six messages, as plain text: an
    /// OpenAI-style parts array would reach the task model as gibberish.
    func testAsksWithTheLastSixMessagesAsPlainText() async throws {
        StubTransport.route(taskPath, Reply.json(String(decoding: Self.completion(
            content: #"{"follow_ups":["Next?"]}"#), as: UTF8.self)))
        var convo = (1...8).map { OWChatMessageInput(role: $0 % 2 == 1 ? "user" : "assistant", text: "m\($0)") }
        convo[6].imageURLs = ["data:image/png;base64,AAAA"]

        let list = try await client().generateFollowUps(model: "gemma", messages: convo, chatID: "chat-1")

        XCTAssertEqual(list, ["Next?"])
        let body = try XCTUnwrap(StubTransport.sentJSON(taskPath))
        XCTAssertEqual(body["model"] as? String, "gemma")
        XCTAssertEqual(body["chat_id"] as? String, "chat-1")
        let sent = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(sent.map { $0["content"] }, ["m3", "m4", "m5", "m6", "m7", "m8"])
        XCTAssertEqual(sent.map { $0["role"] }, ["user", "assistant", "user", "assistant", "user", "assistant"])
    }

    func testAnAdminWhoSwitchedItOffMeansNoSuggestionsNotAnError() async throws {
        StubTransport.route(taskPath, Reply.json(#"{"detail":"Follow-up generation is disabled"}"#))
        let list = try await client().generateFollowUps(
            model: "m", messages: [OWChatMessageInput(role: "user", text: "oi")], chatID: nil)
        XCTAssertEqual(list, [])
        XCTAssertNil(StubTransport.sentJSON(taskPath)?["chat_id"], "an unsaved chat sends no id")
    }

    // MARK: - On the message

    /// The web writes them on the reply node as `followUps`; a chat it answered
    /// shows the same questions when the app opens it.
    func testAReplyCarriesTheQuestionsTheWebSavedOnIt() throws {
        let node = #"{"id":"a1","role":"assistant","content":"Resposta","followUps":["Por quê?","",3,"E depois?"]}"#
        let m = try JSONDecoder().decode(OWMessage.self, from: Data(node.utf8))
        XCTAssertEqual(m.followUps, ["Por quê?", "E depois?"])

        let plain = try JSONDecoder().decode(OWMessage.self, from: Data(#"{"id":"a2","role":"assistant","content":"x"}"#.utf8))
        XCTAssertEqual(plain.followUps, [])
    }

    /// The offline cache encodes `OWMessage`; without this the questions would
    /// vanish from a chat read back from the device.
    func testTheOfflineCopyKeepsThem() throws {
        var m = OWMessage(id: "a1", role: .assistant, content: "Resposta")
        m.followUps = ["Por quê?", "E depois?"]
        let back = try JSONDecoder().decode(OWMessage.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back.followUps, ["Por quê?", "E depois?"])
    }

    // MARK: - Saving them where the web reads them

    private static let chatPath = "/api/v1/chats/chat-1"

    /// A reply the web would have written: fields this client does not model
    /// (`output`, `usage`) ride on the node and must come back untouched.
    private static func chatJSON(replyDone: Bool = true) -> String {
        """
        {"id":"chat-1","title":"Conversa","chat":{
          "title":"Conversa","models":["m"],"params":{},"tags":[],"timestamp":1000,
          "history":{"messages":{
            "u1":{"id":"u1","role":"user","content":"oi","timestamp":1,"parentId":null,"childrenIds":["a1"]},
            "a1":{"id":"a1","role":"assistant","content":"olá","timestamp":2,"parentId":"u1",
                  "childrenIds":[],"done":\(replyDone),"usage":{"total_tokens":42},
                  "output":[{"type":"message","content":[{"type":"output_text","text":"olá"}]}]}},
           "currentId":"a1"},
          "messages":[{"id":"u1","role":"user","content":"oi","timestamp":1},
                      {"id":"a1","role":"assistant","content":"olá","timestamp":2}]}}
        """
    }

    private func savingClient(version: String, replyDone: Bool = true) -> OpenWebUIClient {
        StubTransport.route("/api/config", .json(#"{"version":"\#(version)"}"#))
        StubTransport.route(Self.chatPath, .json(Self.chatJSON(replyDone: replyDone)))
        return client()
    }

    private func posted() throws -> [String: Any] {
        try XCTUnwrap(StubTransport.sentJSON(Self.chatPath)?["chat"] as? [String: Any])
    }

    /// The server merges `history.messages` id by id but REPLACES each node
    /// (`{**existing, **incoming}`), so `{"followUps": […]}` alone would wipe the
    /// reply. The node goes back whole — the server's own copy, plus the list —
    /// and nothing else: no title, no flat list, no `currentId`.
    func testOn011OnlyTheReplyNodeIsWrittenAndItKeepsEverythingTheServerHad() async throws {
        let c = savingClient(version: "0.11.4")

        try await c.saveFollowUps(["Por quê?", "E depois?"], replyID: "a1", chatID: "chat-1")

        let chat = try posted()
        XCTAssertEqual(Set(chat.keys), ["history"])
        let history = try XCTUnwrap(chat["history"] as? [String: Any])
        XCTAssertEqual(Set(history.keys), ["messages"], "the server keeps its own currentId")
        let nodes = try XCTUnwrap(history["messages"] as? [String: [String: Any]])
        XCTAssertEqual(Set(nodes.keys), ["a1"])
        let a1 = try XCTUnwrap(nodes["a1"])
        XCTAssertEqual(a1["followUps"] as? [String], ["Por quê?", "E depois?"])
        XCTAssertEqual(a1["content"] as? String, "olá")
        XCTAssertEqual(a1["parentId"] as? String, "u1")
        XCTAssertEqual((a1["usage"] as? [String: Int])?["total_tokens"], 42)
        XCTAssertNotNil(a1["output"], "web-only fields survive")
    }

    /// An older server replaces the blob: the whole chat goes back, with the
    /// list on the node in the graph and on its copy in the flat list.
    func testOn010TheWholeChatGoesBackWithTheListOnBothCopiesOfTheReply() async throws {
        let c = savingClient(version: "0.10.6")

        try await c.saveFollowUps(["Por quê?"], replyID: "a1", chatID: "chat-1")

        let chat = try posted()
        XCTAssertEqual(chat["title"] as? String, "Conversa")
        let history = try XCTUnwrap(chat["history"] as? [String: Any])
        XCTAssertEqual(history["currentId"] as? String, "a1")
        let nodes = try XCTUnwrap(history["messages"] as? [String: [String: Any]])
        XCTAssertEqual(Set(nodes.keys), ["u1", "a1"])
        XCTAssertEqual(nodes["a1"]?["followUps"] as? [String], ["Por quê?"])
        XCTAssertNotNil(nodes["a1"]?["output"])
        let flat = try XCTUnwrap(chat["messages"] as? [[String: Any]])
        XCTAssertEqual(flat.map { $0["followUps"] as? [String] }, [nil, ["Por quê?"]])
    }

    /// A reply someone else is still streaming is theirs: writing back the
    /// overlaid partial copy would pin the truncated text (see ChatWriteBodyTests).
    func testAReplyStillBeingWrittenElsewhereIsLeftAlone() async throws {
        let c = savingClient(version: "0.11.4", replyDone: false)
        try await c.saveFollowUps(["Por quê?"], replyID: "a1", chatID: "chat-1")
        XCTAssertNil(StubTransport.sentJSON(Self.chatPath), "nothing posted")
    }

    func testAReplyTheServerDoesNotKnowIsNotInvented() async throws {
        let c = savingClient(version: "0.11.4")
        try await c.saveFollowUps(["Por quê?"], replyID: "a9", chatID: "chat-1")
        XCTAssertNil(StubTransport.sentJSON(Self.chatPath))
    }
}

private typealias Reply = StubTransport.Reply
