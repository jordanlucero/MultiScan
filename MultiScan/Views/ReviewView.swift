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
//  ## 2.0 sessions owned here
//  - **Artwork capture** (`captureSession`): opened from the viewer's context menu (seeded at the pointer), the Edit/More menu, a page's context menu, or an existing capture's "Recapture…". Presented as a sheet (regular) or full-screen cover (compact). On completion the reference attachment goes into the live editor (`PageTextController.insertCapture`) when the captured page is the current one, or into the page's stored text otherwise.
//  - **Digest** (`showDigest`), **Page Numbering** (`showPageNumbering`), and the current page's **chapter editor** (`showChapterEditor`) — all reachable from the menu bar through `FocusedValues`. Digest has exactly two entry points: View ▸ Read in Digest in the menu bar (macOS and iPadOS), and on iOS/iPadOS a toolbar button with low visibility priority, so it is the first thing to fold into the toolbar's overflow when space runs out.
//  - **Smart Separate after import** (`smartSeparate`) and the page operations that rewrite text behind the editor — rejoining separated pages, reading a page again, restoring Apple Vision's text (`pendingOperation` → confirmation → `perform`). All of them are offered through one `PageActions` value (`pageActions`) handed to the sidebar, the page grid, the More menu, and — via `FocusedValues.pageActions` — the menu bar.
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

    // 2.0 sessions
    @State private var captureSession: ArtworkCaptureSession?
    @State private var showArtworkCapture = false   // menu-bar trigger; opens `captureSession` centered on the current page
    @State private var showDigest = false
    @State private var showPageNumbering = false
    @State private var showChapterEditor = false
    @State private var chapterTitleDraft = ""

    /// Smart Separate after import (one page or the whole project).
    @State private var smartSeparate = SmartSeparateModel()
    /// The page on screen when a separation started; navigation is pinned to it while later pages are renumbered.
    @State private var pageBeforeSeparation: PersistentIdentifier?
    /// A page operation waiting for the user's confirmation (each one rewrites page text).
    @State private var pendingOperation: PendingPageOperation?
    /// The separated page whose original (whole) scan is being shown.
    @State private var originalScanPage: Page?
    /// Shown while a page operation runs.
    @State private var busyMessage: String?
    @State private var operationError: String?

    /// Page number to insert new pages after (nil = append to end). Set by the iOS insert menus.
    @State private var insertAfterPageNumber: Int?

    // Compact layout: the text panel is a persistent sheet that steps aside while another sheet is up.
    @State private var showTextSheet = true
    @State private var showPageGrid = false

    // AppStorage-backed so the View menu toggles and the toolbar share one source of truth.
    @AppStorage(DefaultsKey.showThumbnails) private var showThumbnails = true
    @AppStorage(DefaultsKey.showTextPanel) private var showTextPanel = true
    @AppStorage(DefaultsKey.showSmartCleanup) private var showSmartCleanup = false

    init(document: Document, onDismiss: @escaping () -> Void) {
        self.document = document
        self.onDismiss = onDismiss
        _cleanup = State(initialValue: SmartCleanupModel(document: document))
    }

    /// A confirmation dialog or alert declared on this view is up (or about to be).
    private var isShowingDialog: Bool {
        pendingOperation != nil || operationError != nil || showChapterEditor || showDeletePageConfirmation
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

    /// Built in three steps — focused values, presentations, lifecycle — because one modifier chain this long is more than the type checker will solve in one expression.
    var body: some View {
        lifecycle(presentations(focusedValues(layout)))
    }

    /// Menu bar commands (MultiScanCommands) act on the focused window through these.
    private func focusedValues(_ content: some View) -> some View {
        content
            .focusedSceneValue(\.navigationState, navigationState)
            .focusedSceneValue(\.showExportPanel, $showExportPanel)
            .focusedSceneValue(\.showAddFromPhotos, $showAddFromPhotos)
            .focusedSceneValue(\.showAddFromFiles, $showAddFromFiles)
            .focusedSceneValue(\.showDeletePageConfirmation, $showDeletePageConfirmation)
            .focusedSceneValue(\.showArtworkCapture, $showArtworkCapture)
            .focusedSceneValue(\.showDigest, $showDigest)
            .focusedSceneValue(\.showChapterEditor, $showChapterEditor)
            .focusedSceneValue(\.showPageNumbering, $showPageNumbering)
            .focusedSceneValue(\.pageActions, pageActions)
    }

    /// Sheets, dialogs, alerts, and the progress badge.
    private func presentations(_ content: some View) -> some View {
        content
            .overlay(alignment: .top) {
                if let busyMessage {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(busyMessage)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect()
                    .padding(.top, 12)
                    .transition(.opacity)
                    .accessibilityElement(children: .combine)
                }
            }
            .animation(.default, value: busyMessage)
            .sheet(isPresented: Bindable(smartSeparate).isPresented, onDismiss: restoreTextSheet) {
                SmartSeparateSheet(model: smartSeparate)
            }
            .sheet(item: $originalScanPage, onDismiss: restoreTextSheet) { page in
                OriginalScanView(page: page)
            }
            .confirmationDialog(
                pendingOperation?.title ?? "",
                isPresented: Binding(get: { pendingOperation != nil }, set: { if !$0 { pendingOperation = nil } }),
                titleVisibility: .visible,
                presenting: pendingOperation
            ) { operation in
                Button(operation.confirmLabel) { perform(operation) }
                Button("Cancel", role: .cancel) {}
            } message: { operation in
                Text(operation.message)
            }
            .alert("Couldn't Finish", isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
                Button("OK") {}
            } message: {
                Text(operationError ?? "")
            }
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
            .sheet(isPresented: $showPageNumbering, onDismiss: restoreTextSheet) {
                PageNumberingSettingsView(document: document)
            }
            .modifier(DigestPresentation(isPresented: $showDigest, isCompact: isCompact, onDismiss: restoreTextSheet) {
                DigestView(document: document)
            })
            .modifier(CapturePresentation(session: $captureSession, isCompact: isCompact, onDismiss: restoreTextSheet) { session in
                ArtworkCaptureView(
                    session: session,
                    onCancel: { captureSession = nil },
                    onCapture: { capture, isNew in
                        finishCapture(capture, isNew: isNew, session: session)
                        captureSession = nil
                    }
                )
            })
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
            .chapterTitleEditor(isPresented: $showChapterEditor, page: navigationState.currentPage, draft: $chapterTitleDraft)
    }

    /// Session start/stop, the compact text sheet's choreography, and save protection.
    private func lifecycle(_ content: some View) -> some View {
        content
            .onChange(of: showChapterEditor) { _, presenting in
                if presenting { chapterTitleDraft = navigationState.currentPage?.sectionTitle ?? "" }
            }
            .onChange(of: showArtworkCapture) { _, requested in
                // Menu bar / keyboard: open the overlay centered on the current page.
                guard requested else { return }
                showArtworkCapture = false
                if let page = navigationState.currentPage { beginCapture(on: page, at: nil) }
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
            .onChange(of: showDigest) { _, showing in
                if showing { textController?.saveNow(); showTextSheet = false }
            }
            .onChange(of: showPageNumbering) { _, showing in
                if showing { showTextSheet = false }
            }
            .onChange(of: smartSeparate.isPresented) { _, showing in
                if showing { showTextSheet = false }
            }
            .onChange(of: originalScanPage == nil) { _, isNil in
                if !isNil { showTextSheet = false }
            }
            .onChange(of: isShowingDialog) { _, showing in
                // iPhone: the persistent text sheet holds this view's one presentation slot, so a dialog or alert declared here cannot appear while it is up (verified in the simulator — the confirmation simply never showed). It steps aside and comes back, like it does for the progress popover.
                if isCompact { showTextSheet = !showing }
            }
            .onChange(of: captureSession == nil) { _, isNil in
                if !isNil { showTextSheet = false }
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
            ThumbnailSidebar(document: document, navigationState: navigationState, actions: pageActions)
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
                        },
                        // The grid dismisses itself first; whatever these present waits until it is gone.
                        actions: pageActions.deferred(by: .milliseconds(350))
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
        let viewer = ImageViewer(navigationState: navigationState, onCaptureArtwork: { point in
            if let page = navigationState.currentPage { beginCapture(on: page, at: point) }
        })
            // Onscreen awareness: lets Siri/Apple Intelligence refer to "this page".
            .appEntityIdentifier(currentPageEntityIdentifier)
            .toolbarRole(.editor)
            .toolbar { reviewToolbar }
            .modifier(PageRotors(pages: sortedPages) { pageNumber in
                navigationState.goToPage(pageNumber: pageNumber)
            })

        #if os(iOS)
        // No title on iPhone or iPad: the bar is toolbar items only, and the image gets the space.
        viewer
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        #else
        viewer
            .navigationTitle(navigationTitle)
            .navigationSubtitle(Text(document.totalPages == 1 ? "1 page" : "\(document.totalPages) pages"))
        #endif
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
        if isCompact {
            ToolbarItem(placement: .primaryAction) {
                Button { showPageGrid = true } label: {
                    Label("Pages", systemImage: "square.grid.3x3")
                }
            }
        }

        ToolbarItem(placement: .primaryAction) {
            moreMenu
        }

        // Digest: the one on-screen entry point on iPhone and iPad, in every size class (the menu bar has View ▸ Read in Digest). Low priority, so when the bar runs out of room this is what moves into the overflow menu first.
        ToolbarItem(placement: .primaryAction) {
            Button { showDigest = true } label: {
                Label("Read in Digest", systemImage: "book.pages")
            }
            .help("Read the whole project as one continuous text")
        }
        .visibilityPriority(.low)
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

            // Image adjustments + artwork capture
            if let page = navigationState.currentPage {
                Section("Image") {
                    PageRotationButtons(page: page)
                    PageAdjustmentToggles(page: page)
                    CaptureArtworkButton(page: page) { beginCapture(on: page, at: nil) }
                }

                Divider()

                Section("Scan") {
                    PageScanMenuItems(page: page, actions: pageActions)
                }

                Divider()

                Section("Chapter") {
                    ChapterMenuItems(page: page) { showChapterEditor = true }
                }

                Divider()
            }

            // Project
            Section("Project") {
                Button { showPageNumbering = true } label: {
                    Label("Page Numbering…", systemImage: "number")
                }
                Button { pageActions.separateProject?() } label: {
                    Label("Smart Separate Pages…", systemImage: "rectangle.split.2x1")
                }
            }

            Divider()

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
        // The progress item lives inside the menu and a popover can't anchor to a menu item, so it anchors to the menu's button: it opens below "More" on iPad and as a sheet on iPhone.
        .popover(isPresented: $showProgress) { progressPopover }
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
        textController = page.map(makeTextController)
        scheduleCleanupAnalysis()
    }

    /// Rebuilds the controller on the page's stored text after it was rewritten behind the editor's back (batch Smart Cleanup, a capture appended to stored text).
    /// - Parameter discardingEdits: `true` when the stored text was *replaced* (read again, separated, rejoined): whatever the editor still holds is the old text and must not be saved back over the new one.
    private func reloadTextController(discardingEdits: Bool = false) {
        if discardingEdits {
            textController?.detachDiscardingEdits()
        } else {
            textController?.detach()
        }
        textController = navigationState.currentPage.map(makeTextController)
        scheduleCleanupAnalysis()
    }

    private func makeTextController(for page: Page) -> PageTextController {
        let controller = PageTextController(page: page)
        controller.onRecaptureRequested = { capture in
            beginCapture(on: capture.page ?? page, at: nil, recapturing: capture)
        }
        return controller
    }

    private func saveNow() {
        textController?.saveNow()
        // Force the disk write now rather than at the next autosave
        try? modelContext.save()
    }

    private func restoreTextSheet() {
        showTextSheet = true
    }

    // MARK: - Page actions (menus, sidebar, grid, menu bar)

    /// Everything the page menus can ask this view to do. Operations that rewrite page text go through `pendingOperation` so the user confirms first.
    private var pageActions: PageActions {
        PageActions(
            insertFromPhotos: { insertAfter in
                insertAfterPageNumber = insertAfter
                showAddFromPhotos = true
            },
            insertFromFiles: { insertAfter in
                insertAfterPageNumber = insertAfter
                showAddFromFiles = true
            },
            captureArtwork: { page in beginCapture(on: page, at: nil) },
            separate: { page in beginSeparation(.page(page.persistentModelID)) },
            separateProject: { beginSeparation(.project) },
            rejoin: { page in pendingOperation = .rejoin(page) },
            viewOriginalScan: { page in originalScanPage = page },
            recognizeAgain: { page in pendingOperation = .recognizeAgain(page) },
            restoreVisionText: { page in pendingOperation = .restoreVisionText(page) }
        )
    }

    /// Opens the Smart Separate sheet for one page or the whole project. Nothing changes until the user confirms there.
    private func beginSeparation(_ scope: SmartSeparateModel.Scope) {
        // The stored text is what gets replaced; make sure it is current first.
        textController?.saveNow()
        pageBeforeSeparation = navigationState.currentPage?.persistentModelID
        smartSeparate.onPageSeparated = { separatedID in
            // A page was inserted: every later page has a new number. Stay on the page that was on screen.
            navigationState.refreshPageOrder()
            navigationState.reselectPage(withID: pageBeforeSeparation)
            if separatedID == pageBeforeSeparation {
                reloadTextController(discardingEdits: true)
            }
        }
        smartSeparate.begin(scope, in: document)
    }

    /// Runs a confirmed page operation, showing progress and keeping the editor in step with the rewritten text.
    private func perform(_ operation: PendingPageOperation) {
        textController?.saveNow()
        let page = operation.page
        busyMessage = operation.progressMessage
        Task {
            defer { busyMessage = nil }
            do {
                switch operation {
                case .rejoin:
                    try await PageSeparationService.rejoin(page, navigationState: navigationState, context: modelContext)
                case .recognizeAgain:
                    try await PageRecognitionService.recognizeAgain(page)
                case .restoreVisionText:
                    try await PageRecognitionService.restoreVisionText(page)
                }
                // Rejoining can change which page is current; either way the page on screen may be the one rewritten.
                if navigationState.currentPage === page || textController?.page !== navigationState.currentPage || operation.isRejoin {
                    reloadTextController(discardingEdits: true)
                }
                AccessibilityNotification.Announcement(operation.completionAnnouncement).post()
            } catch {
                operationError = error.localizedDescription
            }
        }
    }

    // MARK: - Artwork capture

    /// Opens the capture overlay for `page`, seeded at `point` (normalized, upper-left) or the page's center.
    private func beginCapture(on page: Page, at point: CGPoint?, recapturing capture: PageCapture? = nil) {
        textController?.saveNow()
        captureSession = ArtworkCaptureSession(page: page, seedPoint: point, existingCapture: capture)
    }

    /// Puts the finished capture into the page text — through the live editor when it is the current page (undoable), or by appending to the stored text otherwise.
    private func finishCapture(_ capture: PageCapture, isNew: Bool, session: ArtworkCaptureSession) {
        let page = session.page
        if let textController, textController.page === page {
            if isNew {
                textController.insertCapture(capture)
            } else {
                textController.captureDidChange(capture)
            }
        } else if isNew {
            CaptureService.appendAttachmentToStoredText(for: capture, on: page)
            if navigationState.currentPage === page { reloadTextController() }
        } else {
            CaptureImageStore.shared.register(capture)
        }
        AccessibilityNotification.Announcement(
            isNew
                ? String(localized: "Illustration captured and placed in the page text.")
                : String(localized: "Illustration recaptured.")
        ).post()
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
            let prepared = try await pipeline.prepare(urls: urls)
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

        let images = await pipeline.loadPhotos(items)
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

// MARK: - Page operations

/// A page operation that replaces or merges page text, held until the user confirms it.
private enum PendingPageOperation {
    case rejoin(Page)
    case recognizeAgain(Page)
    case restoreVisionText(Page)

    var page: Page {
        switch self {
        case .rejoin(let page), .recognizeAgain(let page), .restoreVisionText(let page): page
        }
    }

    var isRejoin: Bool {
        if case .rejoin = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .rejoin: String(localized: "Rejoin Separated Pages?")
        case .recognizeAgain(let page): String(localized: "Recognize Page \(page.pageNumber) Again?")
        case .restoreVisionText(let page): String(localized: "Restore Apple Vision Text on Page \(page.pageNumber)?")
        }
    }

    var message: String {
        switch self {
        case .rejoin(let page):
            let numbers = ([page] + page.facingPages).map(\.pageNumber).sorted().map(String.init).joined(separator: String(localized: " and ", comment: "Joins two page numbers"))
            return String(localized: "Pages \(numbers) become one page again, showing the whole scan. Their text is kept and joined in order.")
        case .recognizeAgain(let page):
            return page.hasBeenEditedOrReviewed
                ? String(localized: "MultiScan reads the page image again, the way it is displayed now. This page has been edited or reviewed — its current text will be replaced. Illustrations stay on the page.")
                : String(localized: "MultiScan reads the page image again, the way it is displayed now, and replaces the page's text. Illustrations stay on the page.")
        case .restoreVisionText:
            return String(localized: "The page's current text will be replaced with Apple Vision's reading of it. Illustrations stay on the page.")
        }
    }

    var confirmLabel: String {
        switch self {
        case .rejoin: String(localized: "Rejoin")
        case .recognizeAgain: String(localized: "Recognize Again")
        case .restoreVisionText: String(localized: "Restore")
        }
    }

    var progressMessage: String {
        switch self {
        case .rejoin: String(localized: "Rejoining pages…")
        case .recognizeAgain: String(localized: "Reading the page…")
        case .restoreVisionText: String(localized: "Restoring text…")
        }
    }

    var completionAnnouncement: String {
        switch self {
        case .rejoin: String(localized: "Pages rejoined.")
        case .recognizeAgain: String(localized: "Page text recognized again.")
        case .restoreVisionText: String(localized: "Apple Vision text restored.")
        }
    }
}

extension PageActions {
    /// The same actions, each run after `delay` — for a sheet that has to dismiss itself before the review view can present what the action leads to. Insert actions are left out: the sheet presents its own pickers.
    func deferred(by delay: Duration) -> PageActions {
        func later(_ action: ((Page) -> Void)?) -> ((Page) -> Void)? {
            guard let action else { return nil }
            return { page in
                Task { @MainActor in
                    try? await Task.sleep(for: delay)
                    action(page)
                }
            }
        }
        var result = PageActions()
        result.captureArtwork = later(captureArtwork)
        result.separate = later(separate)
        result.rejoin = later(rejoin)
        result.viewOriginalScan = later(viewOriginalScan)
        result.recognizeAgain = later(recognizeAgain)
        result.restoreVisionText = later(restoreVisionText)
        return result
    }
}

// MARK: - Presentation helpers

/// Digest: full-screen on iPhone, a large sheet elsewhere.
private struct DigestPresentation<Digest: View>: ViewModifier {
    @Binding var isPresented: Bool
    let isCompact: Bool
    let onDismiss: () -> Void
    @ViewBuilder let digest: () -> Digest

    func body(content: Content) -> some View {
        #if os(iOS)
        if isCompact {
            content.fullScreenCover(isPresented: $isPresented, onDismiss: onDismiss, content: digest)
        } else {
            content.sheet(isPresented: $isPresented, onDismiss: onDismiss) {
                digest().presentationSizing(.page)
            }
        }
        #else
        content.sheet(isPresented: $isPresented, onDismiss: onDismiss, content: digest)
        #endif
    }
}

/// Artwork capture: full-screen on iPhone (the crop gesture wants the whole screen), a sheet elsewhere.
private struct CapturePresentation<Overlay: View>: ViewModifier {
    @Binding var session: ArtworkCaptureSession?
    let isCompact: Bool
    let onDismiss: () -> Void
    @ViewBuilder let makeOverlay: (ArtworkCaptureSession) -> Overlay

    func body(content: Content) -> some View {
        #if os(iOS)
        if isCompact {
            content.fullScreenCover(item: $session, onDismiss: onDismiss, content: makeOverlay)
        } else {
            content.sheet(item: $session, onDismiss: onDismiss) { session in
                makeOverlay(session).presentationSizing(.page)
            }
        }
        #else
        content.sheet(item: $session, onDismiss: onDismiss, content: makeOverlay)
        #endif
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
            .accessibilityRotor("Chapters") {
                ForEach(pages.filter { $0.sectionTitle != nil }) { page in
                    AccessibilityRotorEntry(page.sectionTitle ?? page.title, id: page.pageNumber) {
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
            Text("Add Pages from Photos")
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
