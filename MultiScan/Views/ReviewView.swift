import SwiftUI
import SwiftData

struct ReviewView: View {
    let document: Document
    @StateObject private var navigationState = NavigationState()
    @State private var selectedPageNumber: Int?
    @State private var leftColumnWidth: CGFloat = 200
    @State private var rightColumnWidth: CGFloat = 300
    @State private var showProgress: Bool = false
    
    var body: some View {
        HSplitView {
            ThumbnailSidebar(
                document: document,
                navigationState: navigationState,
                selectedPageNumber: $selectedPageNumber
            )
            .frame(minWidth: 150, idealWidth: 200)
            
            ImageViewer(
                document: document,
                navigationState: navigationState
            )
            .frame(minWidth: 400)
            
            TextSidebar(
                document: document,
                navigationState: navigationState
            )
            .frame(minWidth: 200, idealWidth: 300)
        }
        .navigationTitle(String(document.name.prefix(30)) + (document.name.count > 30 ? "..." : ""))
        .navigationSubtitle("\(document.totalPages) pages")
        .toolbar {
            ToolbarItemGroup {
                Button(action: { navigationState.previousPage() }) {
                    Label("Previous", systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                }
                .disabled(!navigationState.hasPrevious)
                .keyboardShortcut("[", modifiers: [])
                
                Button(action: { navigationState.nextPage() }) {
                    Label("Next", systemImage: "chevron.right")
                        .labelStyle(.iconOnly)
                }
                .disabled(!navigationState.hasNext)
                .keyboardShortcut("]", modifiers: [])
                
                Button(action: { navigationState.toggleRandomization() }) {
                    Label(navigationState.isRandomized ? "Sequential Order" : "Shuffled Order", systemImage: navigationState.isRandomized ? "shuffle.circle.fill" : "shuffle.circle")
                        .labelStyle(.iconOnly)
                }
                .help(navigationState.isRandomized ? "Switch to Sequential Order" : "Switch to Shuffled Order")
                
                Spacer()
                    .frame(width: 20)
                
                Button(action: { navigationState.toggleCurrentPageDone() }) {
                    Label("Mark as Reviewed", systemImage: navigationState.currentPage?.isDone == true ? "checkmark.circle.fill" : "checkmark.circle")
                        .labelStyle(.iconOnly)
                }
                .help(navigationState.currentPage?.isDone == true ? "Mark as Not Reviewed" : "Mark as Reviewed")
                
                Button(action: { showProgress.toggle() }) {
                    Label("Progress", systemImage: "flag.pattern.checkered")
                        .labelStyle(.iconOnly)
                }
                .popover(isPresented: $showProgress, arrowEdge: .bottom) {
                    ProgressPopover(navigationState: navigationState)
                }
                .help("View Progress")
                
                Spacer()
                    .frame(width: 20)
                
                Button(action: copyCurrentPageText) {
                    Label("Copy Page Text", systemImage: "document")
                        .labelStyle(.iconOnly)
                }
                .help("Copy Current Page Text")
                
                Button(action: copyAllPagesText) {
                    Label("Copy All Pages Text", systemImage: "doc.on.doc.fill")
                        .labelStyle(.iconOnly)
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
        
        TextFormatter.copyFormattedText(currentPage.text)
    }
    
    private func copyAllPagesText() {
        let sortedPages = document.pages.sorted { $0.pageNumber < $1.pageNumber }
        let allText = sortedPages
            .map { $0.text }
            .joined(separator: "\n\n")
        
        TextFormatter.copyFormattedText(allText)
    }
}
