import XCTest
@testable import OpenWebUIKit

/// Report on build 27: "a slider like the barge-in sensitivity — low 3 s,
/// medium 2 s, high 1 s of silence".
final class EndpointWaitTests: XCTestCase {

    func testTheLevelsAreTheSecondsAskedFor() {
        for live in [true, false] {
            XCTAssertEqual(EndpointWait.high.seconds(liveTranscript: live), 1)
            XCTAssertEqual(EndpointWait.medium.seconds(liveTranscript: live), 2)
            XCTAssertEqual(EndpointWait.low.seconds(liveTranscript: live), 3)
        }
    }

    /// Nobody who never opens the setting may notice it exists: automatic is the
    /// wait 1.14 (27) shipped with.
    func testAutomaticKeepsTheShippedWaits() {
        XCTAssertEqual(EndpointWait.automatic.seconds(liveTranscript: true), 1.6, accuracy: 0.0001)
        XCTAssertEqual(EndpointWait.automatic.seconds(liveTranscript: false), 2.3, accuracy: 0.0001)
    }

    func testNothingStoredOrSomethingUnknownIsAutomatic() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "EndpointWaitTests"))
        d.removePersistentDomain(forName: "EndpointWaitTests")
        XCTAssertEqual(EndpointWait.stored(d), .automatic)
        d.set("7", forKey: EndpointWait.key)
        XCTAssertEqual(EndpointWait.stored(d), .automatic)
        d.set("3", forKey: EndpointWait.key)
        XCTAssertEqual(EndpointWait.stored(d), .low)
        d.removePersistentDomain(forName: "EndpointWaitTests")
    }

    /// The energy endpointer takes the wait as it is given: one pause of exactly
    /// the chosen length after speech ends the turn, a shorter one does not.
    func testTheEndpointerEndsOnTheChosenWait() {
        for wait in EndpointWait.allCases {
            let s = wait.seconds(liveTranscript: false)
            var e = EnergyEndpointer(silence: s)
            e.feed(0.0005, at: 0)                 // floor
            e.feed(0.02, at: 0.1)                 // speech
            e.feed(0.0005, at: 0.2)               // quiet from here
            XCTAssertFalse(e.shouldEnd(at: 0.1 + s - 0.15), "\(wait) ended early")
            XCTAssertTrue(e.shouldEnd(at: 0.1 + s + 0.05), "\(wait) did not end")
        }
    }
}
