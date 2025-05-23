import Foundation
import SwiftUI

@MainActor
class NavigationState: ObservableObject {
    @Published var currentPageIndex: Int = 0
    @Published var isRandomized: Bool = true
    @Published var selectedDocument: Document?
    
    private var originalOrder: [Int] = []
    private var randomizedOrder: [Int] = []
    
    var currentOrder: [Int] {
        isRandomized ? randomizedOrder : originalOrder
    }
    
    var currentPage: Page? {
        guard let document = selectedDocument,
              currentPageIndex < currentOrder.count else { return nil }
        
        let pageNumber = currentOrder[currentPageIndex]
        return document.pages.first { $0.pageNumber == pageNumber }
    }
    
    var hasNext: Bool {
        currentPageIndex < currentOrder.count - 1
    }
    
    var hasPrevious: Bool {
        currentPageIndex > 0
    }
    
    func setupNavigation(for document: Document) {
        selectedDocument = document
        originalOrder = document.pages.map { $0.pageNumber }.sorted()
        randomizedOrder = originalOrder.shuffled()
        currentPageIndex = 0
    }
    
    func nextPage() {
        if hasNext {
            currentPageIndex += 1
        }
    }
    
    func previousPage() {
        if hasPrevious {
            currentPageIndex -= 1
        }
    }
    
    func goToPage(pageNumber: Int) {
        if let index = currentOrder.firstIndex(of: pageNumber) {
            currentPageIndex = index
        }
    }
    
    func toggleRandomization() {
        isRandomized.toggle()
        if let currentPageNumber = currentPage?.pageNumber {
            goToPage(pageNumber: currentPageNumber)
        }
    }
}