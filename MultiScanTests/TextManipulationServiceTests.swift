//
//  TextManipulationServiceTests.swift
//  MultiScanTests
//

import Foundation
import Testing
@testable import MultiScan

@Suite("Text normalization and parsing")
struct TextParsingTests {
    @Test func normalizeLowercasesCollapsesAndMapsPunctuation() {
        #expect(TextManipulationService.normalize("  Chapter — One  “Quoted”  ") == "chapter - one \"quoted\"")
        #expect(TextManipulationService.normalize("It’s") == "it's")
        #expect(TextManipulationService.normalize("") == "")
    }

    @Test(arguments: [
        ("42", 42), ("1,234", 1234), ("9,999", 9999), ("7", 7)
    ])
    func parsesNumericTokens(token: String, expected: Int) {
        #expect(TextManipulationService.parseNumericToken(token) == expected)
    }

    @Test(arguments: ["100000", "12,3,", ",123", "1,,2", "abc", "", "12a"])
    func rejectsInvalidNumericTokens(token: String) {
        #expect(TextManipulationService.parseNumericToken(token) == nil)
    }

    @Test func extractsPageNumberPatterns() {
        #expect(TextManipulationService.extractPageNumber(from: "42")?.number == 42)
        #expect(TextManipulationService.extractPageNumber(from: "Page 42.")?.numberText == "42")
        #expect(TextManipulationService.extractPageNumber(from: "p. 7")?.number == 7)
        #expect(TextManipulationService.extractPageNumber(from: "- 12 -")?.number == 12)
        #expect(TextManipulationService.extractPageNumber(from: "Chapter 1") == nil)
        #expect(TextManipulationService.extractPageNumber(from: "pencil") == nil)
    }

    @Test func decomposesHeaderLines() {
        let trailing = TextManipulationService.decomposeHeaderLine("chapter 1 of 3 42")
        #expect(trailing.coreText == "chapter 1 of 3")
        #expect(trailing.pageNumber == 42)

        let leading = TextManipulationService.decomposeHeaderLine("42 chapter one")
        #expect(leading.coreText == "chapter one")
        #expect(leading.pageNumber == 42)

        let numberOnly = TextManipulationService.decomposeHeaderLine("42")
        #expect(numberOnly.coreText == "")
        #expect(numberOnly.pageNumber == 42)

        let plain = TextManipulationService.decomposeHeaderLine("hello world")
        #expect(plain.coreText == "hello world")
        #expect(plain.pageNumber == nil)
    }

    @Test func ocrNormalizationAndEditDistance() {
        #expect(TextManipulationService.ocrNormalize("l0st 1n") == "lost ln")
        #expect(TextManipulationService.editDistance("kitten", "sitting") == 3)
        #expect(TextManipulationService.editDistance("", "abc") == 3)
        #expect(TextManipulationService.editDistance("same", "same") == 0)
    }

    @Test func detectsPageNumberOnMixedLine() throws {
        let detection = try #require(TextManipulationService.detectPageNumber(in: "Chapter 1    42", position: .firstLine, pageNumber: 3))
        #expect(detection.detectedNumber == 42)
        #expect(detection.numberText == "42")
        #expect(detection.lineText == "Chapter 1    42")
        #expect(detection.normalizedLine == "chapter 1 42")
        #expect(detection.pageNumber == 3)
        #expect(detection.position == .firstLine)

        #expect(TextManipulationService.detectPageNumber(in: "Just prose", position: .lastLine, pageNumber: 1) == nil)
    }

    @Test func wordCount() {
        #expect(TextStatistics.wordCount(of: "one two  three\nfour") == 4)
        #expect(TextStatistics.wordCount(of: "") == 0)
    }
}

@Suite("Text removal")
struct TextRemovalTests {
    private func mutable(_ string: String) -> NSMutableAttributedString {
        NSMutableAttributedString(string: string)
    }

    @Test func replaceLineBreaksHandlesEveryLineEnding() {
        let text = mutable("a\r\nb\nc\rd")
        TextManipulationService.replaceLineBreaks(in: text)
        #expect(text.string == "a b c d")
        #expect(TextManipulationService.removingLineBreaks(from: NSAttributedString(string: "x\ny")).string == "x y")
    }

    @Test func removingTokenFromMixedLineKeepsTheRest() {
        let text = mutable("Chapter 1    42")
        TextManipulationService.removePageNumberToken("42", in: text)
        #expect(text.string == "Chapter 1")
    }

    @Test func removingStandaloneTokenCollapsesItsLine() {
        let first = mutable("42\nBody text")
        TextManipulationService.removePageNumberToken("42", in: first)
        #expect(first.string == "Body text")

        let last = mutable("Body text\n42")
        TextManipulationService.removePageNumberToken("42", in: last)
        #expect(last.string == "Body text")
    }

    @Test func tokenMatchingIsStandaloneOnly() {
        let text = mutable("42 items\n4")
        TextManipulationService.removePageNumberToken("4", in: text)
        #expect(text.string == "42 items")

        let untouched = mutable("hello")
        TextManipulationService.removePageNumberToken("99", in: untouched)
        #expect(untouched.string == "hello")
    }

    @Test func removalPreservesSurroundingFormatting() {
        let text = NSMutableAttributedString(string: "Bold", attributes: [.font: PageTextStyle.storageFont.applyingTraits(bold: true, italic: false)])
        text.append(NSAttributedString(string: "\n42"))
        TextManipulationService.removePageNumberToken("42", in: text)
        #expect(text.string == "Bold")
        let font = text.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont
        #expect(font?.isBold == true)
    }

    @Test func removesExactLine() {
        let text = mutable("Chapter One\nBody\nMore")
        TextManipulationService.removeLine(matching: "chapter one", in: text)
        #expect(text.string == "Body\nMore")
    }

    @Test func removesFuzzyHeaderLineWithTrailingNumber() {
        let text = mutable("Body\nRile in the Rain 42\nEnd")
        TextManipulationService.removeLine(matching: "rite in the rain", in: text, stripNumbers: true)
        #expect(text.string == "Body\nEnd")
    }

    @Test func removingLastLineTakesPrecedingNewline() {
        let text = mutable("Body\nFooter")
        TextManipulationService.removeLine(matching: "footer", in: text)
        #expect(text.string == "Body")
    }
}

@Suite("Smart Cleanup analysis")
struct SmartCleanupAnalysisTests {
    private func cache(_ texts: [String]) -> TextExportCache {
        TextExportCache(pages: texts.enumerated().map { index, text in
            PageCacheEntry(pageNumber: index + 1, fileName: nil, attributedText: NSAttributedString(string: text), pageLastModified: nil)
        })
    }

    @Test func detectsPageNumbersAndRepeatedHeaders() {
        let result = TextManipulationService.analyzeForSmartCleanup(cache: cache([
            "1\nThe Rite in the Rain\nSome body text here.\nMore text.",
            "2\nThe Rite in the Rain\nOther body text.\nEven more.",
            "3\nThe Rite in the Rain\nFinal body.\nThe end."
        ]))

        #expect(result.totalPages == 3)
        #expect(result.pageNumbers.count == 3)
        #expect(result.pageNumbers.allSatisfy { $0.position == .firstLine })
        #expect(result.pageNumbers.map(\.detectedNumber) == [1, 2, 3])

        #expect(result.sectionHeaders.count == 1)
        let header = result.sectionHeaders[0]
        #expect(header.headerText == "the rite in the rain")
        #expect(header.displayText == "The Rite in the Rain")
        #expect(header.pageRange == 1...3)
        #expect(header.affectedPages == [1, 2, 3])

        #expect(result.consecutiveNumbers.isEmpty)
    }

    @Test func buildsOptionsForAPage() {
        let result = TextManipulationService.analyzeForSmartCleanup(cache: cache([
            "1\nThe Rite in the Rain\nSome body text here.\nMore text.",
            "2\nThe Rite in the Rain\nOther body text.\nEven more.",
            "3\nThe Rite in the Rain\nFinal body.\nThe end."
        ]))
        let options = TextManipulationService.buildOptions(from: result, forPageNumber: 2)

        #expect(options.count == 4)
        guard case .removePageNumber(let detection) = options[0] else { Issue.record("expected page number option first"); return }
        #expect(detection.pageNumber == 2)
        guard case .removeSectionHeaderFromPage(_, let pageNumber) = options[1] else { Issue.record("expected per-page header option"); return }
        #expect(pageNumber == 2)
        guard case .removeSectionHeaderFromRange = options[2] else { Issue.record("expected range header option"); return }
        guard case .removeAllPageNumbers = options[3] else { Issue.record("expected document-wide option"); return }
        #expect(Set(options.map(\.id)).count == options.count)
    }

    @Test func detectsConsecutiveNumbersAcrossAdjacentPages() {
        let result = TextManipulationService.analyzeForSmartCleanup(cache: cache([
            "Title\nfoo 101 bar\nmid\nEnd",
            "Title\nbaz 102\nmid\nEnd",
            "Title\n103 qux\nmid\nEnd"
        ]))

        #expect(result.consecutiveNumbers.count == 1)
        let group = result.consecutiveNumbers[0]
        #expect(group.numbers == [101, 102, 103])
        #expect(group.pageRange == 1...3)
        #expect(group.pageMapping[1] == ["101"])
        #expect(group.pageMapping[2] == ["102"])
        #expect(group.pageMapping[3] == ["103"])
    }

    @Test func emptyCacheYieldsNothing() {
        let result = TextManipulationService.analyzeForSmartCleanup(cache: TextExportCache())
        #expect(result.isEmpty)
        #expect(TextManipulationService.buildOptions(from: result, forPageNumber: 1).isEmpty)
    }
}
