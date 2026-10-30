import XCTest
import OpenWebUIKit
@testable import OpenWebUI

/// A temporary chat is never saved, and the step that copied a finished reply
/// into the message tree lived in the save. The next send rebuilt the screen
/// from the tree, and every earlier answer came back empty.
@MainActor
final class TemporaryChatTests: XCTestCase {

    private static let completions = "/api/chat/completions"
    private let store = OWKeychainStore(service: "tests.temporary")

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

    private func say(_ text: String) -> StubTransport.Reply {
        .sse([#"{"choices":[{"delta":{"content":"\#(text)"}}]}"#, "[DONE]"])
    }

    private func waitUntil(_ what: String, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(5)
        while !cond(), Date() < end { try? await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertTrue(cond(), "timed out waiting for: \(what)")
    }

    func testEarlierAnswersStayAfterTheNextQuestionAndARegenerate() async {
        StubTransport.routeSequence(Self.completions, [say("Um."), say("Dois."), say("Dois de novo.")])
        store.save(token: "t")
        let client = OpenWebUIClient(config: OWConfig(baseURL: URL(string: "https://temporary.test")!),
                                     tokens: store, protocolClasses: [StubTransport.self])
        let vm = ChatViewModel(client: client, completions: ChatCompletionsClient(client: client),
                               chat: nil, models: [OWModel(id: "m", name: "m")], defaultModel: "m",
                               temporary: true)
        vm.serverSearches = { false }

        for q in ["A", "B"] {
            vm.input = q
            vm.send()
            await waitUntil("the reply to \(q)") { !vm.isStreaming }
        }
        XCTAssertEqual(vm.messages.map(\.content), ["A", "Um.", "B", "Dois."])

        vm.regenerate(messageID: vm.messages[3].id)
        await waitUntil("the regenerated reply") { vm.messages.last?.content == "Dois de novo." }
        XCTAssertEqual(vm.messages.map(\.content), ["A", "Um.", "B", "Dois de novo."])
    }
}
