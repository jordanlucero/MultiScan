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
        guard let document = selectedDocument else { return false }
        
        var nextIndex = currentPageIndex + 1
        while nextIndex < currentOrder.count {
            let pageNumber = currentOrder[nextIndex]
            if let page = document.pages.first(where: { $0.pageNumber == pageNumber }), !page.isDone {
                return true
            }
            nextIndex += 1
        }
        return false
    }
    
    var hasPrevious: Bool {
        guard let document = selectedDocument else { return false }
        
        var prevIndex = currentPageIndex - 1
        while prevIndex >= 0 {
            let pageNumber = currentOrder[prevIndex]
            if let page = document.pages.first(where: { $0.pageNumber == pageNumber }), !page.isDone {
                return true
            }
            prevIndex -= 1
        }
        return false
    }
    
    func setupNavigation(for document: Document) {
        selectedDocument = document
        originalOrder = document.pages.map { $0.pageNumber }.sorted()
        randomizedOrder = originalOrder.shuffled()
        currentPageIndex = 0
        
        // Find first undone page
        var index = 0
        while index < currentOrder.count {
            let pageNumber = currentOrder[index]
            if let page = document.pages.first(where: { $0.pageNumber == pageNumber }), !page.isDone {
                currentPageIndex = index
                return
            }
            index += 1
        }
        
        // If all pages are done, stay at index 0
        currentPageIndex = 0
    }
    
    func nextPage() {
        guard let document = selectedDocument else { return }
        
        var nextIndex = currentPageIndex + 1
        while nextIndex < currentOrder.count {
            let pageNumber = currentOrder[nextIndex]
            if let page = document.pages.first(where: { $0.pageNumber == pageNumber }), !page.isDone {
                currentPageIndex = nextIndex
                return
            }
            nextIndex += 1
        }
    }
    
    func previousPage() {
        guard let document = selectedDocument else { return }
        
        var prevIndex = currentPageIndex - 1
        while prevIndex >= 0 {
            let pageNumber = currentOrder[prevIndex]
            if let page = document.pages.first(where: { $0.pageNumber == pageNumber }), !page.isDone {
                currentPageIndex = prevIndex
                return
            }
            prevIndex -= 1
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
    
    func toggleCurrentPageDone() {
        currentPage?.isDone.toggle()
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
}