import XCTest
@testable import OpenWebUIKit

/// Report from 1.14: "there is no way to search for something once you are in a
/// chat — on the web the browser's search does it".
final class ChatFindTests: XCTestCase {
    private let chat = [
        OWMessage(id: "1", role: .user, content: "Qual a capital da França?"),
        OWMessage(id: "2", role: .assistant, content: "A capital da França é **Paris**."),
        OWMessage(id: "3", role: .user, content: "E da Alemanha?"),
        OWMessage(id: "4", role: .assistant, content: "Berlim.", reasoning: "Pensando na capital alemã"),
    ]

    func testFindsMessagesInOrderIgnoringCaseAndAccents() {
        XCTAssertEqual(ChatFind.matchingIDs("FRANCA", in: chat), ["1", "2"])
        XCTAssertEqual(ChatFind.matchingIDs("paris", in: chat), ["2"])
    }

    func testAnEmptyOrBlankQueryMatchesNothing() {
        XCTAssertTrue(ChatFind.matchingIDs("", in: chat).isEmpty)
        XCTAssertTrue(ChatFind.matchingIDs("   ", in: chat).isEmpty)
    }

    func testTheReasoningOfAReplyIsNotSearchedButWhatIsOnScreenIs() {
        // "pensando" appears only in the collapsed thinking, so it does not count.
        XCTAssertTrue(ChatFind.matchingIDs("pensando", in: chat).isEmpty)
        XCTAssertEqual(ChatFind.matchingIDs("berlim", in: chat), ["4"])
    }

    func testTheNextAndPreviousWrapAround() {
        XCTAssertEqual(ChatFind.step(from: 0, by: 1, count: 3), 1)
        XCTAssertEqual(ChatFind.step(from: 2, by: 1, count: 3), 0)
        XCTAssertEqual(ChatFind.step(from: 0, by: -1, count: 3), 2)
        XCTAssertEqual(ChatFind.step(from: 0, by: 1, count: 0), 0)
    }
}
