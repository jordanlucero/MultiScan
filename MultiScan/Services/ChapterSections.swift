//
//  ChapterSections.swift
//  MultiScan
//
//  Chapters as the user sees them: the page list cut into sections, one per chapter mark.
//
//  ## Storage vs. presentation
//  What is *stored* is a mark on a page: `Page.sectionTitle` says "a chapter starts here". What is *shown* (thumbnail sidebar, iPhone page grid, Digest, exports) is a list of sections — a titled, collapsible group of pages per mark, plus an untitled leading group for pages before the first mark. `sections(for:)` derives one from the other.
//
//  ## Reordering treats chapters as containers
//  When pages are dragged (or moved with Move Page Up/Down), a chapter behaves like the section the user is looking at, not like a property of its first page:
//  - a page dropped into a chapter joins that chapter, including at its very top;
//  - dragging a chapter's first page somewhere else moves *that page*, and the chapter stays where it is — its next page becomes the one carrying the mark;
//  - Move Page Up on a chapter's first page hops it over the header into the end of the previous chapter (and Move Page Down the other way).
//  So a one-page move is a one-page move. The alternative — the mark travels with the page — makes dragging a chapter's opening page drag the whole chapter boundary along, re-homing every page in between; and dropping a page just past a *collapsed* chapter would land it inside that chapter, out of sight.
//
//  `applyingMove` computes the result (new page order + which page carries each mark); `NavigationState` applies it, with undo restoring both the order and the marks. A chapter whose last page is moved out has no page left to carry its mark and goes away with it (undo brings it back).
//
//  Pure, `nonisolated`, unit-tested (`ChapterSectionTests`).
//

import Foundation
import SwiftData

/// A chapter mark as stored on a page.
nonisolated struct ChapterMark: Equatable, Sendable {
    var title: String
    var isAutomatic: Bool
}

/// One section of the page list: a chapter and its pages (or the untitled pages before the first chapter).
nonisolated struct ChapterSection: Identifiable {
    /// The first page's identity. This is also the reorder collection identifier SwiftUI hands back for a drop into this section, and the key for its collapsed state.
    let id: PersistentIdentifier
    /// `nil` for the leading, untitled group.
    var mark: ChapterMark?
    var pages: [Page]

    var title: String? { mark?.title }
}

nonisolated enum ChapterSections {

    /// Splits an ordered page list into sections: a page with a `sectionTitle` starts a new one; pages before the first chapter form an untitled leading section.
    static func sections(for pages: [Page]) -> [ChapterSection] {
        var sections: [ChapterSection] = []
        for page in pages {
            if let title = page.sectionTitle, !title.isEmpty {
                sections.append(ChapterSection(
                    id: page.persistentModelID,
                    mark: ChapterMark(title: title, isAutomatic: page.sectionTitleIsAutomatic),
                    pages: [page]
                ))
            } else if sections.isEmpty {
                sections.append(ChapterSection(id: page.persistentModelID, mark: nil, pages: [page]))
            } else {
                sections[sections.count - 1].pages.append(page)
            }
        }
        return sections
    }

    /// The outcome of a move: the pages in their new order, and the mark each chapter-opening page should carry (pages not listed carry none).
    struct Arrangement {
        var pages: [Page]
        var marks: [PersistentIdentifier: ChapterMark]
        /// Section identity before → after, for sections whose first page changed (so collapsed state can follow the chapter).
        var renamedSections: [PersistentIdentifier: PersistentIdentifier]
    }

    /// Moves `movingIDs` into the section `destinationSectionID` — in front of `targetID`, or to the section's end when `targetID` is nil or isn't in that section. An unknown section falls back to the section containing the target, then to the last section.
    static func applyingMove(
        of movingIDs: [PersistentIdentifier],
        toSection destinationSectionID: PersistentIdentifier?,
        before targetID: PersistentIdentifier?,
        in sections: [ChapterSection]
    ) -> Arrangement {
        let moving = Set(movingIDs)
        // Moving pages keep their relative document order.
        let movingPages = sections.flatMap(\.pages).filter { moving.contains($0.persistentModelID) }

        let destinationIndex = sections.firstIndex { $0.id == destinationSectionID }
            ?? targetID.flatMap { target in sections.firstIndex { $0.pages.contains { $0.persistentModelID == target } } }
            ?? max(sections.count - 1, 0)

        var updated = sections
        for index in updated.indices {
            updated[index].pages.removeAll { moving.contains($0.persistentModelID) }
        }
        if updated.indices.contains(destinationIndex) {
            let insertAt = targetID.flatMap { target in
                updated[destinationIndex].pages.firstIndex { $0.persistentModelID == target }
            } ?? updated[destinationIndex].pages.count
            updated[destinationIndex].pages.insert(contentsOf: movingPages, at: insertAt)
        }
        return arrangement(of: updated)
    }

    /// Moves one page a single visual slot up (`offset` < 0) or down: within its section, or across the neighboring header when it sits at the section's edge. `nil` when there is nowhere to go.
    static func applyingStep(of pageID: PersistentIdentifier, by offset: Int, in sections: [ChapterSection]) -> Arrangement? {
        guard offset != 0,
              let sectionIndex = sections.firstIndex(where: { $0.pages.contains { $0.persistentModelID == pageID } }),
              let pageIndex = sections[sectionIndex].pages.firstIndex(where: { $0.persistentModelID == pageID }) else { return nil }

        var updated = sections
        if offset < 0 {
            if pageIndex > 0 {
                updated[sectionIndex].pages.swapAt(pageIndex, pageIndex - 1)
            } else if sectionIndex > 0 {
                let page = updated[sectionIndex].pages.remove(at: pageIndex)
                updated[sectionIndex - 1].pages.append(page)
            } else {
                return nil
            }
        } else {
            if pageIndex < updated[sectionIndex].pages.count - 1 {
                updated[sectionIndex].pages.swapAt(pageIndex, pageIndex + 1)
            } else if sectionIndex < updated.count - 1 {
                let page = updated[sectionIndex].pages.remove(at: pageIndex)
                updated[sectionIndex + 1].pages.insert(page, at: 0)
            } else {
                return nil
            }
        }
        return arrangement(of: updated)
    }

    /// Flattens sections back to a page order, with each surviving chapter's mark on its (possibly new) first page.
    private static func arrangement(of sections: [ChapterSection]) -> Arrangement {
        var marks: [PersistentIdentifier: ChapterMark] = [:]
        var renamed: [PersistentIdentifier: PersistentIdentifier] = [:]
        for section in sections {
            guard let first = section.pages.first else { continue }
            if let mark = section.mark { marks[first.persistentModelID] = mark }
            if first.persistentModelID != section.id { renamed[section.id] = first.persistentModelID }
        }
        return Arrangement(pages: sections.flatMap(\.pages), marks: marks, renamedSections: renamed)
    }

    /// The marks currently on `pages`, in the shape `Arrangement.marks` uses.
    static func marks(of pages: [Page]) -> [PersistentIdentifier: ChapterMark] {
        var marks: [PersistentIdentifier: ChapterMark] = [:]
        for page in pages {
            if let title = page.sectionTitle, !title.isEmpty {
                marks[page.persistentModelID] = ChapterMark(title: title, isAutomatic: page.sectionTitleIsAutomatic)
            }
        }
        return marks
    }
}
