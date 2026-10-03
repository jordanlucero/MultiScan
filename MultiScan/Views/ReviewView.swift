//
//  ReviewView.swift
//  MultiScan
//
//  The project review screen on every platform and size class.
//
//  One view owns the per-project session — `NavigationState`, the current page's `PageTextController`, the `SmartCleanupModel`, and every sheet/panel flag — and switches between two layouts by horizontal size class:
//  - **Regular** (macOS, iPad, wide iPhone): `NavigationSplitView` with the thumbnail sidebar, the image viewer as detail, and the text panel as an inspector.
//  - **Compact** (iPhone): `NavigationStack` around the image viewer, the text panel as a persistent bottom sheet, and a page-grid sheet in place of the sidebar.
//
//  The toolbar is declared once (`reviewToolbar`) and attached to the detail content in both layouts. Items whose presence depends on the size class use `.hidden(_:)`; page navigation carries `.visibilityPriority(.high)` so it outlasts the rest in a narrow window; only genuinely per-OS item sets (discrete Mac buttons vs. the iOS "More" menu) are split with `#if os`.
//

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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppRouter.self) private var router
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    @State private var navigationState = NavigationState()

    /// Editing controller for the current page; rebuilt on every page switch (`loadTextController`). Owned here, not by the text panel, so the compact "More" menu and Smart Cleanup can edit through it (with undo) whether or not the panel is on screen.
    @State private var textController: PageTextController?

    /// Smart Cleanup analysis + edits for this project.
    @State private var cleanup: SmartCleanupModel

    /// Shared import → OCR pipeline (also used by Home and the "Start New Project" intent).
    private let pipeline = ProjectImportPipeline.shared

    // Presentation state. Menu bar commands flip these through `FocusedValues`.
    @State private var showProgress = false
    @State private var showExportPanel = false
    @State private var showDeletePageConfirmation = false
    @State private var showAddFromPhotos = false
    @State private var showAddFromFiles = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isAddingPages = false

    /// Page number to insert new pages after (nil = append to end). Set by the iOS insert menus.
    @State private var insertAfterPageNumber: Int?

    // Compact layout: the text panel is a persistent sheet that steps aside while another sheet is up.
    @State private var showTextSheet = true
    @State private var showPageGrid = false

    // AppStorage-backed so the View menu toggles and the toolbar share one source of truth.
    @AppStorage(DefaultsKey.showThumbnails) private var showThumbnails = true
    @AppStorage(DefaultsKey.showTextPanel) private var showTextPanel = true
    @AppStorage(DefaultsKey.showSmartCleanup) private var showSmartCleanup = false
    @AppStorage(DefaultsKey.optimizeImagesOnImport) private var optimizeImagesOnImport = false

    init(document: Document, onDismiss: @escaping () -> Void) {
        self.document = document
        self.onDismiss = onDismiss
        _cleanup = State(initialValue: SmartCleanupModel(document: document))
    }

    /// Compact width selects the iPhone layout. Size classes don't exist on macOS.
    private var isCompact: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    #if os(macOS)
    private static let willTerminateNotification = NSApplication.willTerminateNotification
    #else
    private static let willTerminateNotification = UIApplication.willTerminateNotification
    #endif

    // MARK: - Body

    var body: some View {
        layout
            // Menu bar commands (MultiScanCommands) act on the focused window through these.
            .focusedSceneValue(\.navigationState, navigationState)
            .focusedSceneValue(\.showExportPanel, $showExportPanel)
            .focusedSceneValue(\.showAddFromPhotos, $showAddFromPhotos)
            .focusedSceneValue(\.showAddFromFiles, $showAddFromFiles)
            .focusedSceneValue(\.showDeletePageConfirmation, $showDeletePageConfirmation)
            #if os(iOS)
            // On iOS the progress button lives inside the More menu, so the popover can't anchor to it — attach it to the root instead.
            .popover(isPresented: $showProgress) { progressPopover }
            #endif
            .sheet(isPresented: $showExportPanel, onDismiss: restoreTextSheet) {
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
                        Task { await addPages(photos: items, insertAfter: insertAfterPageNumber) }
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
            .onAppear(perform: start)
            .onDisappear {
                // Save any pending edits when the project closes
                textController?.detach()
            }
            .onChange(of: navigationState.currentPage) { _, page in
                loadTextController(for: page)
            }
            .onChange(of: showSmartCleanup) {
                scheduleCleanupAnalysis()
            }
            .onChange(of: router.openRequest) {
                // Deep link (Spotlight page result, Open Page intent, search hit)
                router.fulfillOpenRequest(for: document, navigationState: navigationState)
            }
            .onChange(of: undoManager) { _, newValue in
                navigationState.undoManager = newValue
            }
            .onChange(of: showExportPanel) { _, showing in
                if showing { showTextSheet = false }
            }
            .onChange(of: showProgress) { _, showing in
                // The popover presents as a sheet on iPhone, where the text sheet must step aside.
                if isCompact { showTextSheet = !showing }
            }
            // Save protection beyond the controller's debounce: backgrounding (iOS apps are rarely quit explicitly) and termination (catches a quit mid-debounce).
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { saveNow() }
            }
            .onReceive(NotificationCenter.default.publisher(for: Self.willTerminateNotification)) { _ in
                saveNow()
            }
    }

    // MARK: - Layouts

    @ViewBuilder
    private var layout: some View {
        #if os(iOS)
        if isCompact {
            compactLayout
        } else {
            regularLayout
        }
        #else
        regularLayout
        #endif
    }

    /// The split view's column visibility, derived from `showThumbnails` so the sidebar toggle animates and the setting persists without a second copy of the state.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { showThumbnails ? .all : .detailOnly },
            set: { showThumbnails = $0 != .detailOnly }
        )
    }

    private var regularLayout: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
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
        } detail: {
            detailContent
        }
        .inspector(isPresented: $showTextPanel) {
            textPanel(hideBottomPanels: false)
                .inspectorColumnWidth(min: 250, ideal: 350, max: 500)
        }
    }

    #if os(iOS)
    private var compactLayout: some View {
        NavigationStack {
            detailContent
                .navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $showTextSheet) {
                    textPanel(hideBottomPanels: true)
                        .presentationDetents([.height(120), .fraction(0.3), .medium, .large])
                        .presentationDragIndicator(.visible)
                        .presentationBackgroundInteraction(.enabled(upThrough: .large))
                        .interactiveDismissDisabled()
                }
                .sheet(isPresented: $showPageGrid, onDismiss: restoreTextSheet) {
                    SlideGridView(
                        document: document,
                        navigationState: navigationState,
                        onAddPhotos: { insertAfter, items in
                            Task { await addPages(photos: items, insertAfter: insertAfter) }
                        },
                        onAddFiles: { insertAfter, urls in
                            Task { await addPages(fileURLs: urls, insertAfter: insertAfter) }
                        }
                    )
                }
                .onChange(of: showPageGrid) { _, showing in
                    if showing { showTextSheet = false }
                }
        }
    }
    #endif

    /// The image viewer with the title, toolbar, and rotors — the detail column of the split view and the root of the compact stack.
    @ViewBuilder
    private var detailContent: some View {
        let viewer = ImageViewer(navigationState: navigationState)
            // Onscreen awareness: lets Siri/Apple Intelligence refer to "this page".
            .appEntityIdentifier(currentPageEntityIdentifier)
            .toolbarRole(.editor)
            .toolbar { reviewToolbar }
            .modifier(PageRotors(pages: sortedPages) { pageNumber in
                navigationState.goToPage(pageNumber: pageNumber)
            })

        if isCompact {
            // No title in the compact bar: the space goes to the toolbar items.
            viewer.navigationTitle("")
        } else {
            viewer
                .navigationTitle(navigationTitle)
                .navigationSubtitle(Text(document.totalPages == 1 ? "1 page" : "\(document.totalPages) pages"))
        }
    }

    private func textPanel(hideBottomPanels: Bool) -> some View {
        RichTextSidebar(
            document: document,
            navigationState: navigationState,
            textController: textController,
            cleanup: cleanup,
            hideBottomPanels: hideBottomPanels,
            onApplyCleanup: applyCleanupOption
        )
    }

    private var progressPopover: some View {
        ProgressPopover(
            donePageCount: navigationState.donePageCount,
            totalPageCount: navigationState.totalPageCount
        )
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

    /// Sorted pages for rotor navigation
    private var sortedPages: [Page] {
        document.unwrappedPages.sorted(by: { $0.pageNumber < $1.pageNumber })
    }

    // MARK: - Toolbar

    /// `.navigation` is swallowed by the sidebar toggle in an iPadOS split-view detail column (the long-standing missing Back button on iPad and wide iPhones); the explicit leading placement sits beside the toggle instead.
    private var backButtonPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    @ToolbarContentBuilder
    private var reviewToolbar: some ToolbarContent {
        ToolbarItem(placement: backButtonPlacement) {
            Button(action: onDismiss) {
                Label("Back", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel("Back to Projects")
            .help("Back to Projects")
        }
        .visibilityPriority(.high)

        // Page navigation outlasts everything else when the window narrows. (⌘[ / ⌘] shortcuts live on the View menu commands.)
        ToolbarItemGroup(placement: .primaryAction) {
            Button { navigationState.previousPage() } label: {
                Label("Previous Page", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
            }
            .disabled(!navigationState.hasPrevious)
            .help("Previous Page")

            Button { navigationState.nextPage() } label: {
                Label("Next Page", systemImage: "chevron.right")
                    .labelStyle(.iconOnly)
            }
            .disabled(!navigationState.hasNext)
            .help("Next Page")
        }
        .visibilityPriority(.high)

        #if os(iOS)
        // Compact width has no thumbnail sidebar; the page grid sheet stands in for it.
        ToolbarItem(placement: .primaryAction) {
            Button { showPageGrid = true } label: {
                Label("Pages", systemImage: "square.grid.3x3")
            }
        }
        .hidden(!isCompact)

        ToolbarItem(placement: .primaryAction) {
            moreMenu
        }
        #else
        macToolbarItems
        #endif
    }

    #if os(macOS)
    /// Discrete buttons: page order, review status + progress, text panel. Spacers separate the groups; the edit buttons come from RichTextSidebar.
    @ToolbarContentBuilder
    private var macToolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: { navigationState.toggleRandomization() }) {
                Label(navigationState.isRandomized ? "Switch to Sequential Order" : "Switch to Shuffled Order",
                      systemImage: navigationState.isRandomized ? "shuffle.circle.fill" : "shuffle.circle")
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel("Page Order")
            .accessibilityValue(navigationState.isRandomized ? "Shuffled" : "Sequential")
            .help(navigationState.isRandomized ? "Switch to Sequential Order" : "Switch to Shuffled Order")

            Spacer().frame(width: 20)

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
                progressPopover
            }
            .accessibilityLabel("View Progress")
            .accessibilityValue("\(navigationState.donePageCount) of \(navigationState.totalPageCount) reviewed")
            .help("View Progress")

            Spacer().frame(width: 20)

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

    #if os(iOS)
    /// Everything beyond page navigation, on iPhone and iPad alike. Size-class differences stay inside: Smart Cleanup lives here on iPhone (the inspector pane shows it on iPad), the text panel toggle only applies where there is an inspector.
    private var moreMenu: some View {
        Menu {
            if isCompact {
                Section("Smart Cleanup") {
                    Button { textController?.removeLineBreaks() } label: {
                        Label("Remove Line Breaks", systemImage: "line.3.horizontal")
                    }
                    .disabled(textController == nil)

                    smartCleanupMenuItems
                }

                Divider()
            }

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
            if !isCompact {
                Button { showTextPanel.toggle() } label: {
                    Label(
                        showTextPanel ? "Hide Text Panel" : "Show Text Panel",
                        systemImage: "sidebar.right"
                    )
                }
                .keyboardShortcut("i", modifiers: [.command, .option])

                Divider()
            }

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

    @ViewBuilder
    private var smartCleanupMenuItems: some View {
        if cleanup.isAnalyzing {
            Label("Checking…", systemImage: "sparkle.magnifyingglass")
        } else if !cleanup.options.isEmpty {
            Menu {
                ForEach(cleanup.options) { option in
                    Button(option.label) {
                        applyCleanupOption(option)
                    }
                }
            } label: {
                Label("\(cleanup.options.count) suggestions", systemImage: "sparkles")
            }
        } else {
            Label("No suggestions", systemImage: "sparkles")
        }
    }
    #endif

    // MARK: - Session

    private func start() {
        navigationState.setupNavigation(for: document)
        navigationState.undoManager = undoManager
        router.fulfillOpenRequest(for: document, navigationState: navigationState)
        loadTextController(for: navigationState.currentPage)

        // Announce document opening for VoiceOver users
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            AccessibilityNotification.Announcement(String(localized: "\(document.name) opened. \(document.totalPages) pages.")).post()
        }
    }

    /// Saves the outgoing page and severs its view link (so a late debounce can never read another page's storage), then builds the controller for the new page.
    private func loadTextController(for page: Page?) {
        guard textController?.page !== page else { return }
        textController?.detach()
        textController = page.map { PageTextController(page: $0) }
        scheduleCleanupAnalysis()
    }

    /// Rebuilds the controller on the page's stored text after it was rewritten behind the editor's back (batch Smart Cleanup).
    private func reloadTextController() {
        textController?.detach()
        textController = navigationState.currentPage.map { PageTextController(page: $0) }
    }

    private func saveNow() {
        textController?.saveNow()
        // Force the disk write now rather than at the next autosave
        try? modelContext.save()
    }

    private func restoreTextSheet() {
        showTextSheet = true
    }

    // MARK: - Smart Cleanup

    /// Analysis only runs where its results are shown: the Smart Cleanup pane when enabled (macOS/iPad), or always on iPhone, where the More menu shows them.
    private func scheduleCleanupAnalysis() {
        cleanup.scheduleAnalysis(
            forPage: navigationState.currentPage?.pageNumber,
            enabled: isCompact || showSmartCleanup
        )
    }

    /// Applies a cleanup option through the live editor where possible, so current-page edits land on its undo stack. Batch edits that rewrite the current page behind the editor's back report back, and the controller is rebuilt on the fresh text.
    private func applyCleanupOption(_ option: TextManipulationService.CleanupOption) {
        let needsReload = cleanup.apply(
            option,
            currentPageNumber: navigationState.currentPageNumber,
            liveController: textController
        )
        if needsReload {
            reloadTextController()
        }
    }

    // MARK: - Adding Pages

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            Task { await addPages(fileURLs: urls, insertAfter: insertAfterPageNumber) }
        case .failure(let error):
            print("File import error: \(error)")
        }
    }

    private func addPages(fileURLs urls: [URL], insertAfter: Int?) async {
        isAddingPages = true
        defer { isAddingPages = false }

        do {
            let prepared = try await pipeline.prepare(urls: urls, optimizeImages: optimizeImagesOnImport)
            await addPages(images: prepared.images, insertAfter: insertAfter)
        } catch {
            print("Import error: \(error)")
        }
    }

    private func addPages(photos items: [PhotosPickerItem], insertAfter: Int?) async {
        guard !items.isEmpty else { return }

        isAddingPages = true
        defer {
            isAddingPages = false
            showAddFromPhotos = false
            selectedPhotos = []
        }

        let images = await pipeline.loadPhotos(items, optimizeImages: optimizeImagesOnImport)
        await addPages(images: images, insertAfter: insertAfter)
    }

    /// Runs OCR and adds the pages. `insertAfter` nil appends; 0 inserts at the beginning (iOS insert menus).
    private func addPages(images: [(data: Data, fileName: String)], insertAfter: Int?) async {
        defer { insertAfterPageNumber = nil }
        guard !images.isEmpty else { return }

        do {
            let result = try await pipeline.addPages(
                to: document,
                images: images,
                insertAfter: insertAfter,
                in: modelContext
            )

            // Pick up the new page numbers without resetting the current page, then show the first new page.
            navigationState.refreshPageOrder()
            if let firstNew = result.firstNewPageNumber {
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
                    AccessibilityRotorEntry(page.title, id: page.pageNumber) {
                        onSelect(page.pageNumber)
                    }
                }
            }
            .accessibilityRotor("Unreviewed") {
                // `pages` is already sorted, so filtering preserves page order.
                ForEach(pages.filter { !$0.isDone }) { page in
                    AccessibilityRotorEntry(page.title, id: page.pageNumber) {
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
