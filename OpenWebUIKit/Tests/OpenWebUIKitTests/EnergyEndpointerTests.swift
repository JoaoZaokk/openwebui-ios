import XCTest
@testable import OpenWebUIKit

/// Report from 1.12 (iPad Pro M4): with the on-device model or the server as
/// the speech engine, hands-free voice mode never noticed the person had
/// stopped talking — only a tap on the screen ended the turn. Those engines
/// have no live transcript, so the turn ends on energy, and the gate was one
/// absolute number (RMS 0.04). The recorder runs in `.measurement` mode, which
/// turns the system's gain control off; a voice there reads 0.006–0.023 on an
/// iPhone, so it never crossed the gate. Apple's own recognizer was fine
/// because it ends on its transcript, which is exactly what the report says.
///
/// Every test replays a level series the way the tap delivers it: one RMS per
/// 8192-frame buffer, about 0.17 s apart at 48 kHz.
final class EnergyEndpointerTests: XCTestCase {

    private let step = 0.17

    /// Feeds `levels` starting at `from`, returns the time after the last one.
    @discardableResult
    private func feed(_ e: inout EnergyEndpointer, _ levels: [Float], from t: Double) -> Double {
        var now = t
        for l in levels { e.feed(l, at: now); now += step }
        return now
    }

    private func run(_ n: Int, _ f: (Int) -> Float) -> [Float] { (0..<n).map(f) }

    /// Levels measured on an iPhone 15 Pro Max through the same recorder:
    /// room 0.0012–0.0017, a voice 0.006–0.023.
    private func quietRoom(_ n: Int) -> [Float] { run(n) { 0.0012 + Float($0 % 6) * 0.0001 } }
    private func quietVoice(_ n: Int) -> [Float] { run(n) { 0.006 + Float(($0 * 7) % 18) * 0.001 } }

    func testAQuietVoiceEndsTheTurnAfterTheSilence() {
        var e = EnergyEndpointer()
        var t = feed(&e, quietRoom(6), from: 0)
        t = feed(&e, quietVoice(18), from: t)            // ~3 s of speech
        XCTAssertTrue(e.heardSpeech, "a voice at 0.006–0.023 has to count as speech")
        XCTAssertFalse(e.shouldEnd(at: t))
        let spoke = t
        t = feed(&e, quietRoom(5), from: t)              // 0.85 s of silence
        XCTAssertFalse(e.shouldEnd(at: t), "silence shorter than the window must not end the turn")
        t = feed(&e, quietRoom(8), from: t)              // 2.2 s in all
        XCTAssertTrue(e.shouldEnd(at: t), "ended \(t - spoke) s after the last word")
    }

    func testTheOldAbsoluteGateWouldNeverHaveHeardIt() {
        // Pins the premise of the report: this voice never exceeds 0.04.
        XCTAssertLessThan(quietVoice(100).max() ?? 1, 0.04)
    }

    func testALoudCloseMicEndsToo() {
        var e = EnergyEndpointer()
        var t = feed(&e, run(6) { _ in 0.003 }, from: 0)
        t = feed(&e, run(18) { 0.10 + Float($0 % 5) * 0.04 }, from: t)
        XCTAssertTrue(e.heardSpeech)
        t = feed(&e, run(12) { _ in 0.003 }, from: t)
        XCTAssertTrue(e.shouldEnd(at: t))
    }

    func testNothingEndsBeforeSomeoneSpoke() {
        var e = EnergyEndpointer()
        let t = feed(&e, quietRoom(200), from: 0)        // 34 s of an empty room
        XCTAssertFalse(e.heardSpeech)
        XCTAssertFalse(e.shouldEnd(at: t))
    }

    func testAPauseInsideTheSentenceDoesNotEndIt() {
        var e = EnergyEndpointer()
        var t = feed(&e, quietRoom(6), from: 0)
        t = feed(&e, quietVoice(12), from: t)
        t = feed(&e, quietRoom(7), from: t)              // 1.2 s thinking
        XCTAssertFalse(e.shouldEnd(at: t))
        t = feed(&e, quietVoice(10), from: t)            // and it carries on
        XCTAssertFalse(e.shouldEnd(at: t))
        t = feed(&e, quietRoom(12), from: t)
        XCTAssertTrue(e.shouldEnd(at: t))
    }

    func testASteadyNoisyRoomIsNotTheEndOfSpeechNorItsStart() {
        // A fan: 0.02 all the time. Speech over it is 0.08+.
        var e = EnergyEndpointer()
        var t = feed(&e, run(8) { _ in 0.020 }, from: 0)
        XCTAssertFalse(e.heardSpeech, "steady noise is not speech")
        t = feed(&e, run(14) { 0.08 + Float($0 % 4) * 0.02 }, from: t)
        XCTAssertTrue(e.heardSpeech)
        t = feed(&e, run(12) { _ in 0.020 }, from: t)
        XCTAssertTrue(e.shouldEnd(at: t), "back to the fan's level is silence")
    }

    /// The floor that rose with the speaker's own voice is what shut the
    /// Redoma capture on top of speech: ordinary speech fell under a gate that
    /// had climbed. Twenty seconds of one steady level must stay speech.
    func testTheFloorDoesNotClimbWithALongSpeech() {
        var e = EnergyEndpointer()
        var t = feed(&e, quietRoom(6), from: 0)
        t = feed(&e, run(120) { _ in 0.012 }, from: t)   // 20 s
        XCTAssertFalse(e.shouldEnd(at: t))
        XCTAssertLessThan(e.floor ?? 1, 0.003, "the floor learned from silence, not from speech")
        t = feed(&e, quietRoom(12), from: t)
        XCTAssertTrue(e.shouldEnd(at: t))
    }

    func testStartingToTalkOnTheVeryFirstBufferStillEnds() {
        var e = EnergyEndpointer()
        var t = feed(&e, run(10) { 0.015 + Float($0 % 3) * 0.004 }, from: 0)
        t = feed(&e, quietRoom(3), from: t)              // a dip teaches the floor
        t = feed(&e, quietVoice(6), from: t)
        t = feed(&e, quietRoom(14), from: t)
        XCTAssertTrue(e.shouldEnd(at: t))
    }

    func testSoftTailWordsAfterALoudPeakStillHoldTheTurnOpen() {
        var e = EnergyEndpointer()
        var t = feed(&e, quietRoom(6), from: 0)
        t = feed(&e, run(8) { _ in 0.30 }, from: t)      // a loud start
        t = feed(&e, run(6) { _ in 0.030 }, from: t)     // trailing off, still words
        XCTAssertFalse(e.shouldEnd(at: t + 1.0))
        let lastWord = t
        t = feed(&e, quietRoom(14), from: t)
        XCTAssertTrue(e.shouldEnd(at: t), "ended \(t - lastWord) s after the tail")
    }

    func testTheFloorOnlyEverFallsToWhatSilenceShows() {
        var e = EnergyEndpointer()
        feed(&e, [0.02, 0.0015, 0.0015], from: 0)
        XCTAssertEqual(e.floor ?? 1, 0.0015, accuracy: 0.0005)
    }

    func testAMinimumGateKeepsDeadSilenceFromArming() {
        // A mic that reads 0.0002 in a dead room must not call 0.0006 speech.
        var e = EnergyEndpointer()
        feed(&e, run(30) { _ in 0.0002 } + run(10) { _ in 0.0006 }, from: 0)
        XCTAssertFalse(e.heardSpeech)
    }
}
