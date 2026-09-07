import XCTest
@testable import OpenWebUIKit

/// The three gates and the two signal helpers behind barge-in.
///
/// They are pinned rather than merely exercised: every constant here is
/// calibrated against levels measured on a physical device, and the previous
/// loudness-only version shipped a default threshold (0.075) above the quietest
/// voice ever measured (0.038) — a soft-spoken user could not interrupt at all,
/// and nothing anywhere would have caught it.
final class BargeInTuningTests: XCTestCase {

    // MARK: - Tuning

    func testThresholdSpansTheSlider() {
        XCTAssertEqual(BargeIn.Tuning(sensitivity: 0).threshold, 0.85, accuracy: 1e-6)
        XCTAssertEqual(BargeIn.Tuning(sensitivity: 0.5).threshold, 0.625, accuracy: 1e-6)
        XCTAssertEqual(BargeIn.Tuning(sensitivity: 1).threshold, 0.40, accuracy: 1e-6)
    }

    func testFloorSpansTheSlider() {
        XCTAssertEqual(BargeIn.Tuning(sensitivity: 0).floor, 0.046, accuracy: 1e-6)
        XCTAssertEqual(BargeIn.Tuning(sensitivity: 0.5).floor, 0.036, accuracy: 1e-6)
        XCTAssertEqual(BargeIn.Tuning(sensitivity: 1).floor, 0.026, accuracy: 1e-6)
    }

    /// The shipping default has to sit *under* the quietest voice measured on
    /// device (0.038) or a soft-spoken user cannot interrupt at all — which is
    /// exactly the bug the loudness-only version shipped.
    func testDefaultFloorIsBelowTheQuietestMeasuredVoice() {
        XCTAssertLessThan(BargeIn.Tuning(sensitivity: 0.5).floor, 0.038)
    }

    /// Three chunks (768 ms) wherever the floor cannot reject the loudest
    /// measured echo leak on its own, two (512 ms) where it can — which is only
    /// at the very bottom of the slider.
    func testChunksFollowTheFloorAgainstTheLoudestLeak() {
        XCTAssertEqual(BargeIn.Tuning(sensitivity: 0).chunks, 2)
        XCTAssertEqual(BargeIn.Tuning(sensitivity: 0.5).chunks, 3)
        XCTAssertEqual(BargeIn.Tuning(sensitivity: 1).chunks, 3)
        XCTAssertEqual(BargeIn.Tuning(sensitivity: 0).floor, BargeIn.loudestLeak, accuracy: 1e-6)
    }

    /// A slider value out of range must not produce a negative floor or a
    /// threshold past either end.
    func testSensitivityIsClamped() {
        XCTAssertEqual(BargeIn.Tuning(sensitivity: -3), BargeIn.Tuning(sensitivity: 0))
        XCTAssertEqual(BargeIn.Tuning(sensitivity: 9), BargeIn.Tuning(sensitivity: 1))
    }

    // MARK: - decimate

    /// Averaging, not dropping: on a ramp every output is the mean of its three
    /// inputs. Dropping would return 0, 3, 6 — and dropping aliases, which looks
    /// like energy to the detector.
    func testDecimateAveragesARamp() {
        let ramp: [Float] = (0..<9).map(Float.init)
        let (down, _) = BargeIn.decimate(ramp, by: 3)
        XCTAssertEqual(down, [1, 4, 7])
    }

    /// The mean squares are of the RAW samples, which is what keeps the loudness
    /// gate in the units it was calibrated in on device.
    func testDecimateCarriesTheRawMeanSquares() {
        let ramp: [Float] = (0..<9).map(Float.init)
        let (_, sqs) = BargeIn.decimate(ramp, by: 3)
        XCTAssertEqual(sqs[0], (0 + 1 + 4) / 3, accuracy: 1e-5)
        XCTAssertEqual(sqs[1], (9 + 16 + 25) / 3, accuracy: 1e-5)
        XCTAssertEqual(sqs[2], (36 + 49 + 64) / 3, accuracy: 1e-5)
    }

    /// A trailing partial group is dropped rather than averaged over fewer
    /// samples, which would report a level the room never produced.
    func testDecimateDropsAnIncompleteTail() {
        let (down, sqs) = BargeIn.decimate([1, 1, 1, 1, 1, 1, 1] as [Float], by: 3)
        XCTAssertEqual(down.count, 2)
        XCTAssertEqual(sqs.count, 2)
    }

    func testDecimateByOneIsIdentity() {
        let s: [Float] = [0.5, -0.5, 0.25]
        let (down, _) = BargeIn.decimate(s, by: 1)
        XCTAssertEqual(down, s)
    }

    /// A rate under 16 kHz would round the ratio to zero; the caller refuses to
    /// arm there, but the helper must not divide by it either.
    func testDecimateByZeroIsEmpty() {
        let (down, sqs) = BargeIn.decimate([1, 2, 3] as [Float], by: 0)
        XCTAssertTrue(down.isEmpty)
        XCTAssertTrue(sqs.isEmpty)
    }

    // MARK: - rms

    func testRMSOfMeanSquares() {
        XCTAssertEqual(BargeIn.rms(ofMeanSquares: [0.04, 0.04, 0.04][...]), 0.2, accuracy: 1e-6)
        XCTAssertEqual(BargeIn.rms(ofMeanSquares: [0, 0.08][...]), 0.2, accuracy: 1e-6)
        XCTAssertEqual(BargeIn.rms(ofMeanSquares: ArraySlice<Float>()), 0)
    }

    /// Round trip: a constant-amplitude signal decimated and measured comes back
    /// at its own amplitude, which is the property the device calibration rests
    /// on.
    func testDecimateThenRMSRecoversTheAmplitude() {
        let square: [Float] = (0..<48).map { $0 % 2 == 0 ? 0.1 : -0.1 }
        let (_, sqs) = BargeIn.decimate(square, by: 3)
        XCTAssertEqual(BargeIn.rms(ofMeanSquares: sqs[...]), 0.1, accuracy: 1e-5)
    }
}
