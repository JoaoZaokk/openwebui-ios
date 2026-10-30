import XCTest
import OpenWebUIKit
@testable import OpenWebUI

/// Report from 1.10 (zh_CN): on the web a long conversation could be compressed
/// and carried on; in the app it only ended in an error. The provider's
/// "context too long" is now named for what it is, and the app can summarize
/// the earlier turns and send the summary in their place — the screen keeps
/// the whole conversation, only what goes to the model is shorter.
@MainActor
final class ContextOverflowTests: XCTestCase {

    private static let completions = "/api/chat/completions"
    private let store = OWKeychainStore(service: "tests.overflow")

    override func setUp() {
        super.setUp()
        StubTransport.reset(); store.clear()
        UserDefaults.standard.set(false, forKey: ChatViewModel.followUpsKey)
    }
    override func tearDown() {
        StubTransport.reset(); store.clear()
        UserDefaults.standard.removeObject(forKey: ChatViewModel.followUpsKey)
        super.tearDown()
    }

    private func viewModel() -> ChatViewModel {
        store.save(token: "t")
        let client = OpenWebUIClient(config: OWConfig(baseURL: URL(string: "https://overflow.test")!),
                                     tokens: store, protocolClasses: [StubTransport.self])
        let vm = ChatViewModel(client: client, completions: ChatCompletionsClient(client: client),
                               chat: nil, models: [OWModel(id: "m", name: "m")], defaultModel: "m",
                               temporary: true)
        vm.serverSearches = { false }
        return vm
    }

    private func say(_ text: String) -> StubTransport.Reply {
        .sse([#"{"choices":[{"delta":{"content":"\#(text)"}}]}"#, "[DONE]"])
    }
    private let overflow = StubTransport.Reply.sse([
        #"{"error":{"message":"This model's maximum context length is 8192 tokens. However, your messages resulted in 9120 tokens."}}"#,
    ])

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { try? await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertTrue(cond(), "timed out waiting for: \(what)")
    }

    private func sent(_ n: Int) -> [[String: Any]] {
        let bodies = StubTransport.allBodies[Self.completions] ?? []
        guard n < bodies.count,
              let j = try? JSONSerialization.jsonObject(with: bodies[n]) as? [String: Any] else { return [] }
        return j["messages"] as? [[String: Any]] ?? []
    }
    private func text(_ m: [String: Any]) -> String {
        if let s = m["content"] as? String { return s }
        return (m["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
    }

    private func ask(_ vm: ChatViewModel, _ q: String) async {
        vm.input = q
        vm.send()
        await waitUntil("the reply to \(q)") { !vm.isStreaming }
    }

    func testAContextOverflowIsNamedAndOffersTheSummary() async {
        StubTransport.routeSequence(Self.completions, [say("Olá."), overflow])
        let vm = viewModel()
        await ask(vm, "Oi")
        await ask(vm, "E agora?")
        XCTAssertTrue(vm.contextOverflow)
        XCTAssertEqual(vm.messages.last?.content,
                       "⚠️ " + L("Esta conversa passou do limite de contexto do modelo. Resuma a conversa para continuar."))
    }

    /// The two ways real providers said it, through the owner's server on
    /// 2026-10-28 with ~1.15M tokens.
    func testWhatRealProvidersSendIsRecognised() async {
        let glm = StubTransport.Reply.json(#"{"error":{"code":"1261","message":"Prompt exceeds max length"}}"#, status: 400)
        let mimo = StubTransport.Reply.sse([
            #"{"choices":[{"delta":{"content":"","role":"assistant","tool_calls":null,"reasoning_content":null},"finish_reason":null,"index":0}],"model":"mimo-v2.6-flash"}"#,
            #"{"choices":[{"delta":{"content":null,"role":null,"tool_calls":null,"reasoning_content":null},"finish_reason":"length","index":0}],"model":"mimo-v2.6-flash"}"#,
            "[DONE]",
        ])
        for (name, reply) in [("glm", glm), ("mimo", mimo)] {
            StubTransport.reset()
            StubTransport.routeSequence(Self.completions, [say("Olá."), reply])
            let vm = viewModel()
            await ask(vm, "Oi")
            await ask(vm, "E agora?")
            XCTAssertTrue(vm.contextOverflow, name)
            XCTAssertEqual(vm.messages.last?.content,
                           "⚠️ " + L("Esta conversa passou do limite de contexto do modelo. Resuma a conversa para continuar."), name)
        }
    }

    func testAFirstMessagePastTheContextHasNothingToSummarize() async {
        StubTransport.routeSequence(Self.completions, [overflow])
        let vm = viewModel()
        await ask(vm, "Um texto colado enorme")
        XCTAssertFalse(vm.contextOverflow)
        XCTAssertEqual(vm.messages.last?.content,
                       "⚠️ " + L("Esta conversa passou do limite de contexto do modelo. Resuma a conversa para continuar."))
    }

    func testAnOrdinaryErrorDoesNotOfferTheSummary() async {
        StubTransport.routeSequence(Self.completions, [.sse([#"{"error":{"message":"upstream timeout"}}"#])])
        let vm = viewModel()
        await ask(vm, "Oi")
        XCTAssertFalse(vm.contextOverflow)
    }

    func testTheSummaryStandsInForTheEarlierTurnsAndTheQuestionIsAskedAgain() async {
        StubTransport.routeSequence(Self.completions, [
            say("Resposta um."), overflow, say("RESUMO-DA-CONVERSA"), say("Resposta dois."),
        ])
        let vm = viewModel()
        await ask(vm, "Pergunta um")
        await ask(vm, "Pergunta dois")
        XCTAssertTrue(vm.contextOverflow)

        await vm.summarizeAndRetry()
        await waitUntil("the retried reply") { vm.messages.last?.content == "Resposta dois." }

        // The summary request carried the earlier turns.
        let summaryAsk = sent(2).map(text).joined(separator: "\n")
        XCTAssertTrue(summaryAsk.contains("Pergunta um") && summaryAsk.contains("Resposta um."), summaryAsk)
        // The retry carries the summary in place of them, alternation kept.
        let retry = sent(3)
        XCTAssertEqual(retry.count, 1, "\(retry)")
        XCTAssertEqual(retry.first?["role"] as? String, "user")
        let q = retry.first.map(text) ?? ""
        XCTAssertTrue(q.contains("RESUMO-DA-CONVERSA") && q.contains("Pergunta dois"), q)
        XCTAssertFalse(q.contains("Resposta um."), q)
        // The screen still has the whole conversation, and nothing is offered again.
        XCTAssertEqual(vm.messages.map(\.content), ["Pergunta um", "Resposta um.", "Pergunta dois", "Resposta dois."])
        XCTAssertFalse(vm.contextOverflow)
    }

    func testTurnsAfterTheSummaryGoInFull() async {
        StubTransport.routeSequence(Self.completions, [
            say("Resposta um."), overflow, say("RESUMO-DA-CONVERSA"), say("Resposta dois."), say("Resposta três."),
        ])
        let vm = viewModel()
        await ask(vm, "Pergunta um")
        await ask(vm, "Pergunta dois")
        await vm.summarizeAndRetry()
        await waitUntil("the retried reply") { vm.messages.last?.content == "Resposta dois." }
        await ask(vm, "Pergunta três")

        let next = sent(4)
        XCTAssertEqual(next.map { $0["role"] as? String }, ["user", "assistant", "user"])
        XCTAssertTrue(text(next[0]).contains("RESUMO-DA-CONVERSA"))
        XCTAssertEqual(text(next[1]), "Resposta dois.")
        XCTAssertEqual(text(next[2]), "Pergunta três")
    }

    func testALongHistoryIsSummarizedInPiecesThatFit() {
        let turns = (0..<40).map { OWChatMessageInput(role: $0.isMultiple(of: 2) ? "user" : "assistant",
                                                      text: String(repeating: "x", count: 3_000)) }
        let pieces = ChatViewModel.summaryPieces(turns)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= ChatViewModel.summaryPieceLimit }, "\(pieces.map(\.count))")
        XCTAssertEqual(pieces.joined().filter { $0 == "x" }.count, 40 * 3_000, "nothing dropped")
    }
}
