import SwiftUI
import SwiftData

struct ReviewView: View {
    let document: Document
    @StateObject private var navigationState = NavigationState()
    @State private var selectedPageNumber: Int?
    
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ThumbnailSidebar(
                    document: document,
                    navigationState: navigationState,
                    selectedPageNumber: $selectedPageNumber
                )
                .frame(width: geometry.size.width * 0.2)
                
                Divider()
                
                ImageViewer(
                    document: document,
                    navigationState: navigationState
                )
                .frame(width: geometry.size.width * 0.5)
                
                Divider()
                
                TextSidebar(
                    document: document,
                    navigationState: navigationState
                )
                .frame(width: geometry.size.width * 0.3)
            }
        }
        .navigationTitle(document.name)
        .navigationSubtitle("\(document.totalPages) pages")
        .toolbar {
            ToolbarItemGroup {
                Button(action: { navigationState.previousPage() }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!navigationState.hasPrevious)
                .keyboardShortcut("[", modifiers: [])
                
                Button(action: { navigationState.nextPage() }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!navigationState.hasNext)
                .keyboardShortcut("]", modifiers: [])
                
                Divider()
                
                Button(action: { navigationState.toggleRandomization() }) {
                    Image(systemName: navigationState.isRandomized ? "shuffle.circle.fill" : "shuffle.circle")
                }
                .help(navigationState.isRandomized ? "Sequential Order" : "Random Order")
                
                Divider()
                
                Button(action: copyCurrentPageText) {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy Current Page Text")
                
                Button(action: copyAllPagesText) {
                    Image(systemName: "doc.on.doc.fill")
                }
                .help("Copy All Pages Text")
            }
        }
        .onAppear {
            navigationState.setupNavigation(for: document)
            if let firstPage = navigationState.currentPage {
                selectedPageNumber = firstPage.pageNumber
            }
        }
        .onChange(of: navigationState.currentPageIndex) { _, _ in
            if let currentPage = navigationState.currentPage {
                selectedPageNumber = currentPage.pageNumber
            }
        }
    }
    
    private func copyCurrentPageText() {
        guard let currentPage = navigationState.currentPage else { return }
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(currentPage.text, forType: .string)
        
    }
    
    private func copyAllPagesText() {
        let sortedPages = document.pages.sorted { $0.pageNumber < $1.pageNumber }
        let allText = sortedPages
            .map { $0.text }
            .joined(separator: "\n\n")
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(allText, forType: .string)
        
    }
}