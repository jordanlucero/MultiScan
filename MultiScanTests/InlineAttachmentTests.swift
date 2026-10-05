//
//  InlineAttachmentTests.swift
//  MultiScanTests
//
//  Reference attachments, RTFD persistence, and the plain-text mirrors around them.
//

import Foundation
import SwiftData
import Testing
@testable import MultiScan

@Suite("Inline attachments")
struct InlineAttachmentTests {
    let container = Fixtures.container()

    private func textWithCapture(_ id: UUID) -> NSAttributedString {
        let font = PageTextStyle.storageFont
        let text = NSMutableAttributedString(string: "Before\n", attributes: [.font: font])
        text.append(InlineAttachments.attributedString(for: InlineAttachments.makeCaptureAttachment(captureID: id), font: font))
        text.append(NSAttributedString(string: "\nAfter", attributes: [.font: font]))
        return text
    }

    @Test func captureAttachmentsAreRecognized() {
        let id = UUID()
        let attachment = InlineAttachments.makeCaptureAttachment(captureID: id)
        #expect(InlineAttachments.kind(of: attachment) == .capture(id))
        let text = textWithCapture(id)
        #expect(InlineAttachments.captureIDs(in: text) == [id])
        #expect(InlineAttachments.range(ofCapture: id, in: text) == NSRange(location: 7, length: 1))
        #expect(RichTextArchiver.containsAttachments(text))
    }

    @Test func tableAttachmentsCarryTheirModel() throws {
        let table = TextTableModel(rows: [["Name", "Qty"], ["Apples", "3"], ["Pears"]])
        #expect(table.columnCount == 2)
        #expect(table.rows[2] == ["Pears", ""])
        #expect(table.tabSeparatedText == "Name\tQty\nApples\t3\nPears\t")
        #expect(table.markdown.hasPrefix("| Name | Qty |\n| --- | --- |"))
        let attachment = try #require(InlineAttachments.makeTableAttachment(table))
        #expect(InlineAttachments.kind(of: attachment) == .table(table))
    }

    @Test func textWithAttachmentsPersistsAsRTFDAndRoundTrips() throws {
        let id = UUID()
        let text = textWithCapture(id)
        let data = try #require(RichTextArchiver.richTextData(from: text))
        #expect(!RichTextArchiver.isRTF(data))
        // The flattened package decodes with its attachment intact — the kind survives via the file wrapper's name/contents.
        let decoded = RichTextArchiver.attributedString(from: data)
        #expect(decoded.string.strippingAttachmentCharacters() == "Before\n\nAfter")
        #expect(InlineAttachments.captureIDs(in: decoded) == [id])
        // Text-only content still persists as plain RTF.
        let plain = try #require(RichTextArchiver.richTextData(from: NSAttributedString(string: "Hi", attributes: [.font: PageTextStyle.storageFont])))
        #expect(RichTextArchiver.isRTF(plain))
    }

    @Test func plainTextMirrorsIgnoreCapturesAndKeepTables() throws {
        let id = UUID()
        let document = Fixtures.makeProject(texts: ["x"], in: container.mainContext)
        let page = Fixtures.sortedPages(of: document)[0]
        page.attributedText = textWithCapture(id)
        #expect(page.plainText == "Before\n\nAfter")
        #expect(RichTextArchiver.plainText(from: page.richTextData) == "Before\n\nAfter")

        let table = TextTableModel(rows: [["a", "b"]])
        let withTable = NSMutableAttributedString(string: "Intro\n", attributes: [.font: PageTextStyle.storageFont])
        withTable.append(InlineAttachments.attributedString(for: try #require(InlineAttachments.makeTableAttachment(table)), font: PageTextStyle.storageFont))
        #expect(InlineAttachments.searchablePlainText(of: withTable) == "Intro\n\na\tb\n")
        #expect(TextStatistics.wordCount(of: "one \u{FFFC} two") == 2)
        #expect(TextStatistics.characterCount(of: "ab\u{FFFC}c") == 3)
    }

    @Test func cacheEntriesKeepAttachments() throws {
        let id = UUID()
        let document = Fixtures.makeProject(texts: ["x"], in: container.mainContext)
        let page = Fixtures.sortedPages(of: document)[0]
        page.attributedText = textWithCapture(id)
        TextExportCacheService.updateEntry(pageNumber: 1, attributedText: page.attributedText, pageLastModified: page.lastModified, in: document)
        let entry = try #require(TextExportCacheService.loadFreshCache(from: document)?.pages.first)
        #expect(entry.plainText == "Before\n\nAfter")
        let decoded = try #require(entry.decodedText())
        #expect(InlineAttachments.captureIDs(in: decoded) == [id])
    }

    @Test func exportResolvesCapturesToNotesOrImages() async throws {
        let id = UUID()
        let snapshotText = RichTextArchiver.richTextData(from: textWithCapture(id))
        var snapshot = TextExporter.PageSnapshot(pageNumber: 1, fileName: nil, textData: snapshotText, wordCount: nil, charCount: nil)
        snapshot.captures = [TextExporter.CaptureSnapshot(id: id, imageData: nil, isDraft: true, caption: nil, reminder: "Illustration on page 1")]
        snapshot.sectionTitle = "Chapter One"

        var options = ExportOptions.simple(separatePages: false)
        options.includeCaptures = false
        options.includeDraftReminders = true
        let result = await TextExporter.buildResult(from: [snapshot], options: options)
        #expect(result.plainText.hasPrefix("Chapter One\nBefore\n[Illustration]"))
        #expect(result.plainText.contains("rescan"))
        #expect(result.draftReminders == ["Illustration on page 1"])
        #expect(result.rtfdData == nil)
    }

    @Test func controllerInsertsAndRemovesCaptures() throws {
        let document = Fixtures.makeProject(texts: ["Line one"], in: container.mainContext)
        let page = Fixtures.sortedPages(of: document)[0]
        let capture = PageCapture(page: page, imageData: nil, thumbnailData: nil, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.4), pixelSize: CGSize(width: 100, height: 80))
        container.mainContext.insert(capture)
        page.captures?.append(capture)
        let id = try #require(capture.uuid)

        let controller = PageTextController(page: page)
        controller.insertCapture(capture)
        #expect(InlineAttachments.captureIDs(in: page.attributedText) == [id])
        // The image sits on its own paragraph; the mirror keeps the paragraph break but not the placeholder.
        #expect(page.plainText == "Line one\n")
        #expect(page.attributedText.string.hasPrefix("Line one\n"))

        controller.removeCapture(id)
        #expect(InlineAttachments.captureIDs(in: page.attributedText).isEmpty)
        #expect(page.attributedText.string == "Line one")
        #expect(page.unwrappedCaptures.isEmpty)
    }
}
