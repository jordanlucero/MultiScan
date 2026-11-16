//
//  PageNumberingTests.swift
//  MultiScanTests
//

import Foundation
import Testing
import SwiftData
@testable import MultiScan

@Suite("Printed page numbering")
struct PageNumberingTests {
    let container = Fixtures.container()

    @Test func romanNumerals() {
        #expect(PageNumbering.romanNumeral(1) == "I")
        #expect(PageNumbering.romanNumeral(4) == "IV")
        #expect(PageNumbering.romanNumeral(9) == "IX")
        #expect(PageNumbering.romanNumeral(14) == "XIV")
        #expect(PageNumbering.romanNumeral(1994) == "MCMXCIV")
        #expect(PageNumbering.romanNumeral(0) == "0")
        #expect(PageNumbering.value(ofRomanNumeral: "xii") == 12)
        #expect(PageNumbering.value(ofRomanNumeral: "IIII") == nil)
        #expect(PageNumbering.value(ofRomanNumeral: "Chapter") == nil)
    }

    @Test func simplePlanLabelsBeforeAndAfterTheStart() {
        let roman = ResolvedPrintedNumbering.simple(startPage: 9, startValue: 1, frontMatter: .roman)
        #expect(roman.label(forProjectPage: 1) == "i")
        #expect(roman.label(forProjectPage: 8) == "viii")
        #expect(roman.label(forProjectPage: 9) == "1")
        #expect(roman.label(forProjectPage: 20) == "12")
        #expect(roman.frontMatterStyle == .roman)
        #expect(roman.mainRange?.startPage == 9)
        #expect(roman.additionalRanges.isEmpty)

        let unnumbered = ResolvedPrintedNumbering.simple(startPage: 5, startValue: 41, frontMatter: .none)
        #expect(unnumbered.label(forProjectPage: 3) == nil)
        #expect(unnumbered.label(forProjectPage: 7) == "43")

        // Starting on page 1 needs no front-matter range at all.
        let fromStart = ResolvedPrintedNumbering.simple(startPage: 1, startValue: 1, frontMatter: .roman)
        #expect(fromStart.ranges.count == 1)
        #expect(fromStart.frontMatterStyle == .none)
    }

    @Test func additionalRangesRestartNumbering() throws {
        // Roman front matter, body from page 5, an appendix restarting at 1 on page 20, then unnumbered plates from page 25.
        var plan = ResolvedPrintedNumbering.simple(startPage: 5, startValue: 1, frontMatter: .roman)
        plan.ranges.append(ResolvedPrintedNumbering.Range(startPage: 20, style: .arabic, startValue: 1))
        plan.ranges.append(ResolvedPrintedNumbering.Range(startPage: 25, style: .none))
        plan = ResolvedPrintedNumbering(ranges: plan.ranges) // re-sort
        #expect(plan.label(forProjectPage: 19) == "15")
        #expect(plan.label(forProjectPage: 20) == "1")
        #expect(plan.label(forProjectPage: 24) == "5")
        #expect(plan.label(forProjectPage: 26) == nil)
        #expect(plan.additionalRanges.map(\.startPage) == [20, 25])
        // The inverse finds the first Arabic range that prints the value within its span.
        #expect(plan.projectPage(forPrintedValue: 3, totalPages: 30) == 7)
        #expect(plan.projectPage(forPrintedValue: 16, totalPages: 30) == nil) // body ends at 15; the appendix never reaches 16

        // The one-pass label table agrees with the per-page lookup.
        let labels = plan.labels(pageCount: 30)
        for page in 1...30 {
            #expect(labels[page] == plan.label(forProjectPage: page))
        }
    }

    @Test func documentSettingsDriveTheModel() {
        let document = Fixtures.makeProject(texts: Array(repeating: "x", count: 12), in: container.mainContext)
        let pages = Fixtures.sortedPages(of: document)
        #expect(pages[0].printedPageLabel == nil) // not configured

        document.printedNumbering = ResolvedPrintedNumbering.simple(startPage: 4, startValue: 1, frontMatter: .roman).anchored(to: pages)
        #expect(pages[0].printedPageLabel == "i")
        #expect(pages[2].printedPageLabel == "iii")
        #expect(pages[3].printedPageLabel == "1")
        #expect(pages[11].printedPageLabel == "9")
        #expect(document.printedPageLabels()[12] == "9")
        #expect(PageNumbering.projectPage(forPrintedValue: 9, in: document) == 12)
        #expect(PageNumbering.projectPage(forPrintedValue: 10, in: document) == nil)

        document.printedNumbering = nil
        #expect(pages[3].printedPageLabel == nil)
        #expect(document.printedNumberingData == nil)
        #expect(document.printedPageLabels().isEmpty)
    }

    // MARK: Anchoring to pages

    /// Six pages; counting starts ("1") on the page with text "body-1", Roman front matter before it.
    private func numberedProject() -> (Document, NavigationState) {
        let document = Fixtures.makeProject(texts: ["front-1", "front-2", "body-1", "body-2", "body-3", "body-4"], in: container.mainContext)
        document.printedNumbering = ResolvedPrintedNumbering.simple(startPage: 3, startValue: 1, frontMatter: .roman)
            .anchored(to: Fixtures.sortedPages(of: document))
        let state = NavigationState(settings: NavigationSettings(defaults: Fixtures.defaults("numbering-\(UUID().uuidString)")))
        state.setupNavigation(for: document)
        return (document, state)
    }

    private func label(of text: String, in document: Document) -> String? {
        document.unwrappedPages.first { $0.plainText == text }?.printedPageLabel
    }

    @Test func storedPlanIsAnchoredToPagesNotPositions() throws {
        let (document, _) = numberedProject()
        let plan = try #require(document.printedNumbering)
        let bodyStart = try #require(document.unwrappedPages.first { $0.plainText == "body-1" }?.uuid)
        // Front matter is "from the first page, whichever it is"; the body is anchored to its page.
        #expect(plan.ranges.contains { $0.startPageID == nil && $0.style == .roman })
        #expect(plan.ranges.contains { $0.startPageID == bodyStart && $0.style == .arabic && $0.startValue == 1 })
        // Round trip through storage.
        #expect(PrintedNumberingPlan.decode(plan.encoded(), pages: []) == plan)
        #expect(PrintedNumberingPlan.decode(Data("nope".utf8), pages: []) == nil)
        #expect(PrintedNumberingPlan.storedVersion(of: document.printedNumberingData) == PrintedNumberingPlan.currentVersion)
    }

    @Test func labelsFollowTheirPagesThroughReorders() {
        let (document, state) = numberedProject()
        // Move a front-matter page into the body: the body still starts on "body-1", which is now project page 2.
        let front2 = document.unwrappedPages.first { $0.plainText == "front-2" }!
        let body2 = document.unwrappedPages.first { $0.plainText == "body-2" }!
        state.applyReorder(of: [front2.persistentModelID], before: body2.persistentModelID)

        #expect(Fixtures.sortedPages(of: document).map(\.plainText) == ["front-1", "body-1", "front-2", "body-2", "body-3", "body-4"])
        #expect(label(of: "front-1", in: document) == "i")
        #expect(label(of: "body-1", in: document) == "1")
        #expect(label(of: "front-2", in: document) == "2")
        #expect(label(of: "body-4", in: document) == "5")
    }

    @Test func insertingAndDeletingPagesKeepsCountingOnTheSamePage() async throws {
        let (document, state) = numberedProject()
        let context = container.mainContext

        // A page added at the very front becomes "i"; counting still starts on "body-1".
        for page in document.unwrappedPages { page.pageNumber += 1 }
        let cover = Page(pageNumber: 1, text: "cover", imageData: nil)
        cover.document = document
        document.pages?.append(cover)
        document.totalPages += 1
        TextExportCacheService.insertEntries(for: [cover], in: document, shiftingFrom: 1, by: 1)
        state.refreshPageOrder()
        #expect(label(of: "cover", in: document) == "i")
        #expect(label(of: "front-2", in: document) == "iii")
        #expect(label(of: "body-1", in: document) == "1")

        // Deleting a front-matter page doesn't move the start of counting either.
        state.deletePage(document.unwrappedPages.first { $0.plainText == "front-1" }!, modelContext: context)
        #expect(label(of: "front-2", in: document) == "ii")
        #expect(label(of: "body-1", in: document) == "1")
        #expect(label(of: "body-4", in: document) == "4")

        // Deleting the page counting starts on hands the start to the page that takes its place.
        state.deletePage(document.unwrappedPages.first { $0.plainText == "body-1" }!, modelContext: context)
        #expect(label(of: "body-2", in: document) == "1")
        #expect(label(of: "body-4", in: document) == "3")
        #expect(label(of: "front-2", in: document) == "ii")
    }

    @Test func rangeWithMissingAnchorIsSkippedNotLost() throws {
        let (document, _) = numberedProject()
        var plan = try #require(document.printedNumbering)
        // An anchor that isn't in the project (its page hasn't synced yet, say).
        plan.ranges.append(PrintedNumberingRange(startPageID: UUID(), style: .arabic, startValue: 100))
        document.printedNumbering = plan
        #expect(label(of: "body-4", in: document) == "4")
        // …and it is still stored, so it applies once that page shows up.
        #expect(document.printedNumbering?.ranges.count == 3)
    }

    @Test func positionBasedPlansFromEarlierBuildsAreConverted() throws {
        let document = Fixtures.makeProject(texts: Array(repeating: "x", count: 10), in: container.mainContext)
        let pages = Fixtures.sortedPages(of: document)
        // What a schema-3 development build wrote: plan version 1, ranges by project page number.
        let legacy = """
        {"version":1,"ranges":[{"id":"\(UUID().uuidString)","startPage":1,"style":"roman","startValue":1},{"id":"\(UUID().uuidString)","startPage":4,"style":"arabic","startValue":1}]}
        """
        document.printedNumberingData = Data(legacy.utf8)
        #expect(PrintedNumberingPlan.storedVersion(of: document.printedNumberingData) == 1)

        // Read as-is…
        #expect(pages[0].printedPageLabel == "i")
        #expect(pages[3].printedPageLabel == "1")
        #expect(pages[9].printedPageLabel == "7")

        // …and rewritten in the page-anchored form by the launch maintenance.
        #expect(ProjectMaintenance.migratePrintedNumbering(of: document))
        #expect(PrintedNumberingPlan.storedVersion(of: document.printedNumberingData) == PrintedNumberingPlan.currentVersion)
        #expect(document.printedNumbering?.ranges.contains { $0.startPageID == pages[3].uuid } == true)
        #expect(pages[9].printedPageLabel == "7")
        #expect(!ProjectMaintenance.migratePrintedNumbering(of: document)) // idempotent
    }
}
