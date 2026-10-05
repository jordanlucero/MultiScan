//
//  MarkdownTranscriptConverterTests.swift
//  MultiScanTests
//

import Foundation
import Testing
@testable import MultiScan

@Suite("Markdown transcript converter")
struct MarkdownTranscriptConverterTests {
    @Test func headingsBecomeBoldScaledFonts() throws {
        let text = MarkdownTranscriptConverter.attributedString(fromMarkdown: "# Title\n\nBody text here.")
        #expect(text.string == "Title\nBody text here.")
        let heading = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont)
        let body = try #require(text.attribute(.font, at: 6, effectiveRange: nil) as? PlatformFont)
        #expect(heading.isBold)
        #expect(heading.pointSize > body.pointSize)
        #expect(body.fontName.hasPrefix("HelveticaNeue"))
        #expect(body.pointSize == PageTextStyle.storageFontSize)
    }

    @Test func inlineEmphasisMapsToTraits() throws {
        let text = MarkdownTranscriptConverter.attributedString(fromMarkdown: "Some **bold** and *italic* words.")
        #expect(text.string == "Some bold and italic words.")
        let bold = try #require(text.attribute(.font, at: 5, effectiveRange: nil) as? PlatformFont)
        let italic = try #require(text.attribute(.font, at: 14, effectiveRange: nil) as? PlatformFont)
        #expect(bold.isBold && !bold.isItalic)
        #expect(italic.isItalic && !italic.isBold)
    }

    @Test func listsKeepTheirMarkers() {
        let text = MarkdownTranscriptConverter.attributedString(fromMarkdown: "- one\n- two\n\n1. first\n2. second")
        #expect(text.string == "• one\n• two\n1. first\n2. second")
    }

    @Test func tablesBecomeAttachments() throws {
        let markdown = "Intro\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |\n\nOutro"
        let text = MarkdownTranscriptConverter.attributedString(fromMarkdown: markdown)
        var tables: [TextTableModel] = []
        InlineAttachments.enumerateAttachments(in: text) { attachment, _ in
            if case .table(let table) = InlineAttachments.kind(of: attachment) { tables.append(table) }
        }
        let table = try #require(tables.first)
        #expect(table.columnCount == 2)
        #expect(table.rows.first == ["A", "B"])
        #expect(table.rows.last == ["3", "4"])
        #expect(text.string.hasPrefix("Intro\n"))
        #expect(text.string.hasSuffix("Outro"))
        #expect(InlineAttachments.searchablePlainText(of: text).contains("1\t2"))
    }

    @Test func fencedAnswersAreUnwrappedAndGarbageSurvives() {
        let fenced = "```markdown\n# Hi\n```"
        #expect(MarkdownTranscriptConverter.stripOuterCodeFence(fenced) == "# Hi")
        let text = MarkdownTranscriptConverter.attributedString(fromMarkdown: fenced)
        #expect(text.string == "Hi")
        #expect(MarkdownTranscriptConverter.attributedString(fromMarkdown: "   \n").length == 0)
        // Unbalanced emphasis still yields text, never an empty page.
        #expect(!MarkdownTranscriptConverter.attributedString(fromMarkdown: "**unterminated").string.isEmpty)
    }
}
