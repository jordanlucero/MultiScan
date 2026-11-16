//
//  ChapterSectionTests.swift
//  MultiScanTests
//
//  Chapters as containers: sections derived from page marks, and what moving pages between them does to the marks.
//

import Foundation
import SwiftData
import Testing
@testable import MultiScan

@Suite("Chapter sections")
struct ChapterSectionTests {
    let container = Fixtures.container()

    /// Pages a…h: "One" starts on c, "Two" on f. a and b sit before the first chapter.
    private func makeState() -> (NavigationState, Document, UndoManager) {
        let document = Fixtures.makeProject(texts: ["a", "b", "c", "d", "e", "f", "g", "h"], in: container.mainContext)
        let pages = Fixtures.sortedPages(of: document)
        pages[2].sectionTitle = "One"
        pages[5].sectionTitle = "Two"
        let state = NavigationState(settings: NavigationSettings(defaults: Fixtures.defaults("chapters-\(UUID().uuidString)")))
        state.setupNavigation(for: document)
        let undo = UndoManager()
        undo.groupsByEvent = false
        state.undoManager = undo
        return (state, document, undo)
    }

    private func page(_ text: String, in document: Document) -> Page {
        document.unwrappedPages.first { $0.plainText == text }!
    }

    /// "a b | One: c d e | Two: f g h"
    private func outline(_ document: Document) -> String {
        ChapterSections.sections(for: Fixtures.sortedPages(of: document)).map { section in
            let pages = section.pages.map(\.plainText).joined(separator: " ")
            return section.title.map { "\($0): \(pages)" } ?? pages
        }.joined(separator: " | ")
    }

    @Test func sectionsFollowTheMarks() {
        let (_, document, _) = makeState()
        #expect(outline(document) == "a b | One: c d e | Two: f g h")
        let sections = ChapterSections.sections(for: Fixtures.sortedPages(of: document))
        #expect(sections.map(\.id) == [page("a", in: document), page("c", in: document), page("f", in: document)].map(\.persistentModelID))
    }

    @Test func droppingAtTheTopOfAChapterJoinsThatChapter() {
        let (state, document, _) = makeState()
        // Drag "d" to the very top of "Two" (before its first page, in Two's section).
        state.applyReorder(of: [page("d", in: document).persistentModelID],
                           toChapter: page("f", in: document).persistentModelID,
                           before: page("f", in: document).persistentModelID)
        #expect(outline(document) == "a b | One: c e | Two: d f g h")
        // The chapter's mark is on its new first page, and only there.
        #expect(page("d", in: document).sectionTitle == "Two")
        #expect(page("f", in: document).sectionTitle == nil)
    }

    @Test func droppingAtTheEndOfAChapterStaysAboveTheNextHeader() {
        let (state, document, _) = makeState()
        // Drag "g" to the end of "One" — the same flat position as "before f", but the other side of the header.
        state.applyReorder(of: [page("g", in: document).persistentModelID],
                           toChapter: page("c", in: document).persistentModelID,
                           before: nil)
        #expect(outline(document) == "a b | One: c d e g | Two: f h")
        #expect(page("f", in: document).sectionTitle == "Two")
    }

    @Test func draggingAChaptersFirstPageMovesOnlyThatPage() {
        let (state, document, _) = makeState()
        // Drag "f" (which opens "Two") into the middle of "One".
        state.applyReorder(of: [page("f", in: document).persistentModelID],
                           toChapter: page("c", in: document).persistentModelID,
                           before: page("d", in: document).persistentModelID)
        // "Two" stays where it was and now opens on "g"; nothing else changed chapter.
        #expect(outline(document) == "a b | One: c f d e | Two: g h")
        #expect(page("f", in: document).sectionTitle == nil)
        #expect(page("g", in: document).sectionTitle == "Two")
    }

    @Test func moveUpAndDownHopOverChapterHeaders() {
        let (state, document, _) = makeState()
        // "f" opens "Two"; moving it up puts it at the end of "One" without reshuffling anything else.
        state.movePage(page("f", in: document), by: -1)
        #expect(outline(document) == "a b | One: c d e f | Two: g h")
        // Moving it back down makes it the first page of "Two" again.
        state.movePage(page("f", in: document), by: 1)
        #expect(outline(document) == "a b | One: c d e | Two: f g h")
        // Within a chapter it is a plain swap.
        state.movePage(page("f", in: document), by: 1)
        #expect(outline(document) == "a b | One: c d e | Two: g f h")
        #expect(page("g", in: document).sectionTitle == "Two")
        // Ends of the document: nowhere to go.
        state.movePage(page("a", in: document), by: -1)
        state.movePage(page("h", in: document), by: 1)
        #expect(outline(document) == "a b | One: c d e | Two: g f h")
    }

    @Test func undoRestoresOrderAndMarks() {
        let (state, document, undo) = makeState()
        undo.beginUndoGrouping()
        state.applyReorder(of: [page("c", in: document).persistentModelID, page("d", in: document).persistentModelID, page("e", in: document).persistentModelID],
                           toChapter: page("f", in: document).persistentModelID,
                           before: nil)
        undo.endUndoGrouping()
        // Every page left "One": the chapter has no page to carry its mark.
        #expect(outline(document) == "a b | Two: f g h c d e")

        undo.undo()
        #expect(outline(document) == "a b | One: c d e | Two: f g h")
        undo.redo()
        #expect(outline(document) == "a b | Two: f g h c d e")
    }

    @Test func selectionAndCacheFollowAReorderAcrossChapters() {
        let (state, document, _) = makeState()
        state.goToPage(pageNumber: 4) // "d"
        state.applyReorder(of: [page("d", in: document).persistentModelID],
                           toChapter: page("f", in: document).persistentModelID,
                           before: page("h", in: document).persistentModelID)
        #expect(state.currentPage?.plainText == "d")
        #expect(Fixtures.sortedPages(of: document).map(\.plainText) == ["a", "b", "c", "e", "f", "g", "d", "h"])
        let cache = TextExportCacheService.loadFreshCache(from: document)
        #expect(cache?.pages.sorted { $0.pageNumber < $1.pageNumber }.map(\.plainText) == ["a", "b", "c", "e", "f", "g", "d", "h"])
    }

    @Test func foldedChaptersUnfoldForTheCurrentPageAndFollowTheirChapter() {
        let (state, document, _) = makeState()
        let two = page("f", in: document).persistentModelID
        state.setChapter(two, collapsed: true)
        #expect(state.isChapterCollapsed(two))

        // The chapter's first page changes; it stays folded under its new identity.
        state.movePage(page("f", in: document), by: -1)
        let newTwo = page("g", in: document).persistentModelID
        #expect(state.isChapterCollapsed(newTwo))
        #expect(!state.isChapterCollapsed(two))

        // Navigating into a folded chapter unfolds it.
        state.goToPage(pageNumber: page("h", in: document).pageNumber)
        state.revealCurrentPage()
        #expect(!state.isChapterCollapsed(newTwo))

        // A page moved into a folded chapter doesn't vanish.
        state.setChapter(newTwo, collapsed: true)
        state.movePage(page("f", in: document), by: 1)
        #expect(outline(document) == "a b | One: c d e | Two: f g h")
        #expect(state.collapsedChapters.isEmpty)
    }

    @Test func deletingAChaptersFirstPageKeepsTheChapter() {
        let (state, document, _) = makeState()
        state.deletePage(page("c", in: document), modelContext: container.mainContext)
        #expect(outline(document) == "a b | One: d e | Two: f g h")
    }
}
