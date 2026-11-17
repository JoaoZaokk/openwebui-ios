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

    // MARK: - Fault injection: the server's audio arrives broken

    /// A WAV whose header promises 100 000 bytes of samples and delivers 20 — what
    /// a connection cut mid-body (or a TTS server giving up on long input) leaves.
    private func truncatedWav() -> Data {
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) } }
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
        var d: [UInt8] = Array("RIFF".utf8) + le32(100_036) + Array("WAVE".utf8)
        d += Array("fmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(16_000) + le32(32_000) + le16(2) + le16(16)
        d += Array("data".utf8) + le32(100_000) + [UInt8](repeating: 1, count: 20)
        return Data(d)
    }

    /// Report from 1.14: "OSStatus error -39" in the middle of long, formatted
    /// replies, with a self-hosted TTS. -39 is end-of-file: the server answered 200
    /// with something that is not a whole audio file. Each kind of broken body is
    /// injected here as the answer to *every* sentence of a queued (hands-free)
    /// reply. The reply must still end by itself, with no failure reported and no
    /// raw OSStatus on screen — the device voice reads what the server could not.
    func testAQueuedReplyWhoseServerAudioIsBrokenStillEndsAndReportsNoFailure() async throws {
        let bodies: [(String, Data)] = [
            ("truncated-wav", truncatedWav()),
            ("empty", Data()),
            ("html-error", Data("<html><body>500 upstream timed out</body></html>".utf8)),
            ("garbage", Data(repeating: 0x42, count: 300)),
        ]
        for (label, body) in bodies {
            UserDefaults.standard.set("server", forKey: engineKey)
            StubTransport.reset()
            StubTransport.route("/api/v1/audio/speech",
                                .init(200, body, headers: ["Content-Type": "audio/mpeg"]))
            let s = SpeechManager.shared
            s.stop()
            s.client = OpenWebUIClient(config: OWConfig(baseURL: URL(string: "https://tts.test")!),
                                       tokens: OWKeychainStore(service: "tests.speech.fault"),
                                       protocolClasses: [StubTransport.self])
            var failures: [String?] = []
            var finished = false
            s.onSpeechFailed = { failures.append($0) }
            s.onSpeechFinished = { finished = true }
            let id = "fault-\(label)"
            s.enqueue("Primeira frase do relatório.", id: id)
            s.enqueue("Segunda frase, com marcadores e negrito.", id: id)
            s.closeQueue(id: id)
            try await waitUntil(90) { finished || !failures.isEmpty }
            s.onSpeechFailed = nil; s.onSpeechFinished = nil
            XCTAssertTrue(failures.isEmpty, "\(label): the reply was abandoned with \(failures)")
            XCTAssertTrue(finished, "\(label): the turn never ended")
            XCTAssertNil(s.neuralError.flatMap { $0.contains("-39") ? $0 : nil },
                         "\(label): a raw OSStatus reached the screen")
        }
        // The first bytes of what came back are in the diagnostic log.
        let bad = DiagnosticsStore.shared.recentEvents().filter { $0.name == "tts.badAudio" }
        XCTAssertGreaterThanOrEqual(bad.count, 1, "no tts.badAudio event was written")
    }

    /// Report from 1.14 (iPhone Duo): the reply came out of the "handset speaker"
    /// at call volume. The proximity sensor reads "near" for a phone face-down on a
    /// table, in a hand held flat, or open as a book — not only at the ear.
    func testTheEarpieceIsOnlyForAPhoneHeldUprightAtTheEar() {
        XCTAssertTrue(SpeechManager.earpieceWanted(near: true, orientation: .portrait))
        XCTAssertTrue(SpeechManager.earpieceWanted(near: true, orientation: .unknown))
        XCTAssertFalse(SpeechManager.earpieceWanted(near: false, orientation: .portrait))
        for flat in [UIDeviceOrientation.faceDown, .faceUp, .landscapeLeft, .landscapeRight] {
            XCTAssertFalse(SpeechManager.earpieceWanted(near: true, orientation: flat),
                           "a near reading while \(flat.rawValue) must not mute the loudspeaker")
        }
    }
}
