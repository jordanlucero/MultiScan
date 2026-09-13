import Foundation
import SwiftUI
import SwiftData

/// Per-review-view navigation state.
///
/// `@Observable` rather than `ObservableObject`: observation is tracked per
/// property, so a view that reads only `pageOrderVersion` no longer re-renders
/// when `currentPageNumber` changes. Note that the macro tracks *every* stored
/// property — under `@Published` the ordering arrays below were silently
/// untracked, so mutating them didn't invalidate views reading `hasNext`.
@MainActor
@Observable
final class NavigationState {
    var isRandomized: Bool = false
    var selectedDocument: Document?

    // Sequential mode: index into originalOrder
    private var sequentialIndex: Int = 0

    // Shuffled mode: history-based navigation
    private var shuffledOrder: [Int] = []
    private var visitHistory: [Int] = []  // Page numbers in order visited
    private var historyIndex: Int = -1    // Current position in visitHistory

    private var originalOrder: [Int] = []

    // MARK: - Filter State (synced from ThumbnailSidebar)

    /// Current status filter (synced from ThumbnailSidebar)
    var activeStatusFilter: PageFilterOption = .all

    /// Current text search query (synced from ThumbnailSidebar)
    var activeSearchText: String = ""

    /// Navigation settings for filter-aware behavior. Shared with the Settings UI,
    /// so toggling filter-aware navigation takes effect immediately.
    let navigationSettings = NavigationSettings.shared

    /// The window's undo manager, wired in by ReviewView/CompactReviewView so page
    /// order changes can register undo (⌘Z). Weak: the window owns its undo manager.
    /// Not observed — no view reads it during `body`.
    @ObservationIgnored weak var undoManager: UndoManager?

    /// Updated whenever navigation changes
    private(set) var currentPageNumber: Int?

    /// Version counter that increments when page order changes, used to trigger view updates
    private(set) var pageOrderVersion: Int = 0

    // MARK: - Current Page

    var currentPage: Page? {
        guard let document = selectedDocument,
              let pn = currentPageNumber else { return nil }
        return document.unwrappedPages.first { $0.pageNumber == pn }
    }

    // MARK: - Filter-Aware Navigation

    /// Whether any filter is currently active
    var isFilterActive: Bool {
        activeStatusFilter != .all || !activeSearchText.isEmpty
    }

    /// Page numbers that match the current filter, sorted
    private var filteredPageNumbers: [Int] {
        guard let document = selectedDocument else { return [] }
        return PageFilter.apply(
            to: document.unwrappedPages,
            option: activeStatusFilter,
            searchText: activeSearchText
        ).map { $0.pageNumber }
    }

    /// Updates currentPageNumber based on current mode and indices
    private func updateCurrentPageNumber() {
        if isRandomized {
            currentPageNumber = historyIndex >= 0 && historyIndex < visitHistory.count
                ? visitHistory[historyIndex]
                : nil
        } else {
            currentPageNumber = sequentialIndex >= 0 && sequentialIndex < originalOrder.count
                ? originalOrder[sequentialIndex]
                : nil
        }
    }

    // MARK: - Navigation Availability

    var hasNext: Bool {
        guard let document = selectedDocument else { return false }

        if isRandomized {
            // Shuffled mode: check for undone pages, respecting filter if enabled
            if navigationSettings.shuffledUsesFilteredNavigation && isFilterActive {
                return findNextUndoneInFilteredShuffledOrder(from: currentPageNumber, in: document) != nil
            }
            return findNextUndoneInShuffledOrder(from: currentPageNumber, in: document) != nil
        } else {
            // Sequential mode: check if we can advance, respecting filter if enabled
            if navigationSettings.sequentialUsesFilteredNavigation && isFilterActive {
                return findNextInFilteredSequentialOrder() != nil
            }
            return sequentialIndex < originalOrder.count - 1
        }
    }

    var hasPrevious: Bool {
        guard selectedDocument != nil else { return false }

        if isRandomized {
            // Shuffled mode: can go back if there's history behind us (unchanged)
            return historyIndex > 0
        } else {
            // Sequential mode: check if we can go back, respecting filter if enabled
            if navigationSettings.sequentialUsesFilteredNavigation && isFilterActive {
                return findPreviousInFilteredSequentialOrder() != nil
            }
            return sequentialIndex > 0
        }
    }

    // MARK: - Setup

    func setupNavigation(for document: Document) {
        selectedDocument = document
        originalOrder = document.unwrappedPages.map { $0.pageNumber }.sorted()
        shuffledOrder = originalOrder.shuffled()

        // Reset sequential index to first page
        sequentialIndex = 0

        // Reset shuffled history and start with first shuffled page
        visitHistory = []
        historyIndex = -1

        if !shuffledOrder.isEmpty {
            // Add first shuffled page to history
            visitHistory.append(shuffledOrder[0])
            historyIndex = 0
        }

        updateCurrentPageNumber()
    }

    // MARK: - Navigation

    func nextPage() {
        guard selectedDocument != nil else { return }

        if isRandomized {
            if navigationSettings.shuffledUsesFilteredNavigation && isFilterActive {
                nextPageShuffledFiltered()
            } else {
                nextPageShuffled()
            }
        } else {
            if navigationSettings.sequentialUsesFilteredNavigation && isFilterActive {
                nextPageSequentialFiltered()
            } else {
                nextPageSequential()
            }
        }
    }

    func previousPage() {
        guard selectedDocument != nil else { return }

        if isRandomized {
            // Shuffled mode: history-based, unchanged
            previousPageShuffled()
        } else {
            if navigationSettings.sequentialUsesFilteredNavigation && isFilterActive {
                previousPageSequentialFiltered()
            } else {
                previousPageSequential()
            }
        }
    }

    private func nextPageSequential() {
        guard sequentialIndex < originalOrder.count - 1 else { return }
        sequentialIndex += 1
        updateCurrentPageNumber()
    }

    private func previousPageSequential() {
        guard sequentialIndex > 0 else { return }
        sequentialIndex -= 1
        updateCurrentPageNumber()
    }

    private func nextPageShuffled() {
        guard let document = selectedDocument, !shuffledOrder.isEmpty else { return }

        // Find the next undone page in shuffled order
        guard let nextPN = findNextUndoneInShuffledOrder(from: currentPageNumber, in: document) else {
            return // No undone pages left
        }

        // Truncate forward history if we went back
        if historyIndex < visitHistory.count - 1 {
            visitHistory = Array(visitHistory.prefix(historyIndex + 1))
        }

        visitHistory.append(nextPN)
        historyIndex = visitHistory.count - 1
        updateCurrentPageNumber()
    }

    private func previousPageShuffled() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        updateCurrentPageNumber()
    }

    /// Finds the next undone page in shuffled order, starting after the given page
    private func findNextUndoneInShuffledOrder(from pageNumber: Int?, in document: Document) -> Int? {
        let startIndex: Int
        if let pn = pageNumber, let idx = shuffledOrder.firstIndex(of: pn) {
            startIndex = idx
        } else {
            startIndex = shuffledOrder.count - 1 // Will wrap to 0
        }

        // Search through all OTHER pages in shuffled order (exclude current)
        for offset in 1..<shuffledOrder.count {
            let checkIndex = (startIndex + offset) % shuffledOrder.count
            let checkPageNumber = shuffledOrder[checkIndex]

            if let page = document.unwrappedPages.first(where: { $0.pageNumber == checkPageNumber }),
               !page.isDone {
                return checkPageNumber
            }
        }

        return nil // All pages are done
    }

    // MARK: - Filtered Sequential Navigation

    private func nextPageSequentialFiltered() {
        guard let nextPN = findNextInFilteredSequentialOrder() else {
            announceFilterBoundary(direction: .next)
            return
        }
        if let index = originalOrder.firstIndex(of: nextPN) {
            sequentialIndex = index
            updateCurrentPageNumber()
        }
    }

    private func previousPageSequentialFiltered() {
        guard let prevPN = findPreviousInFilteredSequentialOrder() else {
            announceFilterBoundary(direction: .previous)
            return
        }
        if let index = originalOrder.firstIndex(of: prevPN) {
            sequentialIndex = index
            updateCurrentPageNumber()
        }
    }

    private func findNextInFilteredSequentialOrder() -> Int? {
        let filtered = filteredPageNumbers
        guard let currentPN = currentPageNumber,
              let currentFilteredIndex = filtered.firstIndex(of: currentPN) else {
            // Current page not in filter, find first matching page after current position
            if let currentPN = currentPageNumber {
                return filtered.first { $0 > currentPN }
            }
            return filtered.first
        }
        let nextIndex = currentFilteredIndex + 1
        return nextIndex < filtered.count ? filtered[nextIndex] : nil
    }

    private func findPreviousInFilteredSequentialOrder() -> Int? {
        let filtered = filteredPageNumbers
        guard let currentPN = currentPageNumber,
              let currentFilteredIndex = filtered.firstIndex(of: currentPN) else {
            // Current page not in filter, find last matching page before current position
            if let currentPN = currentPageNumber {
                return filtered.last { $0 < currentPN }
            }
            return nil
        }
        let prevIndex = currentFilteredIndex - 1
        return prevIndex >= 0 ? filtered[prevIndex] : nil
    }

    // MARK: - Filtered Shuffled Navigation

    private func nextPageShuffledFiltered() {
        guard let document = selectedDocument else { return }

        guard let nextPN = findNextUndoneInFilteredShuffledOrder(from: currentPageNumber, in: document) else {
            announceFilterBoundary(direction: .next)
            return
        }

        // Truncate forward history if we went back
        if historyIndex < visitHistory.count - 1 {
            visitHistory = Array(visitHistory.prefix(historyIndex + 1))
        }

        visitHistory.append(nextPN)
        historyIndex = visitHistory.count - 1
        updateCurrentPageNumber()
    }

    private func findNextUndoneInFilteredShuffledOrder(from pageNumber: Int?, in document: Document) -> Int? {
        let filtered = Set(filteredPageNumbers)
        let startIndex: Int
        if let pn = pageNumber, let idx = shuffledOrder.firstIndex(of: pn) {
            startIndex = idx
        } else {
            startIndex = shuffledOrder.count - 1
        }

        for offset in 1..<shuffledOrder.count {
            let checkIndex = (startIndex + offset) % shuffledOrder.count
            let checkPageNumber = shuffledOrder[checkIndex]

            // Must be in filtered set AND undone
            guard filtered.contains(checkPageNumber) else { continue }

            if let page = document.unwrappedPages.first(where: { $0.pageNumber == checkPageNumber }),
               !page.isDone {
                return checkPageNumber
            }
        }
        return nil
    }

    // MARK: - Filter Boundary Announcement

    enum NavigationDirection {
        case next, previous
    }

    private func announceFilterBoundary(direction: NavigationDirection) {
        let message: String
        switch direction {
        case .next:
            message = String(localized: "No more matching pages ahead")
        case .previous:
            message = String(localized: "No more matching pages behind")
        }
        AccessibilityNotification.Announcement(message).post()
    }

    // MARK: - Direct Navigation

    func goToPage(pageNumber: Int) {
        guard selectedDocument != nil else { return }

        if isRandomized {
            // In shuffled mode, add to history (truncating forward history)
            if historyIndex < visitHistory.count - 1 {
                // Truncate forward history
                visitHistory = Array(visitHistory.prefix(historyIndex + 1))
            }
            visitHistory.append(pageNumber)
            historyIndex = visitHistory.count - 1
        } else {
            // In sequential mode, just find the index
            if let index = originalOrder.firstIndex(of: pageNumber) {
                sequentialIndex = index
            }
        }
        updateCurrentPageNumber()
    }

    // MARK: - Mode Toggle

    func toggleRandomization() {
        let currentPN = currentPageNumber

        isRandomized.toggle()

        if let pageNumber = currentPN {
            if isRandomized {
                // Switching TO shuffled: add current page to history if not already there
                if visitHistory.isEmpty || visitHistory[historyIndex] != pageNumber {
                    if historyIndex < visitHistory.count - 1 {
                        visitHistory = Array(visitHistory.prefix(historyIndex + 1))
                    }
                    visitHistory.append(pageNumber)
                    historyIndex = visitHistory.count - 1
                }
            } else {
                // Switching TO sequential: find page in original order
                if let index = originalOrder.firstIndex(of: pageNumber) {
                    sequentialIndex = index
                }
            }
        }
        updateCurrentPageNumber()
    }

    // MARK: - Page State

    func toggleCurrentPageDone() {
        currentPage?.isDone.toggle()
    }

    /// Whether the current page can be moved up
    var canMoveCurrentPageUp: Bool {
        guard let page = currentPage, let document = selectedDocument else { return false }
        return document.unwrappedPages.contains { $0.pageNumber == page.pageNumber - 1 }
    }

    /// Whether the current page can be moved down
    var canMoveCurrentPageDown: Bool {
        guard let page = currentPage, let document = selectedDocument else { return false }
        return document.unwrappedPages.contains { $0.pageNumber == page.pageNumber + 1 }
    }

    /// Move current page up by swapping with adjacent page
    func moveCurrentPageUp() {
        guard let page = currentPage else { return }
        movePage(page, by: -1)
    }

    /// Move current page down by swapping with adjacent page
    func moveCurrentPageDown() {
        guard let page = currentPage else { return }
        movePage(page, by: 1)
    }

    /// Moves a page one slot up (`offset` -1) or down (+1), registering undo.
    /// Backs the Move Page Up/Down menu commands and thumbnail context menus.
    func movePage(_ page: Page, by offset: Int) {
        guard let document = selectedDocument else { return }
        var order = document.unwrappedPages.sorted { $0.pageNumber < $1.pageNumber }
        guard let index = order.firstIndex(where: { $0.persistentModelID == page.persistentModelID }),
              order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
        setPageOrder(order, actionName: offset < 0
            ? String(localized: "Move Page Up")
            : String(localized: "Move Page Down"))
    }

    /// Applies a drag reorder from a `reorderContainer` (thumbnail sidebar / page grid): the dragged pages move in front of the page with `targetID` (nil = to the end).
    func applyReorder(of pageIDs: [PersistentIdentifier], before targetID: PersistentIdentifier?) {
        guard let document = selectedDocument, !pageIDs.isEmpty else { return }
        var order = document.unwrappedPages.sorted { $0.pageNumber < $1.pageNumber }
        let movingIDs = Set(pageIDs)
        let moving = order.filter { movingIDs.contains($0.persistentModelID) }
        guard !moving.isEmpty else { return }
        order.removeAll { movingIDs.contains($0.persistentModelID) }
        let insertIndex = targetID.flatMap { target in
            order.firstIndex { $0.persistentModelID == target }
        } ?? order.count
        order.insert(contentsOf: moving, at: insertIndex)
        setPageOrder(order, actionName: String(localized: "Reorder Pages"))
    }

    /// Looks up pages by ID and restores their order. Used by undo/redo, where only Sendable identifiers are captured; skips silently if pages were added/deleted since.
    private func restorePageOrder(_ orderedIDs: [PersistentIdentifier], actionName: String) {
        guard let document = selectedDocument else { return }
        let pagesByID = Dictionary(uniqueKeysWithValues: document.unwrappedPages.map { ($0.persistentModelID, $0) })
        let ordered = orderedIDs.compactMap { pagesByID[$0] }
        guard ordered.count == orderedIDs.count else { return }
        setPageOrder(ordered, actionName: actionName)
    }

    /// Renumbers the document's pages to match `orderedPages`, keeping the export cache and navigation state in sync. The current page stays selected by identity — the viewer keeps showing the same page at its new position, which also leaves the text editor attached so its undo stack survives the reorder. Registers an inverse action with `undoManager` so ⌘Z/⇧⌘Z walk order changes back and forth.
    private func setPageOrder(_ orderedPages: [Page], actionName: String) {
        guard let document = selectedDocument else { return }
        let oldOrder = document.unwrappedPages.sorted { $0.pageNumber < $1.pageNumber }

        // A stale undo (pages added or deleted since) must not renumber a changed document
        guard orderedPages.count == oldOrder.count,
              Set(orderedPages.map(\.persistentModelID)) == Set(oldOrder.map(\.persistentModelID)),
              orderedPages.map(\.persistentModelID) != oldOrder.map(\.persistentModelID) else { return }

        let currentPageID = currentPage?.persistentModelID

        // Old page number -> new page number, for the cache and history remapping
        var newNumbers: [Int: Int] = [:]
        for (index, page) in orderedPages.enumerated() {
            newNumbers[page.pageNumber] = index + 1
        }
        for (index, page) in orderedPages.enumerated() where page.pageNumber != index + 1 {
            page.pageNumber = index + 1
        }
        TextExportCacheService.renumberEntries(newNumbers, in: document)

        // Keep shuffled visit history pointing at the same pages
        visitHistory = visitHistory.map { newNumbers[$0] ?? $0 }

        refreshPageOrder()

        // Selection follows the page, not the slot
        if let currentPageID,
           let newNumber = orderedPages.first(where: { $0.persistentModelID == currentPageID })?.pageNumber {
            if !isRandomized, let index = originalOrder.firstIndex(of: newNumber) {
                sequentialIndex = index
            }
            updateCurrentPageNumber()
        }

        let oldOrderIDs = oldOrder.map(\.persistentModelID)
        undoManager?.registerUndo(withTarget: self) { state in
            MainActor.assumeIsolated {
                state.restorePageOrder(oldOrderIDs, actionName: actionName)
            }
        }
        undoManager?.setActionName(actionName)
    }

    /// Delete the current page from the document
    func deleteCurrentPage(modelContext: ModelContext) {
        guard let page = currentPage else { return }
        deletePage(page, modelContext: modelContext)
    }

    /// Deletes a page from its document: renumbers the pages after it, syncs the export cache, removes the model, and refreshes navigation. When the deleted page was the current one, navigation moves to the page that took its number (or the new last page).
    ///
    /// The single owner of page deletion — the thumbnail context menu and the vertical size class page grid both route here rather than repeating the renumber/cache bookkeeping.
    func deletePage(_ page: Page, modelContext: ModelContext) {
        guard let document = page.document ?? selectedDocument else { return }

        let deletedPageNumber = page.pageNumber
        let wasCurrentPage = currentPageNumber == deletedPageNumber

        // Remove page entry from export cache (also renumbers subsequent pages)
        TextExportCacheService.removeEntry(pageNumber: deletedPageNumber, from: document)

        // Decrement pageNumber for all pages after the deleted one
        for otherPage in document.unwrappedPages where otherPage.pageNumber > deletedPageNumber {
            otherPage.pageNumber -= 1
        }

        // Remove from document's pages array
        document.pages?.removeAll { $0.persistentModelID == page.persistentModelID }
        document.totalPages -= 1
        document.recalculateStorageSize()

        // Delete the page from the model context
        modelContext.delete(page)

        // Refresh navigation state
        refreshPageOrder()

        guard wasCurrentPage else { return }

        // Navigate to an adjacent page
        let newPageNumber = min(deletedPageNumber, document.totalPages)
        if newPageNumber > 0 {
            goToPage(pageNumber: newPageNumber)
        } else {
            currentPageNumber = nil
        }
    }

    var donePageCount: Int {
        selectedDocument?.unwrappedPages.filter { $0.isDone }.count ?? 0
    }

    var totalPageCount: Int {
        selectedDocument?.unwrappedPages.count ?? 0
    }

    /// Refreshes the page ordering arrays after pages were added, removed, or renumbered.
    func refreshPageOrder() {
        guard let document = selectedDocument else { return }
        originalOrder = document.unwrappedPages.map { $0.pageNumber }.sorted()
        shuffledOrder = originalOrder.shuffled()
        pageOrderVersion += 1
    }
}
