import Foundation
import SwiftUI
import SwiftData

@MainActor
class NavigationState: ObservableObject {
    @Published var isRandomized: Bool = true
    @Published var selectedDocument: Document?

    // Sequential mode: index into originalOrder
    @Published private var sequentialIndex: Int = 0

    // Shuffled mode: history-based navigation
    private var shuffledOrder: [Int] = []
    private var visitHistory: [Int] = []  // Page numbers in order visited
    @Published private var historyIndex: Int = -1    // Current position in visitHistory

    private var originalOrder: [Int] = []

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
            // Shuffled mode: can go next if there's an undone page OTHER than current
            return findNextUndoneInShuffledOrder(from: currentPageNumber, in: document) != nil
        } else {
            // Sequential mode: can go next if not at the last page
            return sequentialIndex < originalOrder.count - 1
        }
    }

    var hasPrevious: Bool {
        guard selectedDocument != nil else { return false }

        if isRandomized {
            // Shuffled mode: can go back if there's history behind us
            return historyIndex > 0
        } else {
            // Sequential mode: can go back if not at the first page
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
            nextPageShuffled()
        } else {
            nextPageSequential()
        }
    }

    func previousPage() {
        guard selectedDocument != nil else { return }

        if isRandomized {
            previousPageShuffled()
        } else {
            previousPageSequential()
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
        let temp = page.pageNumber
        page.pageNumber = adjacent.pageNumber
        adjacent.pageNumber = temp
        refreshPageOrder()
    }

    /// Move current page down by swapping with adjacent page
    func moveCurrentPageDown() {
        guard let page = currentPage,
              let document = selectedDocument,
              let adjacent = document.pages.first(where: { $0.pageNumber == page.pageNumber + 1 }) else { return }
        let temp = page.pageNumber
        page.pageNumber = adjacent.pageNumber
        adjacent.pageNumber = temp
        refreshPageOrder()
    }

    /// Delete the current page from the document
    func deleteCurrentPage(modelContext: ModelContext) {
        guard let page = currentPage,
              let document = selectedDocument else { return }

        let deletedPageNumber = page.pageNumber

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
