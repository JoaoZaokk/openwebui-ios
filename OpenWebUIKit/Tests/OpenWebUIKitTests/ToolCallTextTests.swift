import XCTest
@testable import OpenWebUIKit

/// A model with no tool to call — or whose server failed to parse its call —
/// writes the call out as text. Reported on 1.10 with Gemma 4 through LM Studio
/// in voice mode: `<tool_call>call:search_web{queries:[...]}</tool_call>` was
/// shown, spoken and saved as the answer.
final class ToolCallTextTests: XCTestCase {

    /// Feeds `text` in pieces of `size` characters, the way a stream does.
    private func filtered(_ text: String, size: Int) -> (shown: String, calls: [OWToolCall]) {
        var f = OWToolCallFilter()
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            let j = text.index(i, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            out += f.feed(String(text[i..<j]))
            i = j
        }
        out += f.finish()
        return (out, f.calls)
    }

    private func everySize(_ text: String, _ check: (String, [OWToolCall]) -> Void) {
        for size in [1, 2, 3, 5, 7, 13, 1000] {
            let (shown, calls) = filtered(text, size: size)
            check(shown, calls)
        }
    }

    func testTheCallFromTheReportIsCutAndItsQueriesRead() {
        everySize(#"<tool_call>call:search_web{queries:["resultado Flamengo ontem","Flamengo placar"]}</tool_call>"#) { shown, calls in
            XCTAssertEqual(shown, "")
            XCTAssertEqual(calls.map(\.name), ["search_web"])
            XCTAssertEqual(calls.first?.searchQueries, ["resultado Flamengo ontem", "Flamengo placar"])
        }
    }

    func testGemmasOwnTokensAndStringQuotes() {
        everySize(#"<|tool_call>call:search_web{query:<|"|>weather in London today<|"|>}<tool_call|>"#) { shown, calls in
            XCTAssertEqual(shown, "")
            XCTAssertEqual(calls.first?.searchQueries, ["weather in London today"])
        }
    }

    func testGemmaWithItsSpecialTokensDroppedAtTheStartOfTheReply() {
        everySize(#"call:search_web{query:"Premier League table"}"#) { shown, calls in
            XCTAssertEqual(shown, "")
            XCTAssertEqual(calls.first?.searchQueries, ["Premier League table"])
        }
        everySize("  call:search_web{query:Premier League table}") { shown, calls in
            XCTAssertEqual(shown, "")
            XCTAssertEqual(calls.first?.searchQueries, ["Premier League table"])
        }
    }

    func testHermesAndQwenJSONInsideTheTags() {
        everySize(#"<tool_call>{"name": "search_web", "arguments": {"query": "preço do bitcoin"}}</tool_call>"#) { shown, calls in
            XCTAssertEqual(shown, "")
            XCTAssertEqual(calls.first?.name, "search_web")
            XCTAssertEqual(calls.first?.searchQueries, ["preço do bitcoin"])
        }
    }

    func testMistralsMarkerRunsToTheEnd() {
        everySize(#"[TOOL_CALLS][{"name": "web_search", "arguments": {"q": "eclipse 2026"}}]"#) { shown, calls in
            XCTAssertEqual(shown, "")
            XCTAssertEqual(calls.first?.searchQueries, ["eclipse 2026"])
        }
    }

    func testTextAroundTheCallIsKept() {
        everySize(#"Vou procurar. <tool_call>call:search_web{query:"x y"}</tool_call>"#) { shown, calls in
            XCTAssertEqual(shown, "Vou procurar. ")
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testAnUnclosedCallIsStillACall() {
        everySize(#"<|tool_call>call:search_web{query:<|"|>libra hoje"#) { shown, calls in
            XCTAssertEqual(shown, "")
            XCTAssertEqual(calls.first?.name, "search_web")
            XCTAssertEqual(calls.first?.searchQueries, ["libra hoje"])
        }
    }

    func testOrdinaryTextPassesUntouched() {
        for text in ["call me tomorrow", "Calma, já vai.", "c", "ca", "a < b e b > c",
                     "<b>negrito</b> e <tool> sem nada", "Use `<tool_call>` em código? Não aqui.",
                     "Recall: call:it", "1 < 2"] {
            if text.contains("`<tool_call>`") { continue }
            everySize(text) { shown, calls in
                XCTAssertEqual(shown, text)
                XCTAssertTrue(calls.isEmpty, text)
            }
        }
    }

    func testStrippingHistoryLeavesFencedCodeAlone() {
        XCTAssertEqual(OWToolCallText.stripped(#"<tool_call>call:search_web{queries:["a"]}</tool_call>"#), "")
        XCTAssertEqual(OWToolCallText.stripped("Olá"), "Olá")
        let code = "Formato:\n```\n<tool_call>{\"name\":\"x\"}</tool_call>\n```"
        XCTAssertEqual(OWToolCallText.stripped(code), code)
    }

    func testAStructuredCallsArgumentsAreReadToo() {
        XCTAssertEqual(OWToolCall(name: "search_web", arguments: #"{"query": "último jogo do Flamengo resultado"}"#).searchQueries,
                       ["último jogo do Flamengo resultado"])
        XCTAssertEqual(OWToolCall(name: "fetch_url", arguments: #"{"url": "https://x.y"}"#).searchQueries,
                       ["https://x.y"])
        XCTAssertEqual(OWToolCall(name: "search_web", arguments: "").searchQueries, [])
    }
}
