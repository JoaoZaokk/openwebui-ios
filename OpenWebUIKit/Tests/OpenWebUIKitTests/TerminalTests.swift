import XCTest
@testable import OpenWebUIKit

/// Open Terminal through the server's proxy: the functions offered from its
/// real `openapi.json` (open-terminal 0.17.22), each call routed the way Open
/// WebUI routes it, and the reply loop that runs them — asking the user before
/// anything that changes the terminal, answering with `tool` turns.
final class TerminalTests: XCTestCase {

    private let store = OWKeychainStore(service: "tests.terminal")
    private static let completions = "/api/chat/completions"
    private static let box = "/api/v1/terminals/box"

    override func setUp() {
        super.setUp(); StubTransport.reset(); store.clear()
        ChatCompletionsClient.rememberToolsRefused(by: "m", false)
    }
    override func tearDown() { StubTransport.reset(); store.clear(); super.tearDown() }

    private func owClient() -> OpenWebUIClient {
        store.save(token: "t")
        return OpenWebUIClient(config: OWConfig(baseURL: URL(string: "https://term.test")!),
                               tokens: store, protocolClasses: [StubTransport.self])
    }

    private static let openapi: Data = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/open-terminal-openapi.json")
        return (try? Data(contentsOf: url)) ?? Data()
    }()

    private func spec(_ tool: OWTerminalTool) throws -> [String: Any] {
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: tool.spec) as? [String: Any])
        return try XCTUnwrap(obj["function"] as? [String: Any])
    }

    private func props(_ tool: OWTerminalTool) throws -> [String: [String: Any]] {
        let params = try XCTUnwrap(try spec(tool)["parameters"] as? [String: Any])
        return try XCTUnwrap(params["properties"] as? [String: [String: Any]])
    }

    // MARK: Functions from openapi.json

    func testTheRealSpecGivesTheTerminalFunctions() throws {
        XCTAssertGreaterThan(Self.openapi.count, 1000, "fixture missing")
        let tools = OWTerminalOpenAPI.tools(from: Self.openapi, cwd: "/home/user/proj")
        let names = Set(tools.map(\.name))
        for n in ["run_command", "get_process_status", "kill_process", "read_file", "write_file",
                  "replace_file_content", "list_files", "display_file", "grep_search"] {
            XCTAssertTrue(names.contains(n), n)
        }
        // Only while a shell is open (filter_user_terminal_tools).
        XCTAssertFalse(names.contains("read_user_terminal"))
        XCTAssertFalse(names.contains("send_user_terminal_input"))
        let withShell = Set(OWTerminalOpenAPI.tools(from: Self.openapi, userShellOpen: true).map(\.name))
        XCTAssertTrue(withShell.contains("read_user_terminal"))
        XCTAssertTrue(withShell.contains("send_user_terminal_input"))

        let run = try XCTUnwrap(tools.first { $0.name == "run_command" })
        XCTAssertEqual(run.method, "POST")
        XCTAssertEqual(run.path, "/execute")
        XCTAssertEqual(Set(run.queryParams), ["wait", "tail"])
        let p = try props(run)
        // Body via $ref, query optional via anyOf[…, null].
        XCTAssertEqual(p["command"]?["type"] as? String, "string")
        XCTAssertEqual(p["wait"]?["type"] as? String, "number")
        XCTAssertEqual(p["tail"]?["type"] as? String, "integer")
        let required = try XCTUnwrap((try spec(run)["parameters"] as? [String: Any])?["required"] as? [String])
        XCTAssertEqual(required, ["command"])
        XCTAssertTrue((try spec(run)["description"] as? String ?? "").hasSuffix("The current working directory is: /home/user/proj"))
        XCTAssertFalse(run.readOnly)

        let status = try XCTUnwrap(tools.first { $0.name == "get_process_status" })
        XCTAssertEqual(status.pathParams, ["process_id"])
        XCTAssertTrue(status.readOnly)

        let display = try XCTUnwrap(tools.first { $0.name == "display_file" })
        XCTAssertEqual(try props(display)["page"]?["type"] as? String, "integer")
        XCTAssertEqual(try props(display)["inline"]?["type"] as? String, "boolean")

        // Arrays keep their items (OpenAI refuses an array without them).
        for t in tools {
            for (name, prop) in try props(t) where (prop["type"] as? String) == "array" {
                XCTAssertNotNil(prop["items"], "\(t.name).\(name)")
            }
            XCTAssertFalse(String(data: t.spec, encoding: .utf8)!.contains("\"$ref\""), t.name)
        }
    }

    func testTheServerListDecodesTheChatScopes() async throws {
        let json = #"""
        [{"id":"box","url":"","name":"Linux box","contexts":{},"config":{"chat_uploads":true}},
         {"id":"per","name":"","contexts":{"chat":{"context_id":"chat_id"}}},
         {"id":"off","name":"Auto","contexts":{"chat":false}}]
        """#
        StubTransport.route("/api/v1/terminals", .json(json))
        let list = try await owClient().terminalServers()
        XCTAssertEqual(list.map(\.id), ["box", "per", "off"])
        XCTAssertEqual(list[0].name, "Linux box")
        XCTAssertEqual(list[0].chatScope, .shared)
        XCTAssertEqual(list[1].name, "per", "an empty name falls back to the id")
        XCTAssertTrue(list[1].needsSavedChat)
        XCTAssertFalse(list[2].usableInChats)
    }

    // MARK: Routing

    func testACallGoesThroughTheProxyWithItsPartsInTheRightPlaces() async throws {
        let tools = OWTerminalOpenAPI.tools(from: Self.openapi)
        let ctx = OWTerminalContext(terminal: .init(id: "box", name: "Box"), session: "chat-1", tools: tools)
        StubTransport.route(Self.box + "/execute", .json(#"{"id":"p1","command":"ls","status":"done","exit_code":0,"output":[{"type":"stdout","data":"a\nb\n"}],"next_offset":1,"truncated":false}"#))
        let run = try XCTUnwrap(tools.first { $0.name == "run_command" })
        _ = try await owClient().sendTerminalTool(run, ["command": "ls -la", "wait": 5, "tail": ""], context: ctx)

        let query = try XCTUnwrap(StubTransport.seenQueries[Self.box + "/execute"]?.last)
        XCTAssertEqual(query, "wait=5", "an empty optional query parameter is left out")
        let body = try XCTUnwrap(StubTransport.sentJSON(Self.box + "/execute"))
        XCTAssertEqual(body["command"] as? String, "ls -la")
        XCTAssertNil(body["wait"], "query parameters stay out of the body")
        XCTAssertEqual(StubTransport.sentHeaders[Self.box + "/execute"]?["X-Session-Id"], "chat-1")
        XCTAssertEqual(StubTransport.sentHeaders[Self.box + "/execute"]?["Authorization"], "Bearer t")

        let kill = try XCTUnwrap(tools.first { $0.name == "kill_process" })
        // The id is one path segment, whatever it holds.
        var sentURL = ""
        StubTransport.onRequest = { if $0.httpMethod == "DELETE" { sentURL = $0.url?.absoluteString ?? "" } }
        StubTransport.route(Self.box + "/execute/p/1", .json(#"{"status":"killed"}"#))
        _ = try await owClient().sendTerminalTool(kill, ["process_id": "p/1"], context: ctx)
        XCTAssertTrue(sentURL.hasSuffix("/api/v1/terminals/box/execute/p%2F1"), sentURL)
    }

    func testTheTerminalsOwnKeyRefusalDoesNotSignTheUserOut() async throws {
        StubTransport.route(Self.box + "/files/cwd", .json(#"{"detail":"Invalid API key"}"#, status: 401))
        let c = owClient()
        do {
            _ = try await c.terminalPlace("box", session: nil)
            XCTFail("should throw")
        } catch OWError.http(let code, _) {
            XCTAssertEqual(code, 502)
        }
        XCTAssertTrue(c.isAuthenticated, "the session is not the problem")
    }

    // MARK: Messages

    func testToolTurnsAreWrittenTheOpenAIWay() throws {
        let call = OWToolCall(name: "run_command", arguments: #"{"command":"ls"}"#, id: "call_1")
        let a = try JSONSerialization.jsonObject(with: JSONEncoder().encode(OWChatMessageInput.assistant("", calling: [call]))) as? [String: Any]
        let calls = try XCTUnwrap(a?["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls.first?["id"] as? String, "call_1")
        XCTAssertEqual(calls.first?["type"] as? String, "function")
        XCTAssertEqual((calls.first?["function"] as? [String: Any])?["name"] as? String, "run_command")
        let t = try JSONSerialization.jsonObject(with: JSONEncoder().encode(OWChatMessageInput.tool("{}", answering: "call_1"))) as? [String: Any]
        XCTAssertEqual(t?["role"] as? String, "tool")
        XCTAssertEqual(t?["tool_call_id"] as? String, "call_1")
        XCTAssertEqual(t?["content"] as? String, "{}")
    }

    func testTheTerminalPromptAndAgentsMDGoWhereTheServerPutsThem() {
        let ctx = OWTerminalContext(terminal: .init(id: "box", name: "Box"), session: nil, tools: [],
                                    systemPrompt: "You have a terminal.", agentsMD: "# AGENTS.md\n\nUse uv.")
        let out = ctx.applied(to: [OWChatMessageInput(role: "system", text: "Be brief."),
                                   OWChatMessageInput(role: "user", text: "hi")])
        XCTAssertEqual(out.map(\.role), ["system", "user", "user"])
        XCTAssertEqual(out[0].text, "Be brief.\n\nYou have a terminal.")
        XCTAssertEqual(out[1].text, "# AGENTS.md\n\nUse uv.")
        let bare = ctx.applied(to: [OWChatMessageInput(role: "user", text: "hi")])
        XCTAssertEqual(bare.map(\.role), ["system", "user", "user"])
    }

    // MARK: The reply loop

    private func callFrames(_ name: String, _ args: String, id: String?) -> [String] {
        let idPart = id.map { #""id":"\#($0)","# } ?? ""
        let escaped = args.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return [
            #"{"choices":[{"delta":{"content":"","role":"assistant"},"index":0}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,\#(idPart)"type":"function","function":{"name":"\#(name)","arguments":"\#(escaped)"}}]},"index":0}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls","index":0}]}"#,
            "[DONE]",
        ]
    }

    private let answerFrames = [
        #"{"choices":[{"delta":{"content":"Pronto: a, b."},"index":0}]}"#,
        #"{"choices":[{"delta":{},"finish_reason":"stop","index":0}]}"#,
        "[DONE]",
    ]

    private final class Asked: @unchecked Sendable {
        var requests: [OWTerminalApprovalRequest] = []
        let lock = NSLock()
        func add(_ r: OWTerminalApprovalRequest) { lock.lock(); requests.append(r); lock.unlock() }
    }

    private struct Seen { var text = ""; var cards: [OWToolUse] = []; var errors: [String] = [] }

    private func reply(_ answer: OWTerminalApproval, asked: Asked) async throws -> Seen {
        let tools = OWTerminalOpenAPI.tools(from: Self.openapi, cwd: "/home/user")
        let ctx = OWTerminalContext(terminal: .init(id: "box", name: "Box"), session: "chat-1", tools: tools, cwd: "/home/user")
        let term = OWReplyTerminal(context: ctx) { req in asked.add(req); return answer }
        var seen = Seen()
        let msgs = [OWChatMessageInput(role: "user", text: "lista os arquivos")]
        for try await u in ChatCompletionsClient(client: owClient())
            .streamReply(model: "m", messages: msgs, search: .off, terminal: term) {
            switch u {
            case .textDelta(let t): seen.text += t
            case .toolUsed(let c): seen.cards.append(c)
            case .error(let e): seen.errors.append(e)
            case .toolCall: XCTFail("a tool call must never reach the caller")
            default: break
            }
        }
        return seen
    }

    private func body(_ i: Int) throws -> [String: Any] {
        let bodies = try XCTUnwrap(StubTransport.allBodies[Self.completions])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bodies[i]) as? [String: Any])
    }

    func testAnApprovedCommandRunsAndTheModelGetsAToolTurn() async throws {
        StubTransport.routeSequence(Self.completions, [.sse(callFrames("run_command", #"{"command":"ls"}"#, id: "call_9")),
                                                      .sse(answerFrames)])
        StubTransport.route(Self.box + "/execute", .json(#"{"id":"p1","command":"ls","status":"done","exit_code":0,"output":[{"type":"stdout","data":"a\nb\n"}],"next_offset":1,"truncated":false}"#))
        let asked = Asked()
        let seen = try await reply(.allow, asked: asked)

        XCTAssertEqual(seen.text, "Pronto: a, b.")
        XCTAssertEqual(asked.requests.count, 1)
        XCTAssertEqual(asked.requests.first?.summary, "ls")
        XCTAssertEqual(asked.requests.first?.detail, "/home/user")
        XCTAssertFalse(asked.requests.first?.dangerous ?? true)
        let last = try XCTUnwrap(seen.cards.last)
        XCTAssertEqual(last.action, "run_command")
        XCTAssertEqual(last.status, "done")
        XCTAssertEqual(last.exitCode, 0)
        XCTAssertEqual(last.results, "a\nb\n")
        XCTAssertEqual(last.terminalID, "box")
        XCTAssertEqual(seen.cards.map { $0.status ?? "" }, ["approval", "running", "done"])

        let first = try body(0)
        let declared = (first["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertTrue(declared.contains("run_command"))
        XCTAssertNil(first["tool_ids"])
        let second = try body(1)
        let msgs = try XCTUnwrap(second["messages"] as? [[String: Any]])
        XCTAssertEqual(msgs.map { $0["role"] as? String ?? "" }, ["user", "assistant", "tool"])
        XCTAssertEqual((msgs[1]["tool_calls"] as? [[String: Any]])?.first?["id"] as? String, "call_9")
        XCTAssertEqual(msgs[2]["tool_call_id"] as? String, "call_9")
        XCTAssertTrue((msgs[2]["content"] as? String ?? "").contains("a\\nb"))
        XCTAssertNotNil(second["tools"], "the model may run another command")
    }

    func testARefusedCommandNeverReachesTheTerminal() async throws {
        StubTransport.routeSequence(Self.completions, [.sse(callFrames("run_command", #"{"command":"rm -rf ~"}"#, id: "c1")),
                                                      .sse(answerFrames)])
        let asked = Asked()
        let seen = try await reply(.deny, asked: asked)
        XCTAssertTrue(asked.requests.first?.dangerous ?? false)
        XCTAssertFalse(StubTransport.requested(Self.box + "/execute"))
        XCTAssertEqual(seen.cards.last?.status, "denied")
        let msgs = try XCTUnwrap(try body(1)["messages"] as? [[String: Any]])
        XCTAssertTrue((msgs.last?["content"] as? String ?? "").contains("Tool call rejected by user."))
    }

    func testReadingNeedsNoApproval() async throws {
        StubTransport.routeSequence(Self.completions, [.sse(callFrames("list_files", #"{"directory":"/home/user"}"#, id: "c1")),
                                                      .sse(answerFrames)])
        StubTransport.route(Self.box + "/files/list", .json(#"{"dir":"/home/user","entries":[{"name":"a","type":"file"}]}"#))
        let asked = Asked()
        let seen = try await reply(.deny, asked: asked)
        XCTAssertTrue(asked.requests.isEmpty)
        XCTAssertEqual(StubTransport.seenQueries[Self.box + "/files/list"]?.last, "directory=/home/user")
        XCTAssertEqual(seen.cards.last?.status, "done")
    }

    func testACallWrittenAsTextIsAnsweredOnTheUserTurn() async throws {
        // No provider id: there is nothing for a `tool` turn to point at.
        StubTransport.routeSequence(Self.completions, [.sse(callFrames("list_files", #"{"directory":"/tmp"}"#, id: nil)),
                                                      .sse(answerFrames)])
        StubTransport.route(Self.box + "/files/list", .json(#"{"dir":"/tmp","entries":[]}"#))
        _ = try await reply(.allow, asked: Asked())
        let msgs = try XCTUnwrap(try body(1)["messages"] as? [[String: Any]])
        XCTAssertEqual(msgs.map { $0["role"] as? String ?? "" }, ["user"])
        XCTAssertTrue((msgs[0]["content"] as? String ?? "").contains("<terminal_tool_result tool=\"list_files\">"))
    }

    func testALongCommandIsFollowedAndItsOutputGathered() async throws {
        StubTransport.routeSequence(Self.completions, [.sse(callFrames("run_command", #"{"command":"make","wait":120}"#, id: "c1")),
                                                      .sse(answerFrames)])
        StubTransport.route(Self.box + "/execute", .json(#"{"id":"p7","command":"make","status":"running","output":[{"type":"stdout","data":"step 1\n"}],"next_offset":1,"truncated":false}"#))
        StubTransport.route(Self.box + "/execute/p7/status", .json(#"{"id":"p7","status":"done","exit_code":2,"output":[{"type":"stderr","data":"error\n"}],"next_offset":2,"truncated":false}"#))
        let seen = try await reply(.allow, asked: Asked())
        XCTAssertEqual(StubTransport.seenQueries[Self.box + "/execute"]?.last, "wait=25&tail=250", "never a 5-minute request")
        XCTAssertEqual(StubTransport.seenQueries[Self.box + "/execute/p7/status"]?.last, "offset=1&wait=15&tail=250")
        XCTAssertEqual(seen.cards.last?.results, "step 1\nerror\n")
        XCTAssertEqual(seen.cards.last?.exitCode, 2)
    }

    func testOutputForTheModelKeepsTheStartAndTheEnd() {
        let big = String(repeating: "a", count: 10_000) + String(repeating: "z", count: 20_000)
        let out = OWTerminalToolText.forModel(big)
        XCTAssertLessThan(out.count, 16_300)
        XCTAssertTrue(out.hasPrefix("aaaa"))
        XCTAssertTrue(out.hasSuffix("zzzz"))
        XCTAssertLessThanOrEqual(OWTerminalToolText.forCard(big).count, 4_010)
    }
}
