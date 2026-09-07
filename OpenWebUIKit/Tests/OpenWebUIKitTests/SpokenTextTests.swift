import XCTest
@testable import OpenWebUIKit

/// The arithmetic behind speaking a reply sentence by sentence.
///
/// All of it used to be `private static` inside a `@MainActor` audio class,
/// where none of it could be reached — and every one of these cases is a bug
/// that shipped: "3.5" read as two sentences, a table row recited pipe by pipe,
/// a lone code fence spoken as a backtick.
final class SpokenTextTests: XCTestCase {

    // MARK: - sentenceCut

    /// The whole reason the cut requires whitespace after the terminator.
    func testDecimalNumberIsNotASentenceEnd() {
        XCTAssertNil(SpokenText.sentenceCut(in: "O modelo 3.5 é melhor"))
        XCTAssertNil(SpokenText.sentenceCut(in: "Custa R$ 1.200,00 no total"))
    }

    /// …and it still cuts once the sentence actually ends.
    func testCutsAfterTerminatorFollowedBySpace() {
        let s = "Custa R$ 1.200,00. E o frete?"
        let cut = SpokenText.sentenceCut(in: s)
        XCTAssertEqual(cut, 18)
        XCTAssertEqual(String(s.prefix(cut ?? 0)), "Custa R$ 1.200,00.")
    }

    func testExclamationAndQuestion() {
        XCTAssertEqual(SpokenText.sentenceCut(in: "Claro! Vamos lá"), 6)
        XCTAssertEqual(SpokenText.sentenceCut(in: "Certo? Sim"), 6)
    }

    /// A newline cuts on its own: it cannot be a decimal separator, and
    /// requiring whitespace after it too made single line breaks never cut.
    func testNewlineCutsWithoutTrailingWhitespace() {
        let s = "Primeira linha\nsegunda"
        XCTAssertEqual(SpokenText.sentenceCut(in: s), 15)
    }

    func testCJKTerminators() {
        XCTAssertEqual(SpokenText.sentenceCut(in: "你好。 再见"), 3)
        XCTAssertEqual(SpokenText.sentenceCut(in: "本当！ そう"), 3)
        XCTAssertEqual(SpokenText.sentenceCut(in: "何？ はい"), 2)
    }

    func testEllipsisCharacter() {
        XCTAssertEqual(SpokenText.sentenceCut(in: "Bem… então"), 4)
    }

    func testNoTerminatorAndTooShort() {
        XCTAssertNil(SpokenText.sentenceCut(in: "ainda escrevendo"))
        XCTAssertNil(SpokenText.sentenceCut(in: "."))
        XCTAssertNil(SpokenText.sentenceCut(in: ""))
    }

    /// A terminator at the very end has nothing after it to prove it is one —
    /// the next delta may still be "5". The flush at the end of the stream is
    /// what speaks it.
    func testTrailingTerminatorDoesNotCut() {
        XCTAssertNil(SpokenText.sentenceCut(in: "Pronto."))
    }

    // MARK: - openingCut

    func testOpeningPrefersARealSentence() {
        XCTAssertEqual(SpokenText.openingCut(in: "Oi! Tudo bem"), 3)
    }

    /// Short openings are never chopped — they would sound clipped for nothing.
    func testShortOpeningWaits() {
        XCTAssertNil(SpokenText.openingCut(in: "Uma frase curta, sem fim ainda"))
    }

    /// Past the soft budget the opening may break at a clause, and at the LAST
    /// clause inside the budget rather than the first.
    func testOpeningBreaksAtTheLastClauseInBudget() {
        let s = "Primeiro, isso aqui é um começo bem mais longo do que sessenta caracteres, e segue"
        let cut = SpokenText.openingCut(in: s)
        XCTAssertNotNil(cut)
        XCTAssertGreaterThanOrEqual(cut ?? 0, SpokenText.openingSoft)
        XCTAssertLessThanOrEqual(cut ?? 0, SpokenText.openingHard)
        XCTAssertTrue(String(s.prefix(cut ?? 0)).hasSuffix(","))
    }

    /// No clause break anywhere: only past the hard limit does it split on a
    /// space, so nothing shorter is ever cut mid-thought.
    func testOpeningFallsBackToASpaceOnlyPastTheHardLimit() {
        let long = String(repeating: "palavra ", count: 30)   // 240 chars, no punctuation
        let cut = SpokenText.openingCut(in: long)
        XCTAssertNotNil(cut)
        XCTAssertLessThanOrEqual(cut ?? 0, SpokenText.openingHard)

        let medium = String(repeating: "palavra ", count: 12)  // 96 chars, still under the hard limit
        XCTAssertNil(SpokenText.openingCut(in: medium))
    }

    // MARK: - isSpeakable

    /// A fence arrives as its own chunk while the reply streams, so the closing
    /// half has not been written yet: the fence rule needs both ends, and what
    /// reaches the guard is a stray backtick with no letter in it.
    func testUnclosedCodeFenceIsNotSpeakable() {
        XCTAssertFalse(SpokenText.isSpeakable("```"))
        XCTAssertFalse(SpokenText.isSpeakable("  ```  "))
    }

    /// A complete fence is announced rather than read out.
    func testClosedCodeFenceBecomesAnAnnouncement() {
        XCTAssertEqual(SpokenText.strip("```\nlet x = 1\n```"), "(bloco de código)")
    }

    func testMarkupOnlyChunksAreNotSpeakable() {
        XCTAssertFalse(SpokenText.isSpeakable("---"))
        XCTAssertFalse(SpokenText.isSpeakable("**"))
        XCTAssertFalse(SpokenText.isSpeakable("   \n  "))
    }

    /// A table separator row is pure punctuation and says nothing.
    func testTableSeparatorRowIsNotSpeakable() {
        XCTAssertFalse(SpokenText.isSpeakable("| --- | :---: |"))
    }

    func testOrdinarySentenceIsSpeakable() {
        XCTAssertTrue(SpokenText.isSpeakable("Bom dia."))
        XCTAssertTrue(SpokenText.isSpeakable("42"))
    }

    // MARK: - strip

    func testStripsMarkdownEmphasisHeadingsAndLinks() {
        XCTAssertEqual(SpokenText.strip("**Oi** _mundo_"), "Oi mundo")
        XCTAssertEqual(SpokenText.strip("# Título"), "Título")
        XCTAssertEqual(SpokenText.strip("> citação"), "citação")
        XCTAssertEqual(SpokenText.strip("veja [o site](https://exemplo.com)"), "veja o site")
        XCTAssertEqual(SpokenText.strip("use `ls -la` aqui"), "use ls -la aqui")
    }

    func testStripsThinkBlocks() {
        XCTAssertEqual(SpokenText.strip("<think>raciocínio</think>Resposta"), "Resposta")
    }

    /// A data row is read as its cells, not as pipes.
    func testTableRowIsReadAsAListOfCells() {
        XCTAssertEqual(SpokenText.strip("| Duração | 4 anos | 6 anos |"), "Duração, 4 anos, 6 anos")
    }

    /// The test is the LEADING pipe: an ordinary sentence may hold one in
    /// passing, and shredding it into cells read "roda ls, grep erro".
    func testPipeInsideASentenceIsNotATableRow() {
        XCTAssertEqual(SpokenText.strip("roda ls | grep erro"), "roda ls | grep erro")
    }
}
