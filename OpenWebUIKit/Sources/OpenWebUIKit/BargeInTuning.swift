import Foundation

/// The arithmetic behind interrupting the assistant by talking over it.
///
/// Everything here is a pure function of numbers, which is why it lives in the
/// kit: the gates are calibrated against levels measured on a physical device
/// and there is no other way to pin them. The AVFoundation half — the engine,
/// the tap, echo cancellation, the audio session — stays in the app.
public enum BargeIn {

    /// Loudest echo excursion caught on device: a 0.046 RMS spike, 2.4× the
    /// residual ceiling of the same session, which fired barge-in and cut the
    /// assistant mid-sentence onto eleven seconds of silence.
    ///
    /// It sits *above* the quietest voice ever measured (0.038), and that is the
    /// uncomfortable part: no loudness floor can reject this leak while still
    /// accepting someone speaking softly. Loudness cannot separate them, so
    /// duration has to.
    public static let loudestLeak: Float = 0.046

    /// The three gates, all derived from the one sensitivity setting so they
    /// cannot drift apart when the mapping is retuned.
    public struct Tuning: Equatable {
        /// Speech probability a chunk must reach. From the sensitivity slider:
        /// high sensitivity → lower bar → easier to interrupt.
        public let threshold: Float

        /// Minimum level for a chunk to even reach the model.
        ///
        /// This is the second half of the decision, and it is not an
        /// optimization. The detector answers "is this a human voice?", and echo
        /// residual *is* one — device traces show it scoring 1.00 at rms 0.014,
        /// which fired barge-in on the assistant's own words. What separates the
        /// two is loudness, and on device the gap is *almost* clean: residual
        /// sits at 0.006–0.022, the user's voice at 0.038–0.206 — but the
        /// loudest leak excursion reached 0.046, over the quietest voice. So the
        /// floor's job is only to rule out anything too quiet to have come from
        /// the room; the overlap is duration's problem.
        public let floor: Float

        /// Consecutive speech chunks required. Each chunk is 4096 samples at
        /// 16 kHz (256 ms), so two of them is roughly half a second of
        /// continuous voice — long enough to rule out a cough or a door.
        ///
        /// Three of them wherever the loudness floor cannot reject
        /// `loudestLeak` on its own, which since the retune is everything above
        /// the very bottom of the slider. That is the honest reading of the
        /// device traces: the floor never separated the two populations,
        /// duration did. With three required, the same class of spike that used
        /// to cut the assistant (0.046, 0.037, 0.031, all scoring 0.88–0.98)
        /// stalled at 1/3 and never fired, while a real interruption (0.141 then
        /// 0.081) reached 3/3 and cut immediately.
        public let chunks: Int

        public init(sensitivity s: Double) {
            let s = max(0, min(1, s))
            threshold = Float(0.85 - s * 0.45)   // s=0 → 0.85 (hard), s=1 → 0.40 (easy)

            // s=0 → 0.046, s=0.5 → 0.036, s=1 → 0.026.
            //
            // The top of the range is `loudestLeak` rather than a number above
            // it: from the first notch upward the floor stops pretending it can
            // separate leak from voice and hands that job to duration. A floor
            // above the quietest measured voice (0.038) is what made a
            // soft-spoken user unable to interrupt at all.
            let floor = Float(0.046 - s * 0.020)
            self.floor = floor

            // Derived from the floor rather than written as its own sensitivity
            // number, so the two cannot drift apart when the mapping is retuned.
            chunks = floor < BargeIn.loudestLeak ? 3 : 2
        }
    }

    /// Averaging decimation, plus the mean square of the raw samples behind each
    /// output sample.
    ///
    /// Averaging rather than plain sample-dropping: dropping aliases, and
    /// aliasing looks like energy to the model. The raw energy is carried
    /// alongside so the loudness gate can be measured over exactly the span the
    /// model judges, instead of over whichever tap buffer happened to complete
    /// the chunk — one quiet trailing buffer used to veto an otherwise clearly
    /// voiced chunk.
    public static func decimate<C: RandomAccessCollection>(
        _ s: C, by factor: Int
    ) -> (down: [Float], meanSquares: [Float]) where C.Element == Float, C.Index == Int {
        guard factor > 0 else { return ([], []) }
        let n = s.count
        let base = s.startIndex
        var down: [Float] = []
        var sqs: [Float] = []
        down.reserveCapacity(n / factor + 1)
        sqs.reserveCapacity(n / factor + 1)
        var i = 0
        while i + factor <= n {
            var acc: Float = 0
            var sq: Float = 0
            for k in 0..<factor { let v = s[base + i + k]; acc += v; sq += v * v }
            down.append(acc / Float(factor))
            sqs.append(sq / Float(factor))
            i += factor
        }
        return (down, sqs)
    }

    /// RMS of the raw audio behind a run of decimated samples, from the mean
    /// squares `decimate` produced. This is what the loudness gate reads.
    public static func rms(ofMeanSquares sqs: ArraySlice<Float>) -> Float {
        guard !sqs.isEmpty else { return 0 }
        return (sqs.reduce(0, +) / Float(sqs.count)).squareRoot()
    }
}
