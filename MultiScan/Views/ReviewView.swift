import SwiftUI
import SwiftData

struct ReviewView: View {
    let document: Document
    @StateObject private var navigationState = NavigationState()
    @State private var selectedPageNumber: Int?
    @State private var showProgress: Bool = false

    // Use proper NavigationSplitViewVisibility type for animated sidebar transitions
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @AppStorage("showThumbnails") private var showThumbnails = true

    // Use AppStorage directly for inspector to sync with menu commands
    @AppStorage("showTextPanel") private var inspectorIsShown = true

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar: Thumbnail list
            ThumbnailSidebar(
                document: document,
                navigationState: navigationState,
                selectedPageNumber: $selectedPageNumber
            )
            .navigationSplitViewColumnWidth(min: 150, ideal: 200, max: 400)
        } detail: {
            // Detail: Main content area with image viewer
            ImageViewer(
                document: document,
                navigationState: navigationState
            )
        }
        .inspector(isPresented: $inspectorIsShown) {
            RichTextSidebar(
                document: document,
                navigationState: navigationState
            )
            .inspectorColumnWidth(min: 250, ideal: 350, max: 500)
        }
        .focusedValue(\.document, document)
        .focusedValue(\.navigationState, navigationState)
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
                    Label("Copy All Pages Text", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .help("Copy All Pages Text")

                Spacer()
                    .frame(width: 20)

                Button(action: { inspectorIsShown.toggle() }) {
                    Label("Show Text Panel", systemImage: "sidebar.right")
                        .labelStyle(.iconOnly)
                }
                .help(inspectorIsShown ? "Hide Text Panel" : "Show Text Panel")
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
        .onAppear {
            navigationState.setupNavigation(for: document)
            if let firstPage = navigationState.currentPage {
                selectedPageNumber = firstPage.pageNumber
            }
            // Initialize columnVisibility from persisted AppStorage value
            columnVisibility = showThumbnails ? .all : .detailOnly
        }
        .onChange(of: navigationState.currentPageIndex) { _, _ in
            if let currentPage = navigationState.currentPage {
                selectedPageNumber = currentPage.pageNumber
            }
        }
        // Sync columnVisibility when AppStorage changes (e.g., from menu command)
        .onChange(of: showThumbnails) { _, newValue in
            columnVisibility = newValue ? .all : .detailOnly
        }
        // Persist columnVisibility changes back to AppStorage (e.g., from system sidebar button)
        .onChange(of: columnVisibility) { _, newValue in
            let shouldShow = (newValue != .detailOnly)
            if showThumbnails != shouldShow {
                showThumbnails = shouldShow
            }
        }
    }
    
    private func copyCurrentPageText() {
        guard let currentPage = navigationState.currentPage else { return }
        TextFormatter.copyPageText(currentPage)
    }

    private func copyAllPagesText() {
        TextFormatter.copyAllPagesText(document.pages)
    }
}
