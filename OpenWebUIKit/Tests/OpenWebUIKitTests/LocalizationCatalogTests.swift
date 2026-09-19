import XCTest
@testable import OpenWebUIKit

/// The catalogues are the delivery mechanism for every language the app ships.
/// A literal that never made it into `pt-BR.lproj` is not "untranslated" — it is
/// *Portuguese*, in all 44 languages, forever, and nothing in the build says so.
/// That is how the composer placeholder shipped: an App Store review read
/// "the language keeps defaulting back to Portuguese. Even with English selected".
///
/// The seam is the pair (what the app asks for, what the catalogues answer):
/// the literals sitting in a localized position in `App/**/*.swift` versus the
/// keys in `App/Resources/*.lproj/Localizable.strings`. Verified against
/// `xcodebuild -exportLocalizations SWIFT_EMIT_LOC_STRINGS=YES`, which harvests
/// the same set.
final class LocalizationCatalogTests: XCTestCase {

    // MARK: - The app's strings

    /// Literals Xcode would extract that are deliberately not translated:
    /// product names, a stamp drawn as a glyph, example URLs and a model id.
    private static let notTranslated: Set<String> = [
        "Open WebUI", "Google Drive", "OI", "mimo-v2.5-pro",
        "http://localhost:3000", "https://…", "https://…/ggml-modelo.bin",
    ]

    func testEveryLocalizedLiteralInTheAppHasACatalogueEntry() throws {
        let keys = try catalogue(for: "pt-BR")
        var orphans: [String: String] = [:]      // literal → first site
        for file in try swiftSources() + kitSources() {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (literal, line) in localizedLiterals(in: source) {
                guard !Self.notTranslated.contains(literal), !keys.contains(literal) else { continue }
                orphans[literal] = orphans[literal] ?? "\(file.lastPathComponent):\(line)"
            }
        }
        XCTAssertTrue(orphans.isEmpty, "literals with no catalogue entry — they render in Portuguese in every language:\n"
                      + orphans.sorted { $0.key < $1.key }.map { "  \($0.value): \"\($0.key)\"" }.joined(separator: "\n"))
    }

    // MARK: - The catalogues themselves

    func testEveryLanguageCarriesTheSameKeys() throws {
        let base = try catalogue(for: "pt-BR")
        for lang in try languages() where lang != "pt-BR" {
            let keys = try catalogue(for: lang)
            XCTAssertTrue(base.subtracting(keys).isEmpty,
                          "\(lang) is missing \(base.subtracting(keys).count) key(s), e.g. \"\(base.subtracting(keys).sorted().first ?? "")\"")
            XCTAssertTrue(keys.subtracting(base).isEmpty,
                          "\(lang) has \(keys.subtracting(base).count) key(s) the base does not, e.g. \"\(keys.subtracting(base).sorted().first ?? "")\"")
        }
    }

    /// A translation with fewer `%@`/`%lld` than its key crashes `String(format:)`
    /// at the call site, in that language only.
    func testPlaceholderCountsMatchTheBaseLanguage() throws {
        let base = try entries(for: "pt-BR")
        for lang in try languages() where lang != "pt-BR" {
            for (key, value) in try entries(for: lang) {
                guard let expected = base[key] else { continue }
                XCTAssertEqual(placeholders(in: value), placeholders(in: expected),
                               "\(lang): \"\(key)\" has \(placeholders(in: value)) placeholder(s), the base has \(placeholders(in: expected))")
            }
        }
    }

    // MARK: - Harvesting

    /// The literal positions Xcode treats as `LocalizedStringKey`, plus `L(_:)`.
    private static let callSites = try! NSRegularExpression(pattern:
        #"(?:\bText|\bTextField|\bSecureField|\bButton|\bLabel|\bToggle|\bPicker|\bSection|\bLink|\bL|\bLocalizedStringKey|\.navigationTitle|\.alert|\.confirmationDialog|\.help)\(\s*"((?:[^"\\]|\\.)+)""#)
    private static let verbatim = try! NSRegularExpression(pattern: #"\b(?:Text|Label)\(\s*verbatim:"#)
    /// `var inputPrompt: LocalizedStringKey { … }` — the literals are in the body,
    /// far from any call site, which is exactly how the placeholder went unnoticed.
    private static let keyTyped = try! NSRegularExpression(pattern: #"(?:var|func)[^\n]*LocalizedStringKey[^\n]*\{"#)
    private static let anyLiteral = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)+)""#)

    func localizedLiterals(in source: String) -> [(String, Int)] {
        var out: [(String, Int)] = []
        for (i, raw) in source.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("//") else { continue }
            // `Text(verbatim:)` is the explicit opt-out; drop the call, keep the rest.
            let scanned = Self.verbatim.stringByReplacingMatches(
                in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
            for literal in Self.callSites.captures(in: scanned) where !literal.contains("\\(") {
                out.append((literal, i + 1))
            }
        }
        for body in bodiesOfKeyTypedDeclarations(in: source) {
            for literal in Self.anyLiteral.captures(in: body) where !literal.contains("\\(") {
                out.append((literal, 0))
            }
        }
        return out
    }

    private func bodiesOfKeyTypedDeclarations(in source: String) -> [String] {
        let chars = Array(source)
        let range = NSRange(source.startIndex..., in: source)
        return Self.keyTyped.matches(in: source, range: range).compactMap { match in
            guard let open = Range(match.range, in: source).map({ source.distance(from: source.startIndex, to: $0.upperBound) - 1 }) else { return nil }
            var depth = 0
            var i = open
            while i < chars.count {
                if chars[i] == "{" { depth += 1 }
                if chars[i] == "}" { depth -= 1; if depth == 0 { return String(chars[open...i]) } }
                i += 1
            }
            return nil
        }
    }

    // MARK: - Files

    /// `<repo>/OpenWebUIKit/Tests/OpenWebUIKitTests/<this file>`
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func resources() throws -> URL {
        let dir = Self.repo.appendingPathComponent("App/Resources")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw XCTSkip("the app sources are not next to the package — nothing to lint")
        }
        return dir
    }

    private func languages() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: try resources().path)
            .filter { $0.hasSuffix(".lproj") }
            .map { String($0.dropLast(6)) }
            .sorted()
    }

    private func swiftSources() throws -> [URL] { sources(under: "App") }

    /// The kit calls `L(_:)` too — its keys live in the app's catalogues like
    /// every other, and drift the same way.
    private func kitSources() throws -> [URL] { sources(under: "OpenWebUIKit/Sources") }

    private func sources(under path: String) -> [URL] {
        let root = Self.repo.appendingPathComponent(path)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    private func entries(for language: String) throws -> [String: String] {
        let url = try resources().appendingPathComponent("\(language).lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        let line = try NSRegularExpression(pattern: #"^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;"#, options: .anchorsMatchLines)
        var out: [String: String] = [:]
        for match in line.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let k = Range(match.range(at: 1), in: text), let v = Range(match.range(at: 2), in: text) else { continue }
            out[String(text[k])] = String(text[v])
        }
        return out
    }

    private func catalogue(for language: String) throws -> Set<String> { Set(try entries(for: language).keys) }

    private func placeholders(in s: String) -> Int {
        var count = 0
        var chars = Array(s)[...]
        while let i = chars.firstIndex(of: "%") {
            let next = chars.index(after: i)
            guard next < chars.endIndex else { break }
            if chars[next] != "%" { count += 1 }
            chars = chars[chars.index(after: next)...]
        }
        return count
    }
}

private extension NSRegularExpression {
    func captures(in s: String) -> [String] {
        matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            guard m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
            return String(s[r])
        }
    }
}
