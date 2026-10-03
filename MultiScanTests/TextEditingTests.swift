//
//  TextEditingTests.swift
//  MultiScanTests
//
//  PageTextController without a text view (programmatic edits still land in the model) and SmartCleanupModel's model-side edits.
//

import Foundation
import SwiftData
import Testing
@testable import MultiScan

@Suite("Page text controller")
struct PageTextControllerTests {
    let container = Fixtures.container()

    @Test func programmaticEditsSaveToThePageAndCache() {
        let document = Fixtures.makeProject(texts: ["Line one\nLine two"], in: container.mainContext)
        let page = Fixtures.sortedPages(of: document)[0]
        let controller = PageTextController(page: page)
        #expect(controller.wordCount == 4)
        #expect(controller.charCount == 17)
        #expect(controller.plainText == "Line one\nLine two")

        controller.removeLineBreaks()

        #expect(!controller.hasUnsavedChanges)
        #expect(page.plainText == "Line one Line two")
        #expect(page.attributedText.string == "Line one Line two")
        #expect(controller.attributedTextForExport.string == "Line one Line two")
        #expect(TextExportCacheService.loadFreshCache(from: document)?.pages.first?.plainText == "Line one Line two")
    }

    @Test func removingTokensAndLinesGoesThroughPerformEdit() {
        let document = Fixtures.makeProject(texts: ["42\nChapter One\nBody"], in: container.mainContext)
        let page = Fixtures.sortedPages(of: document)[0]
        let controller = PageTextController(page: page)

        controller.removePageNumberTokens(["42"], actionName: "Remove Page Number")
        #expect(page.plainText == "Chapter One\nBody")

        controller.removeLine(matching: "chapter one", stripNumbers: true, actionName: "Remove Header")
        #expect(page.plainText == "Body")

        // No-op edits don't dirty the page
        let before = page.lastModified
        controller.removePageNumberTokens(["99"], actionName: "Nothing")
        #expect(page.lastModified == before)
    }

    @Test func savedTextUsesTheStorageFont() {
        let document = Fixtures.makeProject(texts: ["Plain"], in: container.mainContext)
        let page = Fixtures.sortedPages(of: document)[0]
        let controller = PageTextController(page: page)
        controller.removeLineBreaks() // no change → nothing saved
        #expect(!controller.hasUnsavedChanges)

        let font = page.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont
        #expect(font?.fontName.hasPrefix("HelveticaNeue") == true)
    }
}

@Suite("Smart Cleanup edits")
struct SmartCleanupModelTests {
    let container = Fixtures.container()

    private let texts = [
        "1\nHeader\nBody one\nEnd one",
        "2\nHeader\nBody two\nEnd two",
        "3\nHeader\nBody three\nEnd three"
    ]

    @Test func removingAPageNumberFromAnotherPageEditsTheModel() async throws {
        let document = Fixtures.makeProject(texts: texts, in: container.mainContext)
        let model = SmartCleanupModel(document: document)
        let detection = try #require(TextManipulationService.detectPageNumber(in: "2", position: .firstLine, pageNumber: 2))

        let needsReload = model.apply(.removePageNumber(detection: detection), currentPageNumber: 1, liveController: nil)
        try await Task.sleep(for: .milliseconds(100))

        #expect(!needsReload)
        let pages = Fixtures.sortedPages(of: document)
        #expect(pages[1].plainText == "Header\nBody two\nEnd two")
        #expect(pages[0].plainText == texts[0])
        #expect(TextExportCacheService.loadFreshCache(from: document)?.pages[1].plainText == "Header\nBody two\nEnd two")
    }

    @Test func editingTheCurrentPageWithoutALiveEditorRequestsAReload() async throws {
        let document = Fixtures.makeProject(texts: texts, in: container.mainContext)
        let model = SmartCleanupModel(document: document)
        let detection = try #require(TextManipulationService.detectPageNumber(in: "2", position: .firstLine, pageNumber: 2))

        let needsReload = model.apply(.removePageNumber(detection: detection), currentPageNumber: 2, liveController: nil)
        try await Task.sleep(for: .milliseconds(100))

        #expect(needsReload)
        #expect(Fixtures.sortedPages(of: document)[1].plainText == "Header\nBody two\nEnd two")
    }

    @Test func rangeRemovalEditsEveryAffectedPageInOneCacheWrite() async throws {
        let document = Fixtures.makeProject(texts: texts, in: container.mainContext)
        let model = SmartCleanupModel(document: document)
        let header = TextManipulationService.SectionHeaderDetection(headerText: "header", displayText: "Header", pageRange: 1...3, affectedPages: [1, 3])

        let needsReload = model.apply(.removeSectionHeaderFromRange(header: header), currentPageNumber: 2, liveController: nil)
        try await Task.sleep(for: .milliseconds(100))

        #expect(!needsReload) // page 2 was not in affectedPages
        let pages = Fixtures.sortedPages(of: document)
        #expect(pages[0].plainText == "1\nBody one\nEnd one")
        #expect(pages[1].plainText == texts[1])
        #expect(pages[2].plainText == "3\nBody three\nEnd three")
        #expect(TextExportCacheService.loadFreshCache(from: document) != nil)
    }

    @Test func removeAllPageNumbersSpansTheDocument() async throws {
        let document = Fixtures.makeProject(texts: texts, in: container.mainContext)
        let model = SmartCleanupModel(document: document)
        let cache = try #require(TextExportCacheService.loadFreshCache(from: document))
        let result = TextManipulationService.analyzeForSmartCleanup(cache: cache)
        let option = try #require(TextManipulationService.buildOptions(from: result, forPageNumber: 1).first {
            if case .removeAllPageNumbers = $0 { return true } else { return false }
        })

        let needsReload = model.apply(option, currentPageNumber: 1, liveController: nil)
        try await Task.sleep(for: .milliseconds(100))

        #expect(needsReload)
        #expect(Fixtures.sortedPages(of: document).map(\.plainText) == [
            "Header\nBody one\nEnd one",
            "Header\nBody two\nEnd two",
            "Header\nBody three\nEnd three"
        ])
    }
}
