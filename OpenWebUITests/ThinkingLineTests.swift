import XCTest
@testable import OpenWebUI

/// While a model thinks, the chat shows one line of what it is on — the way
/// Claude shows "Choosing how to show the itinerary" — instead of the whole
/// reasoning pouring out above the reply.
final class ThinkingLineTests: XCTestCase {

    func testTheLatestFinishedSentenceIsShown() {
        let r = "The user wants a 3-day itinerary for Lisbon. I should include a chart. Then a quest"
        XCTAssertEqual(ReasoningDisclosure.currentLine(r), "I should include a chart.")
    }

    func testBeforeAnySentenceEndsTheTextSoFarIsShown() {
        XCTAssertEqual(ReasoningDisclosure.currentLine("The user wants me to create"), "The user wants me to create")
    }

    func testTheLastLineCountsAndMarkdownGoes() {
        let r = "**Planning the trip**\n\n- Considering the weather in October.\n"
        XCTAssertEqual(ReasoningDisclosure.currentLine(r), "Considering the weather in October.")
    }

    func testALongSentenceIsCut() {
        let long = String(repeating: "palavra ", count: 40) + "fim."
        let line = ReasoningDisclosure.currentLine(long)
        XCTAssertLessThanOrEqual(line.count, 91)
        XCTAssertTrue(line.hasSuffix("…"))
    }

    func testNothingYetIsEmpty() {
        XCTAssertEqual(ReasoningDisclosure.currentLine("  \n "), "")
    }
}
