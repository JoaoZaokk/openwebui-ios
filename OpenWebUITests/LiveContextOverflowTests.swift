import XCTest
import OpenWebUIKit
@testable import OpenWebUI

/// The summary path against the owner's real server and a real model past its
/// context. Skipped unless `OW_LIVE_FIXTURE` points at a `.ow-test-login`.
/// `OW_LIVE_MODEL` picks the model (glm-5.3-flash by default: cheap, and it
/// refuses with HTTP 400 "Prompt exceeds max length" past ~1M tokens).
@MainActor
final class LiveContextOverflowTests: XCTestCase {

    private let store = OWKeychainStore(service: "tests.liveoverflow")
    override func tearDown() { store.clear(); super.tearDown() }

    /// About 640k tokens of distinct sentences (measured ~4.2 characters a token on
    /// glm-5.3-flash): two of them overflow a 1M window, one fits.
    private func page(_ tag: String) -> String {
        (0..<30_000).map { "Relatório \(tag) número \($0): entregas de café por região, preços e transporte. " }.joined()
    }

    private func waitUntil(_ what: String, timeout: TimeInterval, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { try? await Task.sleep(nanoseconds: 200_000_000) }
        XCTAssertTrue(cond(), "timed out waiting for: \(what)")
    }

    func testARealModelPastItsContextIsSummarizedAndAnswers() async throws {
        guard let path = ProcessInfo.processInfo.environment["OW_LIVE_FIXTURE"],
              let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw XCTSkip("OW_LIVE_FIXTURE not set")
        }
        var kv: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            let p = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if p.count == 2 { kv[p[0]] = p[1] }
        }
        let model = ProcessInfo.processInfo.environment["OW_LIVE_MODEL"] ?? "glm-5.3-flash"
        let client = OpenWebUIClient(config: OWConfig(baseURL: try XCTUnwrap(kv["server"].flatMap(URL.init(string:)))),
                                     tokens: store)
        _ = try await client.signIn(email: try XCTUnwrap(kv["email"]), password: try XCTUnwrap(kv["senha"]))
        UserDefaults.standard.set(false, forKey: ChatViewModel.followUpsKey)
        defer { UserDefaults.standard.removeObject(forKey: ChatViewModel.followUpsKey) }
        let vm = ChatViewModel(client: client, completions: ChatCompletionsClient(client: client),
                               chat: nil, models: [OWModel(id: model, name: model)], defaultModel: model,
                               temporary: true)
        vm.serverSearches = { false }

        vm.input = page("A") + "\n\nResponda só: recebido A."
        vm.send()
        await waitUntil("the first reply", timeout: 300) { !vm.isStreaming }
        XCTAssertFalse(vm.contextOverflow, "the first page alone should fit: \(vm.messages.last?.content.prefix(200) ?? "")")

        vm.input = page("B") + "\n\nResponda só: recebido B."
        vm.send()
        await waitUntil("the second reply", timeout: 300) { !vm.isStreaming }
        print("LIVE overflow reply: \(vm.messages.last?.content.prefix(200) ?? "")")
        XCTAssertTrue(vm.contextOverflow, "two pages should overflow \(model)")

        await vm.summarizeAndRetry()
        await waitUntil("the reply after the summary", timeout: 300) { !vm.isStreaming && !vm.summarizing }
        let answer = vm.messages.last?.content ?? ""
        print("LIVE after summary: \(answer.prefix(300))")
        XCTAssertFalse(vm.contextOverflow)
        XCTAssertNil(vm.error)
        XCTAssertFalse(answer.isEmpty || answer.hasPrefix("⚠️"), answer)
        XCTAssertEqual(vm.messages.count, 4)
    }
}
