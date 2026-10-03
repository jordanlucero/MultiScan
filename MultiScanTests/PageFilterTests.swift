//
//  PageFilterTests.swift
//  MultiScanTests
//

import Foundation
import Testing
@testable import MultiScan

@Suite("Page filter")
struct PageFilterTests {
    private func pages() -> [Page] {
        let first = Page(pageNumber: 1, text: "Alpha text", imageData: nil, originalFileName: "scan-one.jpg")
        let second = Page(pageNumber: 2, text: "Beta", imageData: nil, originalFileName: "scan-two.jpg")
        second.isDone = true
        let third = Page(pageNumber: 3, text: "Gamma alpha", imageData: nil, originalFileName: "scan-three.jpg")
        return [third, first, second] // deliberately unsorted
    }

    @Test func sortsByPageNumber() {
        #expect(PageFilter.apply(to: pages()).map(\.pageNumber) == [1, 2, 3])
    }

    @Test func filtersByReviewStatus() {
        #expect(PageFilter.apply(to: pages(), option: .done).map(\.pageNumber) == [2])
        #expect(PageFilter.apply(to: pages(), option: .notDone).map(\.pageNumber) == [1, 3])
        #expect(PageFilterOption.done.matches(pages()[2]))
    }

    @Test func searchesTextNumberAndFilename() {
        #expect(PageFilter.apply(to: pages(), searchText: "ALPHA").map(\.pageNumber) == [1, 3])
        #expect(PageFilter.apply(to: pages(), searchText: "2").map(\.pageNumber) == [2])
        #expect(PageFilter.apply(to: pages(), searchText: "scan-three").map(\.pageNumber) == [3])
        #expect(PageFilter.apply(to: pages(), searchText: "zzz").isEmpty)
    }

    @Test func combinesStatusAndText() {
        #expect(PageFilter.apply(to: pages(), option: .notDone, searchText: "alpha").map(\.pageNumber) == [1, 3])
        #expect(PageFilter.apply(to: pages(), option: .done, searchText: "alpha").isEmpty)
    }

    @Test func rawValuesAreStable() {
        // Persisted in @AppStorage — renaming a case would silently reset users' filter
        #expect(PageFilterOption(rawValue: "all") == .all)
        #expect(PageFilterOption(rawValue: "done") == .done)
        #expect(PageFilterOption(rawValue: "notDone") == .notDone)
    }
}
