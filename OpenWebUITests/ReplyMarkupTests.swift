import XCTest
@testable import OpenWebUI

/// Report from 1.10 (zh_CN) and a capture through the owner's server: the web
/// shows a reply's layout tags as layout, the app showed them as text — a
/// `<div style="text-align: center;">` line above the options and `</div>`
/// below — and joined the options (one per line in the reply) into one
/// paragraph, where the web breaks a line at every newline.
final class ReplyMarkupTests: XCTestCase {

    /// As mimo-v2.6-flash wrote it on 2026-10-29.
    private let options = """
    Com base nesse roteiro, me diga o que você prefere:

    <div style="text-align: center;">

    **Qual dos dias você mais gostaria de adaptar?**

    🔘 **Dia 1** - Alfama
    🔘 **Dia 2** - Belém

    </div>
    """

    func testLayoutTagsAreNotShownAsText() {
        let out = ReplyMarkup.clean(options)
        XCTAssertFalse(out.contains("<div"), out)
        XCTAssertFalse(out.contains("</div>"), out)
        XCTAssertTrue(out.contains("🔘 **Dia 1** - Alfama\n🔘 **Dia 2** - Belém"), out)
    }

    func testABreakTagIsANewLine() {
        XCTAssertEqual(ReplyMarkup.clean("um<br>dois<br/>três<br />quatro"), "um\ndois\ntrês\nquatro")
    }

    func testCodeIsLeftAlone() {
        let code = "```html\n<div class=\"x\">oi</div>\n<br>\n```"
        XCTAssertEqual(ReplyMarkup.clean(code), code)
        XCTAssertEqual(ReplyMarkup.clean("use `<div>` aqui"), "use `<div>` aqui")
    }

    func testPlainTextIsUntouched() {
        let text = "## Título\n\n- item\n- outro\n\nTexto com 3 < 5 e 7 > 2."
        XCTAssertEqual(ReplyMarkup.clean(text), text)
    }

    /// As mimo-v2.6-flash wrote a sun icon: bare SVG in the text, which the web
    /// draws and the app printed as XML.
    func testABareSVGBecomesAnSVGBlock() {
        let reply = "## Sol\n\n<svg viewBox=\"0 0 64 64\">\n  <circle cx=\"32\" cy=\"32\" r=\"14\"/>\n</svg>\n\nPronto."
        let out = ReplyMarkup.clean(reply)
        XCTAssertTrue(out.contains("```svg\n<svg viewBox=\"0 0 64 64\">\n  <circle cx=\"32\" cy=\"32\" r=\"14\"/>\n</svg>\n```"), out)
        XCTAssertTrue(out.hasSuffix("Pronto."))
    }

    func testCodeBlocksTheChatDrawsAreRecognised() {
        XCTAssertEqual(RichBlock(language: "mermaid"), .mermaid)
        XCTAssertEqual(RichBlock(language: "SVG"), .svg)
        XCTAssertEqual(RichBlock(language: "html"), .html)
        XCTAssertNil(RichBlock(language: "python"))
        XCTAssertNil(RichBlock(language: nil))
    }

    func testTheMermaidPageIsBundledAndEscapesTheCode() throws {
        XCTAssertNotNil(RichBlock.resourceBase, "mermaid.min.js is not in the app bundle")
        let page = RichBlock.page(.mermaid, code: "graph TD; A-->B<script>", theme: Theme.named("openwebui"))
        XCTAssertTrue(page.contains("A--&gt;B&lt;script&gt;"), "the diagram code must not run as HTML")
        XCTAssertTrue(page.contains("src=\"mermaid.min.js\""))
    }

    /// Mermaid's dark palette drew wine, brown and near-black slices on our dark
    /// themes. Charts take the theme's accent first and stay apart from it.
    func testChartColoursFollowTheTheme() {
        for id in ["openwebui", "claude", "gemini", "hermes", "terminal"] {
            let t = Theme.named(id)
            let p = RichBlock.palette(for: t)
            XCTAssertEqual(p.first, "#" + t.hex.accent.lowercased(), id)
            XCTAssertEqual(Set(p).count, p.count, "\(id): two slices share a colour")
            XCTAssertGreaterThanOrEqual(p.count, 6, id)
        }
        let vars = RichBlock.chartVariables(Theme.named("claude"))
        XCTAssertTrue(vars.contains("\"pieTitleTextColor\":\"#3d3a34\""), vars)
        XCTAssertTrue(vars.contains("\"plotColorPalette\":\"#ba5937"), vars)
    }
}
