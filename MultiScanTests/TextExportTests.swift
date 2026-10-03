//
//  TextExportTests.swift
//  MultiScanTests
//
//  The export cache (structure, freshness, mutation helpers) and the exporter that consumes it.
//

import Foundation
import SwiftData
import Testing
@testable import MultiScan

@Suite("Export cache")
struct TextExportCacheTests {
    let container = Fixtures.container()

    @Test func entryPrecomputesStatistics() {
        let page = Page(pageNumber: 1, text: "one two three", imageData: nil, originalFileName: "a.jpg")
        let entry = PageCacheEntry(from: page)
        #expect(entry.pageNumber == 1)
        #expect(entry.fileName == "a.jpg")
        #expect(entry.plainText == "one two three")
        #expect(entry.wordCount == 3)
        #expect(entry.charCount == 13)
        #expect(!entry.rtfData.isEmpty)
        #expect(entry.pageLastModified == page.lastModified)
        #expect(entry.decodedText()?.string == "one two three")

        let renumbered = entry.renumbered(to: 7)
        #expect(renumbered.pageNumber == 7)
        #expect(renumbered.rtfData == entry.rtfData)
        #expect(renumbered.pageLastModified == entry.pageLastModified)
    }

    @Test func decodeRejectsOtherVersionsAndGarbage() throws {
        var cache = TextExportCache(pages: [
            PageCacheEntry(pageNumber: 1, fileName: nil, attributedText: NSAttributedString(string: "x"), pageLastModified: nil)
        ])
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary

        let current = try encoder.encode(cache)
        #expect(TextExportCacheService.decodeCache(from: current)?.pages.count == 1)

        cache.version = 1
        let outdated = try encoder.encode(cache)
        #expect(TextExportCacheService.decodeCache(from: outdated) == nil)
        #expect(TextExportCacheService.decodeCache(from: Data("nope".utf8)) == nil)
    }

    @Test func freshnessTracksPageModificationDates() throws {
        let document = Fixtures.makeProject(texts: ["A", "B"], in: container.mainContext)
        let cache = try #require(TextExportCacheService.loadCache(from: document))
        #expect(TextExportCacheService.isFresh(cache, against: TextExportCacheService.fingerprints(of: document)))

        // A write that bypassed the cache (another device, via CloudKit) leaves the entry's fingerprint behind
        Fixtures.sortedPages(of: document)[1].lastModified = Date().addingTimeInterval(5)
        #expect(!TextExportCacheService.isFresh(cache, against: TextExportCacheService.fingerprints(of: document)))
        #expect(TextExportCacheService.loadFreshCache(from: document) == nil)

        let rebuilt = try #require(TextExportCacheService.loadFreshCache(from: document, rebuildIfStale: true))
        #expect(TextExportCacheService.isFresh(rebuilt, against: TextExportCacheService.fingerprints(of: document)))
    }

    @Test func unverifiableEntriesAreAcceptedAndCountMismatchIsNot() {
        let entry = PageCacheEntry(pageNumber: 1, fileName: nil, attributedText: NSAttributedString(string: "x"), pageLastModified: nil)
        let cache = TextExportCache(pages: [entry])
        #expect(TextExportCacheService.isFresh(cache, against: [1: Date()]))
        #expect(!TextExportCacheService.isFresh(cache, against: [1: Date(), 2: Date()]))
        #expect(!TextExportCacheService.isFresh(cache, against: [2: Date()]))
    }

    @Test func updateEntryReplacesTextAndKeepsFileName() throws {
        let document = Fixtures.makeProject(texts: ["A", "B", "C"], in: container.mainContext)
        let page = Fixtures.sortedPages(of: document)[1]
        let newText = NSAttributedString(string: "B changed", attributes: [.font: PageTextStyle.storageFont])
        page.attributedText = newText

        TextExportCacheService.updateEntry(pageNumber: 2, attributedText: newText, pageLastModified: page.lastModified, in: document)

        let cache = try #require(TextExportCacheService.loadFreshCache(from: document))
        let entry = try #require(cache.pages.first { $0.pageNumber == 2 })
        #expect(entry.plainText == "B changed")
        #expect(entry.fileName == "page-2.jpg")
        #expect(entry.wordCount == 2)
    }

    @Test func removeEntryRenumbersTheRest() throws {
        let document = Fixtures.makeProject(texts: ["A", "B", "C"], in: container.mainContext)
        TextExportCacheService.removeEntry(pageNumber: 2, from: document)

        let cache = try #require(TextExportCacheService.loadCache(from: document))
        #expect(cache.pages.map(\.pageNumber) == [1, 2])
        #expect(cache.pages.map(\.plainText) == ["A", "C"])
    }

    @Test func insertEntriesShiftsLaterPages() throws {
        let document = Fixtures.makeProject(texts: ["A", "B", "C"], in: container.mainContext)
        let inserted = Page(pageNumber: 2, text: "inserted", imageData: nil)
        TextExportCacheService.insertEntries(for: [inserted], in: document, shiftingFrom: 2, by: 1)

        let cache = try #require(TextExportCacheService.loadCache(from: document))
        #expect(cache.pages.map(\.pageNumber) == [1, 2, 3, 4])
        #expect(cache.pages.map(\.plainText) == ["A", "inserted", "B", "C"])
    }

    @Test func addEntriesAppends() throws {
        let document = Fixtures.makeProject(texts: ["A"], in: container.mainContext)
        TextExportCacheService.addEntries(for: [Page(pageNumber: 2, text: "B", imageData: nil)], to: document)
        let cache = try #require(TextExportCacheService.loadCache(from: document))
        #expect(cache.pages.map(\.plainText) == ["A", "B"])
    }

    @Test func renumberEntriesAppliesMapping() throws {
        let document = Fixtures.makeProject(texts: ["A", "B", "C"], in: container.mainContext)
        TextExportCacheService.renumberEntries([1: 3, 3: 1], in: document)
        let cache = try #require(TextExportCacheService.loadCache(from: document))
        #expect(cache.pages.map(\.pageNumber) == [1, 2, 3])
        #expect(cache.pages.map(\.plainText) == ["C", "B", "A"])
    }
}

@Suite("Text exporter")
struct TextExporterTests {
    let container = Fixtures.container()

    private func snapshots(_ texts: [String]) -> [TextExporter.PageSnapshot] {
        texts.enumerated().map { index, text in
            TextExporter.PageSnapshot(
                pageNumber: index + 1,
                fileName: "page-\(index + 1).jpg",
                textData: RichTextArchiver.rtfData(from: NSAttributedString(string: text)),
                wordCount: nil,
                charCount: nil
            )
        }
    }

    @Test func inlineExportJoinsPagesWithASpace() async {
        let result = await TextExporter.buildResult(from: snapshots(["Alpha", "Beta"]), options: .simple(separatePages: false))
        #expect(result.plainText == "Alpha Beta")
        #expect(result.attributedText.string == "Alpha Beta")
        #expect(result.rtfData.map(RichTextArchiver.isRTF) == true)
    }

    @Test func lineBreakSeparatorCarriesPageNumbers() async {
        let result = await TextExporter.buildResult(from: snapshots(["Alpha", "Beta"]), options: .simple(separatePages: true))
        // "[Page 1 of 2]\nAlpha\n\n[Page 2 of 2]\nBeta" (the label is localized)
        #expect(result.plainText.hasPrefix("["))
        #expect(result.plainText.contains("]\nAlpha\n\n["))
        #expect(result.plainText.hasSuffix("]\nBeta"))
    }

    @Test func lineBreakWithoutMetadataLeavesTheFirstPageAlone() async {
        let options = ExportOptions(createVisualSeparation: true, separatorStyle: .lineBreak, includePageNumber: false, includeFilename: false, includeStatistics: false)
        let result = await TextExporter.buildResult(from: snapshots(["Alpha", "Beta"]), options: options)
        #expect(result.plainText == "Alpha\n\n\nBeta")
    }

    @Test func hyphenatedDividerIncludesFilenameAndStatistics() async {
        let options = ExportOptions(createVisualSeparation: true, separatorStyle: .hyphenatedDivider, includePageNumber: false, includeFilename: true, includeStatistics: true)
        let result = await TextExporter.buildResult(from: snapshots(["Alpha beta", "Gamma"]), options: options)
        let divider = String(repeating: "-", count: 40)
        #expect(result.plainText.hasPrefix(divider + "\npage-1.jpg | "))
        #expect(result.plainText.contains("Alpha beta\n\n" + divider + "\npage-2.jpg | "))
        #expect(result.plainText.hasSuffix("\nGamma"))
    }

    @Test func emptyInputProducesEmptyResult() async {
        let result = await TextExporter.buildResult(from: [], options: .simple(separatePages: true))
        #expect(result.plainText.isEmpty)
        #expect(result.attributedText.length == 0)
    }

    @Test func exportReadsTheCacheForADocument() async throws {
        let document = Fixtures.makeProject(texts: ["Alpha", "Beta"], in: container.mainContext)
        let fromCache = TextExporter.snapshots(for: document)
        #expect(fromCache.map(\.wordCount) == [1, 1]) // statistics only come from the cache path

        let result = await TextExporter.export(document, options: .simple(separatePages: false))
        #expect(result.plainText == "Alpha Beta")

        // A stale cache falls back to the pages themselves
        Fixtures.sortedPages(of: document)[0].lastModified = Date().addingTimeInterval(5)
        let fallback = TextExporter.snapshots(for: document)
        #expect(fallback.map(\.wordCount) == [nil, nil])
        let fallbackResult = await TextExporter.export(document, options: .simple(separatePages: false))
        #expect(fallbackResult.plainText == "Alpha Beta")
    }
}
