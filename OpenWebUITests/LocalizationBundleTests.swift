import XCTest
import OpenWebUIKit
@testable import OpenWebUI

/// The catalogues only exist for the app if they reach the app *bundle*. They
/// get there as variant groups the project generator builds out of the `.lproj`
/// folders, which is machinery no one looks at until a language goes silently
/// Portuguese.
///
/// `LocalizationCatalogTests` in the kit guards the other half — that every
/// literal the app draws has an entry to find here.
final class LocalizationBundleTests: XCTestCase {

    private func bundle() -> Bundle { Bundle(for: AppState.self) }

    func testEveryShippedLanguageHasACatalogueInTheBundle() throws {
        for language in AppLanguage.allCases {
            let lproj = bundle().path(forResource: language.rawValue, ofType: "lproj")
            let path = try XCTUnwrap(lproj, "\(language.rawValue).lproj never reached the app bundle")
            XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/Localizable.strings"),
                          "\(language.rawValue).lproj has no Localizable.strings")
        }
    }

    /// The composer prompt shipped in 1.8 with no entry in any catalogue, so it
    /// drew "Mensagem…" in all 44 languages — the App Store review that read
    /// "the language keeps defaulting back to Portuguese".
    func testTheComposerPlaceholderIsTranslated() throws {
        let key = "Mensagem…"
        for (language, expected) in ["en": "Message…", "ja": "メッセージ…", "de": "Nachricht…"] {
            let path = try XCTUnwrap(bundle().path(forResource: language, ofType: "lproj"))
            let catalogue = try XCTUnwrap(Bundle(path: path))
            XCTAssertEqual(catalogue.localizedString(forKey: key, value: nil, table: nil), expected)
        }
    }

    /// `L(_:)` reads the language the picker chose, from any thread.
    func testLFollowsTheSelectedLanguage() {
        let original = LanguageManager.shared.override
        defer { LanguageManager.shared.set(original) }

        LanguageManager.shared.set(.en)
        XCTAssertEqual(L("Mensagem…"), "Message…")
        LanguageManager.shared.set(.ja)
        XCTAssertEqual(L("Mensagem…"), "メッセージ…")
    }
}
