import Foundation

/// Decides, from the microphone's loudness alone, that the person has finished
/// talking. Used by the speech engines that have no live transcript to watch —
/// the on-device model and the server — where Apple's recognizer would have
/// ended the turn on its own text.
///
/// It lives in the kit for the reason `BargeIn` does: the numbers are tied to
/// levels measured on real hardware, and a pure function of those numbers is the
/// only way to pin them.
///
/// **Nothing here is an absolute loudness.** The first version was one constant
/// (RMS 0.04), taken from a laptop. The recorder runs in `.measurement` mode,
/// which switches the system's gain control off, and a phone then reads a voice
/// at 0.006–0.023 and an empty room at 0.0012–0.0017 — a tenth of the laptop.
/// The constant was never crossed, so hands-free mode waited for a tap (report
/// from 1.12, iPad Pro M4). Every gate is now a multiple of the room's own
/// level, learned while it was quiet, with one small minimum so a dead-silent
/// mic does not call its own hiss speech.
public struct EnergyEndpointer {

    /// How long the level must stay below the hold gate, after speech, for the
    /// turn to be over.
    public let silence: TimeInterval

    /// The lowest level that can ever count as speech. Below this the mic's own
    /// noise is indistinguishable from a voice, whatever the room reads.
    public static let minimumGate: Float = 0.004

    /// Highest the hold gate may climb with a loud peak. A loud start must not
    /// make the soft end of the same sentence read as silence.
    public static let holdCeiling: Float = 0.02

    /// The room's level as silence showed it. `nil` until the first buffer.
    public private(set) var floor: Float?
    /// Loudest buffer so far that counted as speech.
    public private(set) var peak: Float = 0
    public private(set) var heardSpeech = false
    private var lastLoud: TimeInterval?

    public init(silence: TimeInterval = 1.6) {
        self.silence = silence
    }

    /// Level a buffer must pass to *start* the turn's speech.
    public var armGate: Float { max(Self.minimumGate, (floor ?? 0) * 3) }

    /// Level a buffer must pass to count as *still talking*, once speech began.
    /// Lower than the arming gate and tied to the peak: ordinary speech has soft
    /// words and the end of a sentence trails off.
    public var holdGate: Float {
        max(Self.minimumGate, (floor ?? 0) * 2, min(peak * 0.15, Self.holdCeiling))
    }

    /// One buffer's RMS, at `time` (any monotonic clock, in seconds).
    public mutating func feed(_ level: Float, at time: TimeInterval) {
        guard level.isFinite, level >= 0 else { return }

        // The first buffer only teaches the floor. Judged against no floor at
        // all it was judged against the minimum gate alone, and a fan at 0.02
        // armed the turn on its very first buffer. If the person is already
        // talking, the first dip between words brings the floor down at once.
        guard let f = floor else { floor = level; return }

        let counts = level > (heardSpeech ? holdGate : armGate)
        if counts {
            if !heardSpeech { heardSpeech = true }
            peak = max(peak, level)
            lastLoud = time
            // The floor is frozen by speech. The Redoma capture closed on top
            // of a person because a floor that rose with their voice pushed
            // the gate past ordinary speech.
            return
        }
        // Falls at once to anything quieter; climbs only a little per buffer,
        // and only on buffers that were not speech, so a room that got noisier
        // is followed and a person who got louder is not.
        floor = level < f ? level : f + (level - f) * 0.02
    }

    /// True once speech was heard and has been absent for `silence` seconds.
    public func shouldEnd(at time: TimeInterval) -> Bool {
        guard heardSpeech, let last = lastLoud else { return false }
        return time - last > silence
    }
}
