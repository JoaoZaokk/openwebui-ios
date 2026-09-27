import XCTest
import OpenWebUIKit
@testable import OpenWebUI

/// The 🔊 on a message, played for real in the simulator host.
///
/// Reported 27/09: messages could not be listened to, sent or received. Two
/// things made that true. A sent message had no 🔊 at all — the button lived in
/// the reply header only. And when the chosen engine could not produce audio (a
/// server whose speech engine is off, a key the provider refuses, a neural pack
/// that failed to load) the failure was written to a property only the Settings
/// screen reads: in the chat, the spinner simply went back to the speaker icon
/// and nothing played.
@MainActor
final class SpeechPlaybackTests: XCTestCase {

    private let engineKey = "voice.tts.engine"
    private var savedEngine: String?
    private var savedClient: OpenWebUIClient?

    override func setUp() async throws {
        savedEngine = UserDefaults.standard.string(forKey: engineKey)
        savedClient = SpeechManager.shared.client
        SpeechManager.shared.stop()
        SpeechManager.shared.dismissPlaybackFailure()
    }

    override func tearDown() async throws {
        SpeechManager.shared.stop()
        SpeechManager.shared.client = savedClient
        UserDefaults.standard.set(savedEngine, forKey: engineKey)
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
    }

    func testTheDeviceVoiceReadsAMessageToTheEnd() async throws {
        UserDefaults.standard.set("native", forKey: engineKey)
        let s = SpeechManager.shared
        s.toggle("Olá. Isto é um teste de leitura.", id: "m1")
        XCTAssertTrue(s.isSpeaking("m1"), "nothing started playing")
        try await waitUntil(20) { !s.isSpeaking("m1") }
        XCTAssertFalse(s.isSpeaking("m1"), "the utterance never finished")
        XCTAssertNil(s.playbackFailure)
    }

    func testAServerVoiceThatCannotStartIsReportedAndTheDeviceReadsInstead() async throws {
        UserDefaults.standard.set("server", forKey: engineKey)
        let s = SpeechManager.shared
        s.client = nil
        s.toggle("Mensagem que eu enviei.", id: "u1")
        XCTAssertEqual(s.playbackFailure?.messageID, "u1", "the chat never hears about it")
        XCTAssertTrue(s.isSpeaking("u1"), "the message still has to be heard")
    }

    func testAServerVoiceThatFailsOverTheNetworkFallsBackToo() async throws {
        UserDefaults.standard.set("server", forKey: engineKey)
        let s = SpeechManager.shared
        // Port 9 (discard) refuses at once: the same shape as a server whose
        // speech endpoint answers with an error, without waiting 30 s for one.
        s.client = OpenWebUIClient(config: OWConfig(baseURL: URL(string: "http://127.0.0.1:9")!),
                                   tokens: OWKeychainStore(service: "tests.speech"))
        s.toggle("Resposta que eu recebi.", id: "a1")
        try await waitUntil(15) { s.playbackFailure != nil }
        XCTAssertEqual(s.playbackFailure?.messageID, "a1")
        try await waitUntil(5) { s.isSpeaking("a1") }
        XCTAssertTrue(s.isSpeaking("a1"), "after the server failed, the device voice should read it")
    }
}
