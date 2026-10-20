import XCTest
@testable import OpenWebUIKit

/// Open WebUI runs tool calls only for requests from a browser tab
/// (`session_id`); for the app's requests it passes the provider's reply
/// through untouched. `streamReply` is what makes a model's search request
/// actually search: it offers the tool, runs the search through the server's
/// engine and asks again with the results attached.
final class WebSearchReplyTests: XCTestCase {

    private let store = OWKeychainStore(service: "tests.websearchreply")
    private static let completions = "/api/chat/completions"
    private static let search = "/api/v1/retrieval/process/web/search"

    override func setUp() {
        super.setUp(); StubTransport.reset(); store.clear()
        ChatCompletionsClient.rememberToolsRefused(by: "m", false)
    }
    override func tearDown() { StubTransport.reset(); store.clear(); super.tearDown() }

    private func completionsClient() -> ChatCompletionsClient {
        store.save(token: "t")
        let c = OpenWebUIClient(config: OWConfig(baseURL: URL(string: "https://search.test")!),
                                tokens: store, protocolClasses: [StubTransport.self])
        return ChatCompletionsClient(client: c)
    }

    private struct Seen { var text = ""; var searching: [[String]] = []; var sources = 0; var failed = 0; var errors: [String] = []; var done = false }

    private func run(_ search: OWReplySearch, question: String = "Qual foi o último jogo do Flamengo?") async throws -> Seen {
        var seen = Seen()
        let msgs = [OWChatMessageInput(role: "system", text: "Seja breve."),
                    OWChatMessageInput(role: "user", text: question)]
        for try await u in completionsClient().streamReply(model: "m", messages: msgs, search: search) {
            switch u {
            case .textDelta(let t): seen.text += t
            case .searching(let q): seen.searching.append(q)
            case .sources(let s): seen.sources += s.count
            case .searchFailed: seen.failed += 1
            case .error(let e): seen.errors.append(e)
            case .done: seen.done = true
            case .toolCall: XCTFail("a tool call must never reach the caller")
            case .reasoningDelta: break
            }
        }
        return seen
    }

    private func body(_ i: Int) throws -> [String: Any] {
        let bodies = try XCTUnwrap(StubTransport.allBodies[Self.completions])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bodies[i]) as? [String: Any])
    }

    private let searchOK = #"{"status":true,"collection_names":["web-search-abc"],"filenames":["https://ge.globo.com/x","https://espn.com/y"]}"#

    /// Frames as mimo-v2.5 sent them through a real Open WebUI 0.12.2 on 2026-10-20.
    private let mimoCall = [
        #"{"choices":[{"delta":{"content":"","role":"assistant","tool_calls":null,"reasoning_content":null},"finish_reason":null,"index":0}]}"#,
        #"{"choices":[{"delta":{"content":null,"role":null,"tool_calls":[{"index":0,"id":"call_34b","function":{"arguments":"","name":"search_web"},"type":"function"}],"reasoning_content":null},"finish_reason":null,"index":0}]}"#,
        #"{"choices":[{"delta":{"content":null,"tool_calls":[{"index":0,"id":null,"function":{"arguments":"{\"query\": ","name":null},"type":"function"}]},"finish_reason":null,"index":0}]}"#,
        #"{"choices":[{"delta":{"content":null,"tool_calls":[{"index":0,"id":null,"function":{"arguments":"\"último jogo","name":null},"type":"function"}]},"finish_reason":null,"index":0}]}"#,
        #"{"choices":[{"delta":{"content":null,"tool_calls":[{"index":0,"id":null,"function":{"arguments":" do Flamengo resultado\"","name":null},"type":"function"}]},"finish_reason":null,"index":0}]}"#,
        #"{"choices":[{"delta":{"content":null,"tool_calls":[{"index":0,"id":null,"function":{"arguments":"}","name":null},"type":"function"}]},"finish_reason":null,"index":0}]}"#,
        #"{"choices":[{"delta":{"content":null},"finish_reason":"tool_calls","index":0}]}"#,
        "[DONE]",
    ]

    private let answer = Reply.sse([#"{"choices":[{"delta":{"content":"Ganhou de 2 a 1."}}]}"#, "[DONE]"])
    private typealias Reply = StubTransport.Reply

    func testAStructuredCallSearchesAndAsksAgainWithTheResults() async throws {
        StubTransport.routeSequence(Self.completions, [.sse(mimoCall), answer])
        StubTransport.route(Self.search, .json(searchOK))
        let seen = try await run(OWReplySearch(offer: true, mayRun: true))

        XCTAssertEqual(seen.text, "Ganhou de 2 a 1.")
        XCTAssertEqual(seen.searching, [["último jogo do Flamengo resultado"]])
        XCTAssertEqual(seen.sources, 2)
        XCTAssertTrue(seen.done)
        let sent = try XCTUnwrap(StubTransport.sentJSON(Self.search))
        XCTAssertEqual(sent["queries"] as? [String], ["último jogo do Flamengo resultado"])

        let first = try body(0)
        let tools = try XCTUnwrap(first["tools"] as? [[String: Any]])
        XCTAssertEqual((tools.first?["function"] as? [String: Any])?["name"] as? String, "search_web")
        let second = try body(1)
        XCTAssertNil(second["tools"], "the follow-up offers no tool, so it cannot loop")
        let files = try XCTUnwrap(second["files"] as? [[String: Any]])
        XCTAssertEqual(files.first?["type"] as? String, "web_search")
        XCTAssertEqual(files.first?["collection_name"] as? String, "web-search-abc")
    }

    /// Open WebUI 0.12 answers the follow-up with a `sources` frame named after
    /// the query ("cotação do dólar em reai…") and no addresses. It replaced
    /// the sites the search found.
    func testTheServersQueryNamedSourcesFrameDoesNotReplaceTheSites() async throws {
        StubTransport.routeSequence(Self.completions, [
            .sse(mimoCall),
            .sse([#"{"sources":[{"source":{"name":"último jogo do Flamengo resultado","type":"web_search"},"document":["x"],"metadata":[{"source":"último jogo do Flamengo resultado"}]}]}"#,
                  #"{"choices":[{"delta":{"content":"Ganhou de 2 a 1."}}]}"#, "[DONE]"]),
        ])
        StubTransport.route(Self.search, .json(searchOK))
        var last: [OWWebSource] = []
        let msgs = [OWChatMessageInput(role: "user", text: "Último jogo do Flamengo?")]
        for try await u in completionsClient().streamReply(model: "m", messages: msgs,
                                                           search: OWReplySearch(offer: true, mayRun: true)) {
            if case .sources(let s) = u { last = s }
        }
        XCTAssertEqual(last.map(\.name), ["ge.globo.com", "espn.com"])
    }

    func testTheGemmaTextCallFromTheReportSearchesInsteadOfBeingShown() async throws {
        StubTransport.routeSequence(Self.completions, [
            .sse([#"{"choices":[{"delta":{"content":"<tool_call>call:search_"}}]}"#,
                  #"{"choices":[{"delta":{"content":"web{queries:[\"Flamengo último jogo\"]}</tool_call>"}}]}"#,
                  "[DONE]"]),
            answer,
        ])
        StubTransport.route(Self.search, .json(searchOK))
        let seen = try await run(OWReplySearch(offer: true, mayRun: true))
        XCTAssertEqual(seen.text, "Ganhou de 2 a 1.")
        XCTAssertEqual(seen.searching, [["Flamengo último jogo"]])
    }

    func testAnUndeclaredCallStillSearchesWhenTheServerAllowsIt() async throws {
        StubTransport.routeSequence(Self.completions, [
            .sse([#"{"choices":[{"delta":{"content":"<|tool_call>call:search_web{query:<|\"|>Flamengo<|\"|>}<tool_call|>"}}]}"#, "[DONE]"]),
            answer,
        ])
        StubTransport.route(Self.search, .json(searchOK))
        let seen = try await run(OWReplySearch(offer: false, mayRun: true))
        XCTAssertEqual(seen.text, "Ganhou de 2 a 1.")
        XCTAssertNil(try body(0)["tools"])
        XCTAssertEqual(seen.searching, [["Flamengo"]])
    }

    func testWithSearchOffTheCallIsCutAndTheModelAnswersFromMemory() async throws {
        StubTransport.routeSequence(Self.completions, [
            .sse([#"{"choices":[{"delta":{"content":"<tool_call>call:search_web{query:\"x\"}</tool_call>"}}]}"#, "[DONE]"]),
            .sse([#"{"choices":[{"delta":{"content":"Pelo que sei, ganhou."}}]}"#, "[DONE]"]),
        ])
        let seen = try await run(.off)
        XCTAssertEqual(seen.text, "Pelo que sei, ganhou.")
        XCTAssertTrue(seen.searching.isEmpty)
        XCTAssertFalse(StubTransport.requested(Self.search))
        let msgs = try XCTUnwrap(try body(1)["messages"] as? [[String: Any]])
        XCTAssertTrue((msgs.last?["content"] as? String ?? "").contains("Web search is not available"))
    }

    func testAFailedSearchIsReportedAndTheReplyStillComes() async throws {
        StubTransport.routeSequence(Self.completions, [.sse(mimoCall), answer])
        StubTransport.route(Self.search, .json(#"{"detail":"No search engine configured"}"#, status: 400))
        let seen = try await run(OWReplySearch(offer: true, mayRun: true))
        XCTAssertEqual(seen.failed, 1)
        XCTAssertEqual(seen.text, "Ganhou de 2 a 1.")
        let msgs = try XCTUnwrap(try body(1)["messages"] as? [[String: Any]])
        XCTAssertTrue((msgs.last?["content"] as? String ?? "").contains("web search you asked for failed"))
    }

    func testAProviderThatRejectsToolsIsAskedAgainWithoutThem() async throws {
        StubTransport.routeSequence(Self.completions, [
            .json(#"{"detail":"registry.ollama.ai/library/gemma3:27b does not support tools"}"#, status: 400),
            .sse([#"{"choices":[{"delta":{"content":"Oi!"}}]}"#, "[DONE]"]),
            .sse([#"{"choices":[{"delta":{"content":"Oi de novo!"}}]}"#, "[DONE]"]),
        ])
        let seen = try await run(OWReplySearch(offer: true, mayRun: true), question: "Oi")
        XCTAssertEqual(seen.text, "Oi!")
        XCTAssertNotNil(try body(0)["tools"])
        XCTAssertNil(try body(1)["tools"])
        // Next turn: not offered again.
        let next = try await run(OWReplySearch(offer: true, mayRun: true), question: "Oi")
        XCTAssertEqual(next.text, "Oi de novo!")
        XCTAssertNil(try body(2)["tools"])
    }

    func testAnOrdinaryAnswerWithTheToolOfferedIsJustTheAnswer() async throws {
        StubTransport.routeSequence(Self.completions, [
            .sse([#"{"choices":[{"delta":{"content":"Tudo bem, e você?"}}]}"#, "[DONE]"]),
        ])
        let seen = try await run(OWReplySearch(offer: true, mayRun: true), question: "Oi, tudo bem?")
        XCTAssertEqual(seen.text, "Tudo bem, e você?")
        XCTAssertTrue(seen.searching.isEmpty)
        XCTAssertEqual(StubTransport.allBodies[Self.completions]?.count, 1)
        XCTAssertTrue(seen.done)
    }

    func testWordsBeforeTheCallAreKeptAndTheAnswerFollowsAfterAGap() async throws {
        StubTransport.routeSequence(Self.completions, [
            .sse([#"{"choices":[{"delta":{"content":"Vou ver. "}}]}"#,
                  #"{"choices":[{"delta":{"content":"<tool_call>{\"name\":\"search_web\",\"arguments\":{\"query\":\"q\"}}</tool_call>"}}]}"#,
                  "[DONE]"]),
            answer,
        ])
        StubTransport.route(Self.search, .json(searchOK))
        let seen = try await run(OWReplySearch(offer: true, mayRun: true))
        XCTAssertEqual(seen.text, "Vou ver. \n\nGanhou de 2 a 1.")
    }

    func testAStreamThatIsDownIsNotMistakenForARefusalOfTools() async throws {
        StubTransport.routeSequence(Self.completions, [
            .json(#"{"detail":"Model not found"}"#, status: 404),
            .json(#"{"detail":"Model not found"}"#, status: 404),
        ])
        do {
            _ = try await run(OWReplySearch(offer: true, mayRun: true))
            XCTFail("expected the error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Model not found")
        }
        XCTAssertFalse(ChatCompletionsClient.toolsRefused(by: "m"))
    }
}
