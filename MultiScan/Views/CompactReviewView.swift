//
//  CompactReviewView.swift
//  MultiScan
//
//  iPhone (vertical size class) review layout: full-screen image viewer with a persistent bottom sheet for the page text, a page grid sheet for navigation, and a toolbar.
//

#if os(iOS)
import SwiftUI
import SwiftData
import PhotosUI
import AppIntents

struct CompactReviewView: View {
    let document: Document
    var onDismiss: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.undoManager) private var undoManager
    @Environment(AppRouter.self) private var router
    @StateObject private var navigationState = NavigationState()

    /// Shared import → OCR pipeline (also used by Home and the "Start New Project" intent).
    private let pipeline = ProjectImportPipeline.shared

    @State private var selectedPageNumber: Int?

    /// Smart Cleanup analysis + edits (shared with the RichTextSidebar pane on macOS/iPad).
    /// The compact layout has no reachable text controller, so its edits go model-side and the text sheet is reloaded afterwards.
    @State private var cleanup: SmartCleanupModel?
    @State private var showTextSheet = true
    @State private var textSheetRefreshID = UUID()
    @State private var showSlideGrid = false
    @State private var showExportPanel = false

    @AppStorage("optimizeImagesOnImport") private var optimizeImagesOnImport = false

    var body: some View {
        NavigationStack {
            ImageViewer(navigationState: navigationState)
            // Onscreen awareness: lets Siri/Apple Intelligence refer to "this page".
            .appEntityIdentifier(navigationState.currentPage?.uuid.map { EntityIdentifier(for: PageEntity.self, identifier: $0) })
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarRole(.editor)
            .toolbar { compactToolbar }
            .sheet(isPresented: $showTextSheet) {
                RichTextSidebar(
                    document: document,
                    navigationState: navigationState,
                    hideBottomPanels: true
                )
                .id(textSheetRefreshID)
                .presentationDetents([.height(120), .fraction(0.3), .medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .large))
                .interactiveDismissDisabled()
            }
            .sheet(isPresented: $showSlideGrid, onDismiss: restoreTextSheet) {
                SlideGridView(
                    document: document,
                    navigationState: navigationState,
                    selectedPageNumber: $selectedPageNumber,
                    onAddPhotos: { insertAfter, items in
                        Task { await processSelectedPhotos(items, insertAfter: insertAfter) }
                    },
                    onAddFiles: { insertAfter, urls in
                        Task { await processFileURLs(urls, insertAfter: insertAfter) }
                    }
                )
            }
            .sheet(isPresented: $showExportPanel, onDismiss: restoreTextSheet) {
                ExportPanelView(document: document)
            }
            .onChange(of: showSlideGrid) { _, showing in
                if showing { showTextSheet = false }
            }
            .onChange(of: showExportPanel) { _, showing in
                if showing { showTextSheet = false }
            }
            .onChange(of: scenePhase) { _, newPhase in
                // Persist any pending edits when the app is backgrounded
                if newPhase == .background {
                    try? modelContext.save()
                }
            }
            .onAppear {
                navigationState.setupNavigation(for: document)
                navigationState.undoManager = undoManager
                if let firstPage = navigationState.currentPage {
                    selectedPageNumber = firstPage.pageNumber
                }
                fulfillOpenRequest()
                setUpCleanupModel()
            }
            .onChange(of: navigationState.currentPageNumber) { _, newPageNumber in
                selectedPageNumber = newPageNumber
                scheduleCleanupAnalysis()
            }
            .onChange(of: router.openRequest) { _, _ in
                fulfillOpenRequest()
            }
            .onChange(of: undoManager) { _, newValue in
                navigationState.undoManager = newValue
            }
        }
    }

    private func restoreTextSheet() {
        showTextSheet = true
    }

    /// Jumps to the page requested by a deep link (Spotlight page result, Open Page intent, search hit).
    private func fulfillOpenRequest() {
        if let pageNumber = router.fulfillOpenRequest(for: document, navigationState: navigationState) {
            selectedPageNumber = pageNumber
        }
    }

    // MARK: - Smart Cleanup

    private func setUpCleanupModel() {
        guard cleanup == nil else { return }
        cleanup = SmartCleanupModel(document: document)
        scheduleCleanupAnalysis()
    }

    /// No live `PageTextController` is reachable from here — it lives inside the text sheet — so every edit goes model-side and the sheet is reloaded when the current page changed.
    private func applyCleanupOption(_ option: TextManipulationService.CleanupOption) {
        let needsReload = cleanup?.apply(
            option,
            currentPageNumber: navigationState.currentPageNumber,
            liveController: nil
        ) ?? false

        if needsReload {
            refreshTextSheet()
        }
    }

    /// Smart Cleanup is always active on iPhone — it lives in the More menu, not a toggled pane.
    private func scheduleCleanupAnalysis() {
        cleanup?.scheduleAnalysis(forPage: navigationState.currentPage?.pageNumber)
    }

    /// Removes line breaks from the current page's text, modifying the model directly.
    private func removeLineBreaksFromCurrentPage() {
        guard let page = navigationState.currentPage else { return }
        let cleaned = TextManipulationService.removingLineBreaks(from: page.attributedText)
        page.attributedText = cleaned
        TextExportCacheService.updateEntry(
            pageNumber: page.pageNumber,
            attributedText: cleaned,
            pageLastModified: page.lastModified,
            in: document
        )
        refreshTextSheet()
    }

    /// Forces the RichTextSidebar sheet to reinitialize its PageTextController
    private func refreshTextSheet() {
        textSheetRefreshID = UUID()
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var compactToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: onDismiss) {
                Label("Back", systemImage: "chevron.left")
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            // Page navigation
            Button { navigationState.previousPage() } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(!navigationState.hasPrevious)

            Button { navigationState.nextPage() } label: {
                Label("Next", systemImage: "chevron.right")
            }
            .disabled(!navigationState.hasNext)

            // Pages grid
            Button { showSlideGrid = true } label: {
                Label("Pages", systemImage: "square.grid.3x3")
            }

            // More options
            Menu {
                // Smart Cleanup
                Section("Smart Cleanup") {
                    Button { removeLineBreaksFromCurrentPage() } label: {
                        Label("Remove Line Breaks", systemImage: "line.3.horizontal")
                    }
                    .disabled(navigationState.currentPage == nil)

                    if cleanup?.isAnalyzing ?? true {
                        Label("Checking…", systemImage: "sparkle.magnifyingglass")
                    } else if let options = cleanup?.options, !options.isEmpty {
                        Menu {
                            ForEach(options) { option in
                                Button(option.label) {
                                    applyCleanupOption(option)
                                }
                            }
                        } label: {
                            Label("\(options.count) suggestions", systemImage: "sparkles")
                        }
                    } else {
                        Label("No suggestions", systemImage: "sparkles")
                    }
                }

                Divider()

                // Review
                PageReviewStatusButton(navigationState: navigationState)
                PageOrderButton(navigationState: navigationState)

                Divider()

                // Image adjustments
                if let page = navigationState.currentPage {
                    Section("Image") {
                        PageRotationButtons(page: page)
                        PageAdjustmentToggles(page: page)
                    }
                }

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

    // MARK: - Add Pages

    @MainActor
    private func processFileURLs(_ urls: [URL], insertAfter: Int? = nil) async {
        do {
            let prepared = try await pipeline.prepare(urls: urls, optimizeImages: optimizeImagesOnImport)
            guard !prepared.images.isEmpty else { return }
            await addPagesToDocument(images: prepared.images, insertAfter: insertAfter)
        } catch {
            print("Import error: \(error)")
        }
    }

    @MainActor
    private func processSelectedPhotos(_ items: [PhotosPickerItem], insertAfter: Int? = nil) async {
        guard !items.isEmpty else { return }
        let images = await pipeline.loadPhotos(items, optimizeImages: optimizeImagesOnImport)
        guard !images.isEmpty else { return }
        await addPagesToDocument(images: images, insertAfter: insertAfter)
    }

    /// Adds pages to the document, inserting after a specific page number.
    /// - Parameters:
    ///   - images: The images to process and add
    ///   - insertAfter: Page number to insert after (nil = append to end, 0 = insert at beginning)
    @MainActor
    private func addPagesToDocument(images: [(data: Data, fileName: String)], insertAfter: Int? = nil) async {
        do {
            let result = try await pipeline.addPages(
                to: document,
                images: images,
                insertAfter: insertAfter,
                in: modelContext
            )
            navigationState.setupNavigation(for: document)

            // Navigate to the first new page
            if let firstNew = result.firstNewPageNumber {
                navigationState.goToPage(pageNumber: firstNew)
                selectedPageNumber = firstNew
            }
        } catch {
            print("Failed to add pages: \(error)")
        }
    }
}
#endif
