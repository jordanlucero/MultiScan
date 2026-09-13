import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers
import AppIntents

struct ReviewView: View {
    let document: Document
    var onDismiss: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager) private var undoManager
    @Environment(AppRouter.self) private var router
    @State private var navigationState = NavigationState()

    /// Shared import → OCR pipeline (also used by Home and the "Start New Project" intent).
    private let pipeline = ProjectImportPipeline.shared

    @State private var showProgress: Bool = false
    @State private var showExportPanel: Bool = false
    @State private var showDeletePageConfirmation: Bool = false

    // Add pages state
    @State private var showAddFromPhotos: Bool = false
    @State private var showAddFromFiles: Bool = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isAddingPages: Bool = false

    /// Page number to insert new pages after (nil = append to end). Set by iOS insert menus.
    @State private var insertAfterPageNumber: Int?

    // AppStorage-backed so the View menu toggles and the toolbar buttons share one source of truth.
    @AppStorage("showThumbnails") private var showThumbnails = true
    @AppStorage("showTextPanel") private var showTextPanel = true
    @AppStorage("optimizeImagesOnImport") private var optimizeImagesOnImport = false

    /// The split view's column visibility, derived from `showThumbnails` so the sidebar toggle animates and the setting persists without a second copy of the state.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { showThumbnails ? .all : .detailOnly },
            set: { showThumbnails = $0 != .detailOnly }
        )
    }

    /// Sorted pages for rotor navigation
    private var sortedPages: [Page] {
        document.unwrappedPages.sorted(by: { $0.pageNumber < $1.pageNumber })
    }

    var body: some View {
        mainContent
            #if os(iOS)
            // On iOS the progress button lives inside the More menu, so the popover can't anchor to it — attach it to the root instead.
            .popover(isPresented: $showProgress) {
                ProgressPopover(
                    donePageCount: navigationState.donePageCount,
                    totalPageCount: navigationState.totalPageCount
                )
            }
            #endif
            .sheet(isPresented: $showExportPanel) {
                ExportPanelView(document: document)
            }
            .sheet(isPresented: $showAddFromPhotos) {
                AddPagesFromPhotosSheet(
                    selectedPhotos: $selectedPhotos,
                    isAddingPages: isAddingPages,
                    onCancel: {
                        showAddFromPhotos = false
                        selectedPhotos = []
                    },
                    onSelectionChanged: { items in
                        Task { await processSelectedPhotos(items) }
                    }
                )
            }
            .fileImporter(
                isPresented: $showAddFromFiles,
                allowedContentTypes: [.image, .pdf, .folder],
                allowsMultipleSelection: true
            ) { result in
                handleFileImport(result)
            }
            .deletePageConfirmation(isPresented: $showDeletePageConfirmation, pageNumber: navigationState.currentPageNumber ?? 0) {
                navigationState.deleteCurrentPage(modelContext: modelContext)
            }
            .onAppear {
                navigationState.setupNavigation(for: document)
                navigationState.undoManager = undoManager
                router.fulfillOpenRequest(for: document, navigationState: navigationState)

                // Announce document opening for VoiceOver users
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    AccessibilityNotification.Announcement(String(localized: "\(document.name) opened. \(document.totalPages) pages.")).post()
                }
            }
            .onChange(of: router.openRequest) {
                // Deep link (Spotlight page result, Open Page intent, search hit)
                router.fulfillOpenRequest(for: document, navigationState: navigationState)
            }
            .onChange(of: undoManager) { _, newValue in
                navigationState.undoManager = newValue
            }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        splitView
            // Menu bar commands (MultiScanCommands) act on the focused window through these.
            .focusedSceneValue(\.navigationState, navigationState)
            .focusedSceneValue(\.showExportPanel, $showExportPanel)
            .focusedSceneValue(\.showAddFromPhotos, $showAddFromPhotos)
            .focusedSceneValue(\.showAddFromFiles, $showAddFromFiles)
            .focusedSceneValue(\.showDeletePageConfirmation, $showDeletePageConfirmation)
            // Onscreen awareness: lets Siri/Apple Intelligence refer to "this page".
            .appEntityIdentifier(currentPageEntityIdentifier)
            .navigationTitle(navigationTitle)
            .navigationSubtitle(Text(document.totalPages == 1 ? "1 page" : "\(document.totalPages) pages"))
            .toolbarRole(.editor)
            .toolbar { toolbarContent }
            .modifier(PageRotors(pages: sortedPages) { pageNumber in
                navigationState.goToPage(pageNumber: pageNumber)
            })
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            #if os(iOS)
            ThumbnailSidebar(
                document: document,
                navigationState: navigationState,
                onInsertFromPhotos: { insertAfter in
                    insertAfterPageNumber = insertAfter
                    showAddFromPhotos = true
                },
                onInsertFromFiles: { insertAfter in
                    insertAfterPageNumber = insertAfter
                    showAddFromFiles = true
                }
            )
            .navigationSplitViewColumnWidth(min: 150, ideal: 200, max: 400)
            #else
            ThumbnailSidebar(document: document, navigationState: navigationState)
                .navigationSplitViewColumnWidth(min: 150, ideal: 200, max: 400)
            #endif
        } detail: {
            ImageViewer(navigationState: navigationState)
        }
        .inspector(isPresented: $showTextPanel) {
            RichTextSidebar(
                document: document,
                navigationState: navigationState
            )
            .inspectorColumnWidth(min: 250, ideal: 350, max: 500)
        }
    }

    private var currentPageEntityIdentifier: EntityIdentifier? {
        navigationState.currentPage?.uuid.map { EntityIdentifier(for: PageEntity.self, identifier: $0) }
    }

    private var navigationTitle: String {
        let name = document.name
        if name.count > 30 {
            return String(name.prefix(30)) + "…"
        }
        return name
    }

    // MARK: - Toolbar Content

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(iOS)
        iOSToolbarContent
        #else
        macToolbarContent
        #endif
    }

    #if os(iOS)
    // iPad toolbar: page navigation stays visible; everything else lives in a "More" menu.
    @ToolbarContentBuilder
    private var iOSToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: onDismiss) {
                Label("Back", systemImage: "chevron.left")
            }
            .accessibilityLabel("Back to Projects")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { navigationState.previousPage() } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(!navigationState.hasPrevious)

            Button { navigationState.nextPage() } label: {
                Label("Next", systemImage: "chevron.right")
            }
            .disabled(!navigationState.hasNext)

            Menu {
                // Review
                PageReviewStatusButton(navigationState: navigationState)
                PageOrderButton(navigationState: navigationState)

                Button { showProgress.toggle() } label: {
                    Label("View Progress", systemImage: "flag.pattern.checkered")
                }

                Divider()

                // Image adjustments
                if let page = navigationState.currentPage {
                    Section("Image") {
                        PageRotationButtons(page: page)
                        PageAdjustmentToggles(page: page)
                    }

                    Divider()
                }

                // Panels
                Button { showTextPanel.toggle() } label: {
                    Label(
                        showTextPanel ? "Hide Text Panel" : "Show Text Panel",
                        systemImage: "sidebar.right"
                    )
                }
                .keyboardShortcut("i", modifiers: [.command, .option])

                Divider()

                // Export
                Section("Export") {
                    ExportProjectTextButton { showExportPanel = true }
                }

                Divider()

                // Statistics
                if let page = navigationState.currentPage {
                    PageStatisticsLabel(page: page)
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
    #else
    @ToolbarContentBuilder
    private var macToolbarContent: some ToolbarContent {
        // Back button in navigation position
        ToolbarItem(placement: .navigation) {
            Button(action: onDismiss) {
                Label("Back", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel("Back to Projects")
            .help("Back to Projects")
        }

        // All main toolbar items grouped on the trailing side
        // Using .primaryAction keeps them together on the right
        // Spacers create visual separation between logical groups
        ToolbarItemGroup(placement: .primaryAction) {
            // Group 1: Page navigation
            Button(action: { navigationState.previousPage() }) {
                Label("Previous Page", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
            }
            .disabled(!navigationState.hasPrevious)
            .keyboardShortcut("[", modifiers: [])

            Button(action: { navigationState.nextPage() }) {
                Label("Next Page", systemImage: "chevron.right")
                    .labelStyle(.iconOnly)
            }
            .disabled(!navigationState.hasNext)
            .keyboardShortcut("]", modifiers: [])

            Button(action: { navigationState.toggleRandomization() }) {
                Label(navigationState.isRandomized ? "Switch to Sequential Order" : "Switch to Shuffled Order",
                      systemImage: navigationState.isRandomized ? "shuffle.circle.fill" : "shuffle.circle")
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel("Page Order")
            .accessibilityValue(navigationState.isRandomized ? "Shuffled" : "Sequential")
            .help(navigationState.isRandomized ? "Switch to Sequential Order" : "Switch to Shuffled Order")

            //ToolbarSpacer(.fixed)
            Spacer().frame(width: 20)

            // Group 2: Review status
            Button(action: { navigationState.toggleCurrentPageDone() }) {
                Label("Mark as Reviewed",
                      systemImage: navigationState.currentPage?.isDone == true ? "checkmark.circle.fill" : "checkmark.circle")
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel("Review Status")
            .accessibilityValue(navigationState.currentPage?.isDone == true ? "Reviewed" : "Not reviewed")
            .help(navigationState.currentPage?.isDone == true ? "Mark Page as Not Reviewed" : "Mark Page as Reviewed")

            Button(action: { showProgress.toggle() }) {
                Label("Progress", systemImage: "flag.pattern.checkered")
                    .labelStyle(.iconOnly)
            }
            .popover(isPresented: $showProgress, arrowEdge: .bottom) {
                ProgressPopover(
                    donePageCount: navigationState.donePageCount,
                    totalPageCount: navigationState.totalPageCount
                )
            }
            .accessibilityLabel("View Progress")
            .accessibilityValue("\(navigationState.donePageCount) of \(navigationState.totalPageCount) reviewed")
            .help("View Progress")

            //ToolbarSpacer(.fixed)
            Spacer().frame(width: 20)

            // Group 3: Inspector toggle (edit buttons come from RichTextSidebar)
            Button(action: { showTextPanel.toggle() }) {
                Label("Show Text Panel", systemImage: "sidebar.right")
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel("Text Panel")
            .accessibilityValue(showTextPanel ? "Showing" : "Hidden")
            .help(showTextPanel ? "Hide Text Panel" : "Show Text Panel")
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
    #endif

    // MARK: - File Import Handling

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            Task {
                await processFileURLs(urls)
            }
        case .failure(let error):
            print("File import error: \(error)")
        }
    }

    @MainActor
    private func processFileURLs(_ urls: [URL]) async {
        isAddingPages = true
        defer { isAddingPages = false }

        do {
            let prepared = try await pipeline.prepare(urls: urls, optimizeImages: optimizeImagesOnImport)
            guard !prepared.images.isEmpty else { return }
            await addPagesToDocument(images: prepared.images)
        } catch {
            print("Import error: \(error)")
        }
    }

    // MARK: - Photos Import Handling

    @MainActor
    private func processSelectedPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }

        isAddingPages = true
        defer {
            isAddingPages = false
            showAddFromPhotos = false
            selectedPhotos = []
        }

        let images = await pipeline.loadPhotos(items, optimizeImages: optimizeImagesOnImport)

        guard !images.isEmpty else { return }

        await addPagesToDocument(images: images)
    }

    // MARK: - Add Pages to Document

    @MainActor
    private func addPagesToDocument(images: [(data: Data, fileName: String)]) async {
        // Insert after a specific page (iOS insert menus) or append to the end (default).
        let insertAfter = insertAfterPageNumber
        defer { insertAfterPageNumber = nil }

        do {
            let result = try await pipeline.addPages(
                to: document,
                images: images,
                insertAfter: insertAfter,
                in: modelContext
            )

            // Refresh navigation state with new pages
            navigationState.setupNavigation(for: document)

            // Navigate to the first inserted page so the user sees the result
            if !result.isAppend, let firstNew = result.firstNewPageNumber {
                navigationState.goToPage(pageNumber: firstNew)
            }
        } catch {
            print("Failed to add pages: \(error)")
        }
    }
}

// MARK: - Accessibility Rotors

/// Both rotors derive from one sorted array
private struct PageRotors: ViewModifier {
    let pages: [Page]
    let onSelect: (Int) -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityRotor("Pages") {
                ForEach(pages) { page in
                    AccessibilityRotorEntry(page.rotorLabel, id: page.pageNumber) {
                        onSelect(page.pageNumber)
                    }
                }
            }
            .accessibilityRotor("Unreviewed") {
                // `pages` is already sorted, so filtering preserves page order.
                ForEach(pages.filter { !$0.isDone }) { page in
                    AccessibilityRotorEntry(page.rotorLabel, id: page.pageNumber) {
                        onSelect(page.pageNumber)
                    }
                }
            }
    }
}

// MARK: - Add Pages from Photos Sheet

struct AddPagesFromPhotosSheet: View {
    @Binding var selectedPhotos: [PhotosPickerItem]
    let isAddingPages: Bool
    let onCancel: () -> Void
    let onSelectionChanged: ([PhotosPickerItem]) -> Void

    /// Read here rather than in ReviewView's body so import progress ticks don't invalidate the split view behind the sheet.
    private let pipeline = ProjectImportPipeline.shared

    var body: some View {
        VStack(spacing: 20) {
            Text("Append Pages from Photos")
                .font(.headline)

            if isAddingPages {
                ProgressView("Processing \(Int(pipeline.progress * 100), format: .percent)")
                    .progressViewStyle(.linear)
            } else {
                PhotosPicker(
                    selection: $selectedPhotos,
                    maxSelectionCount: nil,
                    matching: .images
                ) {
                    Label("Select Photos", systemImage: "photo.on.rectangle")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .onChange(of: selectedPhotos) { _, items in
                    onSelectionChanged(items)
                }
            }

            Button("Cancel") {
                onCancel()
            }
            .disabled(isAddingPages)
        }
        .padding(40)
    }
}

