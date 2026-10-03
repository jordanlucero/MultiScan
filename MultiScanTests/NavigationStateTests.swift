//
//  NavigationStateTests.swift
//  MultiScanTests
//

import Foundation
import SwiftData
import Testing
@testable import MultiScan

@Suite("Navigation state")
struct NavigationStateTests {
    let container = Fixtures.container()

    private func makeState(_ texts: [String]) -> (NavigationState, Document) {
        let document = Fixtures.makeProject(texts: texts, in: container.mainContext)
        let settings = NavigationSettings(defaults: Fixtures.defaults("navigation-\(UUID().uuidString)"))
        let state = NavigationState(settings: settings)
        state.setupNavigation(for: document)
        return (state, document)
    }

    @Test func sequentialNavigationWalksPagesInOrder() {
        let (state, _) = makeState(["A", "B", "C"])
        #expect(state.currentPageNumber == 1)
        #expect(!state.hasPrevious)
        #expect(state.hasNext)
        #expect(state.totalPageCount == 3)
        #expect(state.donePageCount == 0)

        state.nextPage()
        #expect(state.currentPageNumber == 2)
        state.nextPage()
        #expect(state.currentPageNumber == 3)
        #expect(!state.hasNext)
        state.nextPage()
        #expect(state.currentPageNumber == 3)

        state.previousPage()
        #expect(state.currentPageNumber == 2)
        state.goToPage(pageNumber: 1)
        #expect(state.currentPageNumber == 1)
        #expect(state.currentPage?.plainText == "A")
    }

    @Test func togglingDoneUpdatesCounts() {
        let (state, _) = makeState(["A", "B"])
        state.toggleCurrentPageDone()
        #expect(state.currentPage?.isDone == true)
        #expect(state.donePageCount == 1)
        state.toggleCurrentPageDone()
        #expect(state.donePageCount == 0)
    }

    @Test func filteredSequentialNavigationSkipsNonMatchingPages() {
        let (state, document) = makeState(["A", "B", "C", "D", "E"])
        let pages = Fixtures.sortedPages(of: document)
        pages[1].isDone = true
        pages[3].isDone = true
        state.activeStatusFilter = .notDone
        #expect(state.isFilterActive)

        state.nextPage()
        #expect(state.currentPageNumber == 3)
        state.nextPage()
        #expect(state.currentPageNumber == 5)
        #expect(!state.hasNext)
        state.nextPage()
        #expect(state.currentPageNumber == 5)

        state.previousPage()
        #expect(state.currentPageNumber == 3)
        state.previousPage()
        #expect(state.currentPageNumber == 1)
        #expect(!state.hasPrevious)
    }

    @Test func textFilterNarrowsNavigationToo() {
        let (state, _) = makeState(["apple", "pear", "apple pie"])
        state.activeSearchText = "apple"
        state.nextPage()
        #expect(state.currentPageNumber == 3)
    }

    @Test func shuffledNavigationVisitsUndonePagesAndKeepsHistory() {
        let (state, document) = makeState(["A", "B", "C"])
        state.toggleRandomization()
        #expect(state.isRandomized)
        #expect(state.currentPageNumber == 1)

        state.nextPage()
        let visited = state.currentPageNumber
        #expect(visited == 2 || visited == 3)
        state.previousPage()
        #expect(state.currentPageNumber == 1)

        for page in document.unwrappedPages { page.isDone = true }
        #expect(!state.hasNext)

        state.toggleRandomization()
        #expect(!state.isRandomized)
        #expect(state.currentPageNumber == 1)
    }

    @Test func movePageRenumbersAndKeepsSelectionOnTheSamePage() {
        let (state, document) = makeState(["A", "B", "C"])
        let pages = Fixtures.sortedPages(of: document)
        let (a, b, c) = (pages[0], pages[1], pages[2])

        #expect(!state.canMoveCurrentPageUp)
        #expect(state.canMoveCurrentPageDown)

        state.goToPage(pageNumber: 2)
        let versionBefore = state.pageOrderVersion
        state.movePage(c, by: -1)

        #expect(a.pageNumber == 1)
        #expect(c.pageNumber == 2)
        #expect(b.pageNumber == 3)
        #expect(state.currentPage === b)
        #expect(state.currentPageNumber == 3)
        #expect(state.pageOrderVersion == versionBefore + 1)
        #expect(TextExportCacheService.loadFreshCache(from: document)?.pages.map(\.plainText) == ["A", "C", "B"])
    }

    @Test func applyReorderMovesDraggedPagesBeforeTarget() {
        let (state, document) = makeState(["A", "B", "C"])
        let pages = Fixtures.sortedPages(of: document)
        state.applyReorder(of: [pages[2].persistentModelID], before: pages[0].persistentModelID)
        #expect(pages.map(\.pageNumber) == [2, 3, 1])

        state.applyReorder(of: [pages[0].persistentModelID], before: nil)
        #expect(pages.map(\.pageNumber) == [3, 2, 1])
    }

    @Test func reordersAreUndoable() {
        let (state, document) = makeState(["A", "B", "C"])
        let pages = Fixtures.sortedPages(of: document)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        state.undoManager = undoManager

        undoManager.beginUndoGrouping()
        state.movePage(pages[2], by: -1)
        undoManager.endUndoGrouping()
        #expect(pages[2].pageNumber == 2)
        #expect(undoManager.canUndo)

        undoManager.undo()
        #expect(pages[2].pageNumber == 3)
        #expect(pages[1].pageNumber == 2)
        #expect(undoManager.canRedo)

        undoManager.redo()
        #expect(pages[2].pageNumber == 2)
    }

    @Test func deletingTheCurrentPageMovesToItsSuccessor() {
        let (state, document) = makeState(["A", "B", "C"])
        let pages = Fixtures.sortedPages(of: document)
        state.goToPage(pageNumber: 2)

        state.deletePage(pages[1], modelContext: container.mainContext)

        #expect(document.totalPages == 2)
        #expect(document.unwrappedPages.count == 2)
        #expect(pages[0].pageNumber == 1)
        #expect(pages[2].pageNumber == 2)
        #expect(state.currentPageNumber == 2)
        #expect(state.currentPage?.plainText == "C")
        #expect(state.totalPageCount == 2)
        #expect(TextExportCacheService.loadFreshCache(from: document)?.pages.map(\.plainText) == ["A", "C"])
    }

    @Test func deletingTheLastPageSelectsTheNewLast() {
        let (state, document) = makeState(["A", "B"])
        let pages = Fixtures.sortedPages(of: document)
        state.goToPage(pageNumber: 2)
        state.deletePage(pages[1], modelContext: container.mainContext)
        #expect(state.currentPageNumber == 1)
        #expect(!state.hasNext)
    }
}
