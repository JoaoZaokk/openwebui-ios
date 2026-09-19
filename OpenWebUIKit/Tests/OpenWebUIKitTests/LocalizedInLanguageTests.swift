import XCTest
@testable import OpenWebUIKit

/// `L(_:)` answers in the interface language, which is the right answer for
/// everything the user reads. It is the wrong answer for the one string the app
/// sends to the *model*: the voice companion's system prompt has to name the
/// language the user is speaking, and that is a separate setting — a Japanese
/// interface dictating in English is a pairing this app supports on purpose.
///
/// So a lookup has to be possible in a named language, which means resolving a
/// catalogue other than the active one.
final class LocalizedInLanguageTests: XCTestCase {

    private let key = "Mensagem…"
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ow-catalogue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testACatalogueCanBeResolvedByLanguage() throws {
        let container = try bundle(["en": "Message…", "ja": "メッセージ…"])

        let japanese = try XCTUnwrap(LanguageManager.catalogue(for: .ja, in: container))
        XCTAssertEqual(japanese.localizedString(forKey: key, value: key, table: nil), "メッセージ…")

        let english = try XCTUnwrap(LanguageManager.catalogue(for: .en, in: container))
        XCTAssertEqual(english.localizedString(forKey: key, value: key, table: nil), "Message…")
    }

    /// A language the container ships nothing for is reported, not faked — the
    /// caller decides what to fall back to.
    func testAMissingCatalogueIsNil() throws {
        let container = try bundle(["en": "Message…"])
        XCTAssertNil(LanguageManager.catalogue(for: .th, in: container))
    }

    // MARK: - Fixtures

    private func bundle(_ catalogues: [String: String]) throws -> Bundle {
        let root = scratch.appendingPathComponent("Probe.bundle")
        for (language, translation) in catalogues {
            let dir = root.appendingPathComponent("\(language).lproj")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "\"\(key)\" = \"\(translation)\";\n"
                .write(to: dir.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        }
        return try XCTUnwrap(Bundle(url: root))
    }
}
