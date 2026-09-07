import XCTest
@testable import OpenWebUIKit

/// The speech language is one stored string with three meanings — a language
/// code, "follow the app", "let the engine guess" — so the cases worth pinning
/// down are the two that are not a code, plus the one nobody writes on purpose:
/// a code this build no longer knows.
final class SpeechLanguageTests: XCTestCase {
    private var saved: String?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.string(forKey: SpeechLanguage.key)
    }

    override func tearDown() {
        if let saved { UserDefaults.standard.set(saved, forKey: SpeechLanguage.key) }
        else { UserDefaults.standard.removeObject(forKey: SpeechLanguage.key) }
        super.tearDown()
    }

    func testAutoPinsNothingSoTheEngineDetects() {
        UserDefaults.standard.set(SpeechLanguage.auto, forKey: SpeechLanguage.key)
        XCTAssertNil(SpeechLanguage.pinned())
    }

    func testFollowingTheAppPinsTheAppLanguage() {
        UserDefaults.standard.set(SpeechLanguage.followApp, forKey: SpeechLanguage.key)
        XCTAssertEqual(SpeechLanguage.pinned(), LanguageManager.shared.current)
    }

    /// Nothing stored is the shipped default, and it must mean the same as
    /// "follow the app" rather than detection.
    func testAnUnsetPreferenceFollowsTheApp() {
        UserDefaults.standard.removeObject(forKey: SpeechLanguage.key)
        XCTAssertEqual(SpeechLanguage.pinned(), LanguageManager.shared.current)
    }

    func testAStoredLanguageIsThePinnedOne() {
        UserDefaults.standard.set(AppLanguage.ja.rawValue, forKey: SpeechLanguage.key)
        XCTAssertEqual(SpeechLanguage.pinned(), .ja)
    }

    /// A code left behind by a build that shipped a language this one dropped.
    /// Degrading to detection would be the worse of the two failures: the
    /// Whisper family guesses a random language on short or noisy audio and
    /// hands back nothing, whereas the app's own language is at least a language
    /// the user reads.
    func testAnUnknownCodeFallsBackToTheAppLanguageNotToDetection() {
        UserDefaults.standard.set("xx-NOPE", forKey: SpeechLanguage.key)
        XCTAssertNotNil(SpeechLanguage.pinned())
        XCTAssertEqual(SpeechLanguage.pinned(), LanguageManager.shared.current)
    }

    // MARK: - The code that reaches the server

    func testRegionAndScriptAreDroppedFromTheServerCode() {
        XCTAssertEqual(AppLanguage.ptBR.sttServerCode, "pt")
        XCTAssertEqual(AppLanguage.zhHans.sttServerCode, "zh")
        XCTAssertEqual(AppLanguage.zhHant.sttServerCode, "zh")
        XCTAssertEqual(AppLanguage.deAT.sttServerCode, "de")
        XCTAssertEqual(AppLanguage.en.sttServerCode, "en")
        XCTAssertEqual(AppLanguage.ind.sttServerCode, "id")
        XCTAssertEqual(AppLanguage.he.sttServerCode, "he")
    }

    /// Whisper's language table has no Uyghur and every server in that family
    /// validates against it, so naming it loses the recording instead of
    /// producing a guess. Sending nothing leaves the server detecting.
    func testUyghurNamesNoLanguageAtAll() {
        XCTAssertNil(AppLanguage.ug.sttServerCode)
    }

    func testEveryOtherLanguageHasABareLowercaseCode() throws {
        for l in AppLanguage.allCases where l != .ug {
            let code = try XCTUnwrap(l.sttServerCode, l.rawValue)
            XCTAssertFalse(code.contains("-"), l.rawValue)
            XCTAssertEqual(code, code.lowercased(), l.rawValue)
            XCTAssertTrue((2...3).contains(code.count), "\(l.rawValue) → \(code)")
        }
    }

    // MARK: - How it travels

    /// The language rides along with the audio as a plain form field. A
    /// `filename` or a `Content-Type` on this part would make the server's
    /// parser read it as a second file instead of a parameter.
    func testAPlainFieldCarriesNoFilenameAndNoContentType() throws {
        let form = OWMultipart()
        form.append(name: "language", value: "pt")
        let body = try XCTUnwrap(String(data: form.finalized, encoding: .utf8))
        XCTAssertTrue(body.contains("--\(form.boundary)\r\n"
                                    + "Content-Disposition: form-data; name=\"language\"\r\n\r\n"
                                    + "pt\r\n"), body)
        XCTAssertFalse(body.contains("filename"))
        XCTAssertFalse(body.contains("Content-Type:"))
        XCTAssertTrue(body.hasSuffix("--\(form.boundary)--\r\n"))
    }
}
