//
//  PageNumberingTests.swift
//  MultiScanTests
//

import Foundation
import Testing
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
        let roman = PrintedNumberingPlan.simple(startPage: 9, startValue: 1, frontMatter: .roman)
        #expect(roman.label(forProjectPage: 1) == "i")
        #expect(roman.label(forProjectPage: 8) == "viii")
        #expect(roman.label(forProjectPage: 9) == "1")
        #expect(roman.label(forProjectPage: 20) == "12")
        #expect(roman.frontMatterStyle == .roman)
        #expect(roman.mainRange?.startPage == 9)
        #expect(roman.additionalRanges.isEmpty)

        let unnumbered = PrintedNumberingPlan.simple(startPage: 5, startValue: 41, frontMatter: .none)
        #expect(unnumbered.label(forProjectPage: 3) == nil)
        #expect(unnumbered.label(forProjectPage: 7) == "43")

        // Starting on page 1 needs no front-matter range at all.
        let fromStart = PrintedNumberingPlan.simple(startPage: 1, startValue: 1, frontMatter: .roman)
        #expect(fromStart.ranges.count == 1)
        #expect(fromStart.frontMatterStyle == .none)
    }

    @Test func additionalRangesRestartNumbering() throws {
        // Roman front matter, body from page 5, an appendix restarting at 1 on page 20, then unnumbered plates from page 25.
        var plan = PrintedNumberingPlan.simple(startPage: 5, startValue: 1, frontMatter: .roman)
        plan.ranges.append(PrintedNumberingRange(startPage: 20, style: .arabic, startValue: 1))
        plan.ranges.append(PrintedNumberingRange(startPage: 25, style: .none))
        plan = PrintedNumberingPlan(ranges: plan.ranges) // re-sort
        #expect(plan.label(forProjectPage: 19) == "15")
        #expect(plan.label(forProjectPage: 20) == "1")
        #expect(plan.label(forProjectPage: 24) == "5")
        #expect(plan.label(forProjectPage: 26) == nil)
        #expect(plan.additionalRanges.map(\.startPage) == [20, 25])
        // The inverse finds the first Arabic range that prints the value within its span.
        #expect(plan.projectPage(forPrintedValue: 3, totalPages: 30) == 7)
        #expect(plan.projectPage(forPrintedValue: 16, totalPages: 30) == nil) // body ends at 15; the appendix never reaches 16

        let data = try #require(plan.encoded())
        #expect(PrintedNumberingPlan.decode(data) == plan)
        #expect(PrintedNumberingPlan.decode(Data("nope".utf8)) == nil)
    }

    @Test func documentSettingsDriveTheModel() {
        let document = Fixtures.makeProject(texts: Array(repeating: "x", count: 12), in: container.mainContext)
        let pages = Fixtures.sortedPages(of: document)
        #expect(pages[0].printedPageLabel == nil) // not configured

        document.printedNumbering = .simple(startPage: 4, startValue: 1, frontMatter: .roman)
        #expect(pages[0].printedPageLabel == "i")
        #expect(pages[2].printedPageLabel == "iii")
        #expect(pages[3].printedPageLabel == "1")
        #expect(pages[11].printedPageLabel == "9")
        #expect(PageNumbering.projectPage(forPrintedValue: 9, in: document) == 12)
        #expect(PageNumbering.projectPage(forPrintedValue: 10, in: document) == nil)

        document.printedNumbering = nil
        #expect(pages[3].printedPageLabel == nil)
        #expect(document.printedNumberingData == nil)
    }
}
