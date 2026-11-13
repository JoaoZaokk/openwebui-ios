import XCTest
@testable import OpenWebUIKit

/// Report from 1.12 (iPad, hardware keyboard): "it would be much more efficient
/// if users could simply hit Enter to submit". The composer is a multi-line
/// field, so Return used to make a new line and only the arrow sent.
///
/// The rule is not just "Return sends". With a Chinese, Japanese or Korean
/// keyboard Return is also the key that confirms the characters being composed,
/// and a handler on the key cannot tell the two apart — a message would go out
/// half written. For those keyboards plain Return stays a newline/confirm and
/// ⌘Return sends.
final class ReturnKeyTests: XCTestCase {

    func testPlainReturnSends() {
        XCTAssertEqual(ReturnKey.action(modifiers: [], enabledInputLanguages: ["en-US", "pt-BR"]), .send)
    }

    func testShiftReturnIsANewLine() {
        XCTAssertEqual(ReturnKey.action(modifiers: .shift, enabledInputLanguages: ["en-US"]), .newline)
    }

    func testOptionAndControlReturnKeepTheirOwnMeaning() {
        XCTAssertEqual(ReturnKey.action(modifiers: .option, enabledInputLanguages: ["en-US"]), .newline)
        XCTAssertEqual(ReturnKey.action(modifiers: .control, enabledInputLanguages: ["en-US"]), .newline)
    }

    func testCommandReturnAlwaysSends() {
        for langs in [["en-US"], ["zh-Hans"], ["ja-JP", "en-US"]] {
            XCTAssertEqual(ReturnKey.action(modifiers: .command, enabledInputLanguages: langs), .send, "\(langs)")
        }
    }

    func testPlainReturnConfirmsCompositionWhenAnIMEKeyboardIsEnabled() {
        for langs in [["zh-Hans"], ["zh-Hant"], ["ja-JP"], ["ko-KR"], ["en-US", "zh-Hans"], ["yue-Hant"]] {
            XCTAssertEqual(ReturnKey.action(modifiers: [], enabledInputLanguages: langs), .newline, "\(langs)")
        }
    }

    func testNoKeyboardInformationDefaultsToSending() {
        XCTAssertEqual(ReturnKey.action(modifiers: [], enabledInputLanguages: []), .send)
    }

    func testEmojiAndDictationEntriesAreNotLanguages() {
        // The OS lists "emoji" and "dictation" as input modes without a language.
        XCTAssertEqual(ReturnKey.action(modifiers: [], enabledInputLanguages: ["emoji", "dictation", "en-US"]), .send)
    }
}
