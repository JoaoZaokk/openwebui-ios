import XCTest
@testable import OpenWebUIKit

/// `streamReply` against a real Open WebUI, with the owner's disposable test
/// account. Skipped unless `OW_LIVE_FIXTURE` points at a `.ow-test-login`
/// (`server=`, `email=`, `senha=`). `OW_LIVE_MODEL` picks the model; without
/// it, the newest MiMo the account can see, else its first model.
final class LiveWebSearchReplyTests: XCTestCase {

    private let store = OWKeychainStore(service: "tests.livewebsearch")

    override func tearDown() { store.clear(); super.tearDown() }

    private func signedIn() async throws -> (ChatCompletionsClient, String) {
        guard let path = ProcessInfo.processInfo.environment["OW_LIVE_FIXTURE"],
              let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw XCTSkip("OW_LIVE_FIXTURE not set")
        }
        var kv: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { kv[parts[0]] = parts[1] }
        }
        let base = try XCTUnwrap(kv["server"].flatMap(URL.init(string:)))
        let client = OpenWebUIClient(config: OWConfig(baseURL: base), tokens: store)
        _ = try await client.signIn(email: try XCTUnwrap(kv["email"]), password: try XCTUnwrap(kv["senha"]))
        if let pinned = ProcessInfo.processInfo.environment["OW_LIVE_MODEL"] {
            return (ChatCompletionsClient(client: client), pinned)
        }
        let ids = try await client.models().map(\.id)
        let mimo = ids.filter { $0.lowercased().hasPrefix("mimo") }.sorted().last
        return (ChatCompletionsClient(client: client), try XCTUnwrap(mimo ?? ids.first, "no model visible"))
    }

    private func ask(_ question: String) async throws -> (text: String, searched: [[String]], sources: Int) {
        let (completions, model) = try await signedIn()
        print("LIVE model=\(model)")
        var text = "", searched: [[String]] = [], sources = 0
        let msgs = [OWChatMessageInput(role: "system", text: "You are a friendly voice companion. Answer in 1 to 3 short sentences, in the user's language."),
                    OWChatMessageInput(role: "user", text: question)]
        for try await u in completions.streamReply(model: model, messages: msgs,
                                                   search: OWReplySearch(offer: true, mayRun: true)) {
            switch u {
            case .textDelta(let t): text += t
            case .searching(let q): searched.append(q)
            case .sources(let s): sources += s.count
            case .error(let e): XCTFail("error: \(e)")
            case .searchFailed(let e): XCTFail("search failed: \(e)")
            default: break
            }
        }
        return (text, searched, sources)
    }

    func testACurrentQuestionIsSearchedAndAnswered() async throws {
        let r = try await ask("Pesquise na web: qual é a cotação do dólar em reais hoje?")
        XCTAssertEqual(r.searched.count, 1, "one search")
        XCTAssertGreaterThan(r.sources, 0)
        XCTAssertFalse(r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(r.text.contains("tool_call") || r.text.contains("call:search"), r.text)
        print("LIVE searched=\(r.searched) sources=\(r.sources) text=\(r.text.prefix(300))")
    }

    func testSmallTalkIsNotSearched() async throws {
        let r = try await ask("Oi, tudo bem?")
        XCTAssertTrue(r.searched.isEmpty)
        XCTAssertFalse(r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        print("LIVE smalltalk text=\(r.text.prefix(200))")
    }
}
