import XCTest
@testable import OpenWebUIKit

/// Report from 1.14: "it might also be nice to be able to search for a note".
final class NoteSearchTests: XCTestCase {
    private let note = OWNote(id: "n", title: "Lista de compras", markdown: "Pão, café e açúcar")

    func testMatchesTitleOrBodyIgnoringCaseAndAccents() {
        XCTAssertTrue(note.matches("COMPRAS"))
        XCTAssertTrue(note.matches("cafe"))
        XCTAssertTrue(note.matches("acucar"))
        XCTAssertFalse(note.matches("chocolate"))
    }

    func testABlankQueryShowsEverything() {
        XCTAssertTrue(note.matches(""))
        XCTAssertTrue(note.matches("   "))
    }
}
