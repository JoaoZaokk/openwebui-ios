import XCTest
@testable import OpenWebUI

/// The reply layout (Settings › Appearance › Reply style). Automatic is plain
/// text — the GPT/Claude layout — except on the engraved Hermes themes, where
/// the engraving would run behind the text and the reading lane fades it.
final class ReplyStyleTests: XCTestCase {

    private let hermes = Theme.named("hermes")
    private let openwebui = Theme.named("openwebui")

    override func setUp() { super.setUp(); UserDefaults.standard.removeObject(forKey: "debug.replyStyle") }

    func testAutomaticIsPlainTextExceptOnEngravedThemes() {
        XCTAssertEqual(ReplyStyle.auto.resolved(for: openwebui), .plain)
        XCTAssertEqual(ReplyStyle.auto.resolved(for: hermes), .lane)
        XCTAssertEqual(ReplyStyle.auto.resolved(for: Theme.named("hermes_noir")), .lane)
    }

    func testAChosenStyleIsKept() {
        for style in [ReplyStyle.bubble, .glass, .plain] {
            XCTAssertEqual(style.resolved(for: hermes), style)
            XCTAssertEqual(style.resolved(for: openwebui), style)
        }
    }

    func testAReadingLaneWithNoEngravingIsPlainText() {
        XCTAssertEqual(ReplyStyle.lane.resolved(for: openwebui), .plain)
        XCTAssertEqual(ReplyStyle.lane.resolved(for: hermes), .lane)
    }
}
