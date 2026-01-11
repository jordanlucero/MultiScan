import Foundation
import SwiftUI
import SwiftData

@MainActor
class NavigationState: ObservableObject {
    @Published var isRandomized: Bool = false
    @Published var selectedDocument: Document?

    // Sequential mode: index into originalOrder
    @Published private var sequentialIndex: Int = 0

    // Shuffled mode: history-based navigation
    private var shuffledOrder: [Int] = []
    private var visitHistory: [Int] = []  // Page numbers in order visited
    @Published private var historyIndex: Int = -1    // Current position in visitHistory

    private var originalOrder: [Int] = []

    // MARK: - Filter State (synced from ThumbnailSidebar)

    /// Current status filter option raw value (synced from ThumbnailSidebar)
    @Published var activeStatusFilter: String = "all"

    /// Current text search query (synced from ThumbnailSidebar)
    @Published var activeSearchText: String = ""

    /// Navigation settings for filter-aware behavior
    let navigationSettings = NavigationSettings()

    // Published for view observation - updated whenever navigation changes
    @Published private(set) var currentPageNumber: Int?

    // MARK: - Full Document Text Cache (for TTS, accessibility, and future search)

    /// Plain text version of the entire document for TTS and search
    @Published private(set) var fullDocumentPlainText: String = ""

    /// Attributed text version of the entire document with formatting
    @Published private(set) var fullDocumentAttributedText: AttributedString = AttributedString()

    /// Version counter that increments when page order changes, used to trigger view updates
    @Published private(set) var pageOrderVersion: Int = 0

    // MARK: - Current Page

    var currentPage: Page? {
        guard let document = selectedDocument,
              let pn = currentPageNumber else { return nil }
        return document.pages.first { $0.pageNumber == pn }
    }

    // MARK: - Filter-Aware Navigation

    /// Whether any filter is currently active
    var isFilterActive: Bool {
        activeStatusFilter != "all" || !activeSearchText.isEmpty
    }

    /// Page numbers that match the current filter, sorted
    private var filteredPageNumbers: [Int] {
        guard let document = selectedDocument else { return [] }

        let sortedPages = document.pages.sorted { $0.pageNumber < $1.pageNumber }

        // Apply status filter
        let statusFiltered: [Page]
        switch activeStatusFilter {
        case "notDone":
            statusFiltered = sortedPages.filter { !$0.isDone }
        case "done":
            statusFiltered = sortedPages.filter { $0.isDone }
        default: // "all"
            statusFiltered = sortedPages
        }

        // Apply text search
        guard !activeSearchText.isEmpty else {
            return statusFiltered.map { $0.pageNumber }
        }

        let query = activeSearchText.lowercased()
        return statusFiltered.filter { page in
            // Match page number: "1", "Page 1", "page 1"
            let pageNum = String(page.pageNumber)
            if pageNum.contains(query) || "page \(pageNum)".contains(query) {
                return true
            }

            // Match filename (case-insensitive)
            if let filename = page.originalFileName?.lowercased(), filename.contains(query) {
                return true
            }

            // Match page content (case-insensitive)
            if page.plainText.lowercased().contains(query) {
                return true
            }

            return false
        }.map { $0.pageNumber }
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
        originalOrder = document.pages.map { $0.pageNumber }.sorted()
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

        // Build the full document text cache for TTS/accessibility/search
        rebuildTextCache()
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

            if let page = document.pages.first(where: { $0.pageNumber == checkPageNumber }),
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

            if let page = document.pages.first(where: { $0.pageNumber == checkPageNumber }),
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
        return document.pages.contains { $0.pageNumber == page.pageNumber - 1 }
    }

    /// Whether the current page can be moved down
    var canMoveCurrentPageDown: Bool {
        guard let page = currentPage, let document = selectedDocument else { return false }
        return document.pages.contains { $0.pageNumber == page.pageNumber + 1 }
    }

    /// Move current page up by swapping with adjacent page
    func moveCurrentPageUp() {
        guard let page = currentPage,
              let document = selectedDocument,
              let adjacent = document.pages.first(where: { $0.pageNumber == page.pageNumber - 1 }) else { return }

        // Capture original page numbers for cache update
        let originalPageNumber = page.pageNumber
        let adjacentPageNumber = adjacent.pageNumber

        let temp = page.pageNumber
        page.pageNumber = adjacent.pageNumber
        adjacent.pageNumber = temp

        // Update export cache with swapped page numbers
        TextExportCacheService.swapPageNumbers(originalPageNumber, adjacentPageNumber, in: document)

        refreshPageOrder()
    }

    /// Move current page down by swapping with adjacent page
    func moveCurrentPageDown() {
        guard let page = currentPage,
              let document = selectedDocument,
              let adjacent = document.pages.first(where: { $0.pageNumber == page.pageNumber + 1 }) else { return }

        // Capture original page numbers for cache update
        let originalPageNumber = page.pageNumber
        let adjacentPageNumber = adjacent.pageNumber

        let temp = page.pageNumber
        page.pageNumber = adjacent.pageNumber
        adjacent.pageNumber = temp

        // Update export cache with swapped page numbers
        TextExportCacheService.swapPageNumbers(originalPageNumber, adjacentPageNumber, in: document)

        refreshPageOrder()
    }

    /// Delete the current page from the document
    func deleteCurrentPage(modelContext: ModelContext) {
        guard let page = currentPage,
              let document = selectedDocument else { return }

        let deletedPageNumber = page.pageNumber

        // Remove page entry from export cache (also renumbers subsequent pages)
        TextExportCacheService.removeEntry(pageNumber: deletedPageNumber, from: document)

        // Decrement pageNumber for all pages after the deleted one
        for otherPage in document.pages where otherPage.pageNumber > deletedPageNumber {
            otherPage.pageNumber -= 1
        }

        // Remove from document's pages array
        document.pages.removeAll { $0.persistentModelID == page.persistentModelID }
        document.totalPages -= 1
        document.recalculateStorageSize()

        // Delete the page from the model context
        modelContext.delete(page)

        // Refresh navigation state
        refreshPageOrder()

        // Navigate to an adjacent page
        let newPageNumber = min(deletedPageNumber, document.totalPages)
        if newPageNumber > 0 {
            goToPage(pageNumber: newPageNumber)
        } else {
            currentPageNumber = nil
        }
    }

    var donePageCount: Int {
        selectedDocument?.pages.filter { $0.isDone }.count ?? 0
    }

    var totalPageCount: Int {
        selectedDocument?.pages.count ?? 0
    }

    var progress: Double {
        guard totalPageCount > 0 else { return 0 }
        return Double(donePageCount) / Double(totalPageCount)
    }

    // MARK: - Text Cache

    /// Rebuilds the full document text cache from all pages
    func rebuildTextCache() {
        guard let document = selectedDocument else {
            fullDocumentPlainText = ""
            fullDocumentAttributedText = AttributedString()
            return
        }

        let sortedPages = document.pages.sorted { $0.pageNumber < $1.pageNumber }

        // Build plain text version (for TTS, search, accessibility)
        fullDocumentPlainText = sortedPages.map { $0.plainText }.joined(separator: "\n\n")

        // Build attributed text version (preserves formatting)
        var attributed = AttributedString()
        for (index, page) in sortedPages.enumerated() {
            if index > 0 {
                attributed.append(AttributedString("\n\n"))
            }
            attributed.append(page.richText)
        }
        fullDocumentAttributedText = attributed
    }

    /// Refreshes page ordering arrays after pages have been reordered
    /// Call this after swapping page numbers to ensure navigation stays consistent
    func refreshPageOrder() {
        guard let document = selectedDocument else { return }
        originalOrder = document.pages.map { $0.pageNumber }.sorted()
        shuffledOrder = originalOrder.shuffled()
        rebuildTextCache()
        pageOrderVersion += 1
    }
}
