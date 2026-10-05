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

    @Test func labelsBeforeAndAfterTheStart() {
        #expect(PageNumbering.printedLabel(forProjectPage: 1, startPage: 9, startValue: 1, frontMatterStyle: .roman) == "i")
        #expect(PageNumbering.printedLabel(forProjectPage: 8, startPage: 9, startValue: 1, frontMatterStyle: .roman) == "viii")
        #expect(PageNumbering.printedLabel(forProjectPage: 9, startPage: 9, startValue: 1, frontMatterStyle: .roman) == "1")
        #expect(PageNumbering.printedLabel(forProjectPage: 20, startPage: 9, startValue: 1, frontMatterStyle: .roman) == "12")
        #expect(PageNumbering.printedLabel(forProjectPage: 3, startPage: 5, startValue: 41, frontMatterStyle: .none) == nil)
        #expect(PageNumbering.printedLabel(forProjectPage: 7, startPage: 5, startValue: 41, frontMatterStyle: .none) == "43")
    }

    @Test func documentSettingsDriveTheModel() {
        let document = Fixtures.makeProject(texts: Array(repeating: "x", count: 12), in: container.mainContext)
        let pages = Fixtures.sortedPages(of: document)
        #expect(pages[0].printedPageLabel == nil) // not configured

        document.printedNumberingStartPage = 4
        document.printedNumberingStartValue = 1
        document.frontMatterStyle = .roman
        #expect(pages[0].printedPageLabel == "i")
        #expect(pages[2].printedPageLabel == "iii")
        #expect(pages[3].printedPageLabel == "1")
        #expect(pages[11].printedPageLabel == "9")
        #expect(PageNumbering.projectPage(forPrintedValue: 9, in: document) == 12)
        #expect(PageNumbering.projectPage(forPrintedValue: 10, in: document) == nil)
        #expect(document.frontMatterNumberingStyle == FrontMatterNumberingStyle.roman.rawValue)
    }
}
