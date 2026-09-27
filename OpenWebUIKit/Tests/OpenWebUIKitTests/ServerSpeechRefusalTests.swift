import XCTest
@testable import OpenWebUIKit

/// `/audio/speech` when the server has no speech engine to use.
///
/// With the admin's text-to-speech engine left on its default (the browser's
/// own voice) the server answers 404 with its generic "We could not find what
/// you're looking for :/", and the slim image answers 503. Either one reached
/// the chat as that sentence, which says nothing about what to change.
final class ServerSpeechRefusalTests: XCTestCase {

    private let store = OWKeychainStore(service: "tests.serverspeech")
    override func setUp() { super.setUp(); StubTransport.reset(); store.clear() }
    override func tearDown() { StubTransport.reset(); store.clear(); super.tearDown() }

    private func client() -> OpenWebUIClient {
        store.save(token: "t")
        return OpenWebUIClient(config: OWConfig(baseURL: URL(string: "https://tts.test")!),
                               tokens: store, protocolClasses: [StubTransport.self])
    }

    private func refusal(_ reply: StubTransport.Reply) async -> String? {
        StubTransport.route("/api/v1/audio/speech", reply)
        do { _ = try await client().speech(text: "oi"); return nil }
        catch { return error.localizedDescription }
    }

    func testNoEngineConfiguredSaysWhereToConfigureIt() async {
        let why = await refusal(.json(#"{"detail":"We could not find what you're looking for :/"}"#, status: 404))
        XCTAssertEqual(why, L("O servidor não tem um motor de voz (TTS) configurado."))
    }

    func testSlimImageWithoutAnEngineSaysTheSame() async {
        let why = await refusal(.json(#"{"detail":"Configure an external text-to-speech engine."}"#, status: 503))
        XCTAssertEqual(why, L("O servidor não tem um motor de voz (TTS) configurado."))
    }

    func testAProviderRefusalIsPassedThrough() async {
        let why = await refusal(.json(#"{"detail":"Invalid voice id"}"#, status: 400))
        XCTAssertEqual(why, "Invalid voice id")
    }
}
