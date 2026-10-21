import XCTest
import OpenWebUIKit
@testable import OpenWebUI

/// App Store review on 1.10, "Replies don't come through": send a message,
/// switch apps or lock the phone, and the reply is replaced with "⚠️ The
/// connection dropped partway through." and never saved — although the server
/// finished it. iOS suspends the app about 30 s after it leaves, the stream
/// dies with it, and the app (which saves the conversation itself) had nothing
/// to save but the error.
///
/// A reply cut off that way is now asked again, once, when the app is back.
@MainActor
final class ReplyCutOffInBackgroundTests: XCTestCase {

    private static let completions = "/api/chat/completions"
    private let store = OWKeychainStore(service: "tests.cutoff")

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
        let client = OpenWebUIClient(config: OWConfig(baseURL: URL(string: "https://cutoff.test")!),
                                     tokens: store, protocolClasses: [StubTransport.self])
        let vm = ChatViewModel(client: client, completions: ChatCompletionsClient(client: client),
                               chat: nil, models: [OWModel(id: "m", name: "m")], defaultModel: "m",
                               temporary: true)
        vm.serverSearches = { false }
        return vm
    }

    private func dropped(after frames: [String] = [], in seconds: TimeInterval) -> StubTransport.Reply {
        var r = StubTransport.Reply.failing(.networkConnectionLost)
        r.body = Data(frames.map { "data: \($0)\n\n" }.joined().utf8)
        r.headers = ["Content-Type": "text/event-stream"]
        r.delay = seconds
        return r
    }

    private let answer = StubTransport.Reply.sse([#"{"choices":[{"delta":{"content":"Resposta inteira."}}]}"#, "[DONE]"])

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { try? await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertTrue(cond(), "timed out waiting for: \(what)")
    }

    private var sent: Int { StubTransport.allBodies[Self.completions]?.count ?? 0 }

    func testAReplyCutOffWhileAwayIsAskedAgainWhenTheAppIsBack() async {
        StubTransport.routeSequence(Self.completions, [dropped(in: 0.3), answer])
        let vm = viewModel()
        vm.input = "Oi"
        vm.send()
        vm.appWentToBackground()
        await waitUntil("the cut-off stream to end") { !vm.isStreaming }

        XCTAssertEqual(vm.messages.last?.content, "", "no error stamped over the reply while away")
        XCTAssertNil(vm.error)
        XCTAssertEqual(sent, 1, "not asked again while still in the background")

        vm.appBecameActive()
        await waitUntil("the reply asked again") { vm.messages.last?.content == "Resposta inteira." }
        XCTAssertEqual(sent, 2)
        XCTAssertEqual(vm.messages.count, 2, "the same reply, not a new branch")
    }

    func testWhenTheCutArrivesAfterComingBackItIsAskedAgainAtOnce() async {
        StubTransport.routeSequence(Self.completions, [dropped(in: 0.5), answer])
        let vm = viewModel()
        vm.input = "Oi"
        vm.send()
        vm.appWentToBackground()
        vm.appBecameActive()
        await waitUntil("the reply asked again") { vm.messages.last?.content == "Resposta inteira." }
        XCTAssertEqual(sent, 2)
    }

    func testHalfAReplyIsReplacedByTheWholeOne() async {
        StubTransport.routeSequence(Self.completions, [
            dropped(after: [#"{"choices":[{"delta":{"content":"Metade da "}}]}"#], in: 0.3), answer,
        ])
        let vm = viewModel()
        vm.input = "Oi"
        vm.send()
        vm.appWentToBackground()
        await waitUntil("the cut-off stream to end") { !vm.isStreaming }
        vm.appBecameActive()
        await waitUntil("the whole reply") { vm.messages.last?.content == "Resposta inteira." }
    }

    func testADropWithTheAppOnScreenIsStillReported() async {
        StubTransport.routeSequence(Self.completions, [dropped(in: 0.1), answer])
        let vm = viewModel()
        vm.input = "Oi"
        vm.send()
        await waitUntil("the failure") { !vm.isStreaming }
        XCTAssertEqual(vm.messages.last?.content, "⚠️ " + L("A conexão caiu no meio do caminho."))
        XCTAssertEqual(sent, 1, "a drop the user watched is not retried behind their back")
    }

    func testItIsAskedAgainOnlyOnce() async {
        StubTransport.routeSequence(Self.completions, [dropped(in: 0.3), dropped(in: 0.3)])
        let vm = viewModel()
        vm.input = "Oi"
        vm.send()
        vm.appWentToBackground()
        await waitUntil("the cut-off stream to end") { !vm.isStreaming }
        vm.appBecameActive()
        // The second attempt is on screen; its drop is the real answer.
        await waitUntil("the second failure") {
            !vm.isStreaming && sent == 2 && vm.messages.last?.content.isEmpty == false
        }
        XCTAssertEqual(vm.messages.last?.content, "⚠️ " + L("A conexão caiu no meio do caminho."))
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(sent, 2)
    }
}
