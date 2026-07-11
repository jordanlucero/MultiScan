//
//  CompactReviewView.swift
//  MultiScan
//
//  iPhone (compact size class) review layout: full-screen image viewer with a persistent bottom sheet for the page text, a page grid sheet for navigation, and a toolbar.
//

#if os(iOS)
import SwiftUI
import SwiftData
import PhotosUI

struct CompactReviewView: View {
    let document: Document
    var onDismiss: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.undoManager) private var undoManager
    @StateObject private var navigationState = NavigationState()
    @StateObject private var ocrService = OCRService()
    private let importService = ImageImportService()

    @State private var selectedPageNumber: Int?

    /// Smart Cleanup analysis results for the current page
    @State private var cleanupOptions: [TextManipulationService.CleanupOption] = []
    @State private var isAnalyzingCleanup = false
    @State private var cleanupAnalysisTask: Task<Void, Never>?
    @State private var showTextSheet = true
    @State private var textSheetRefreshID = UUID()
    @State private var showSlideGrid = false
    @State private var showExportPanel = false
    @State private var isAddingPages = false

    @AppStorage("optimizeImagesOnImport") private var optimizeImagesOnImport = false

    var body: some View {
        NavigationStack {
            ImageViewer(navigationState: navigationState)
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
                scheduleCleanupAnalysis()
            }
            .onChange(of: navigationState.currentPageNumber) { _, newPageNumber in
                selectedPageNumber = newPageNumber
                scheduleCleanupAnalysis()
            }
            .onChange(of: undoManager) { _, newValue in
                navigationState.undoManager = newValue
            }
        }
    }

    private func restoreTextSheet() {
        showTextSheet = true
    }

    // MARK: - Smart Cleanup

    private func scheduleCleanupAnalysis() {
        cleanupAnalysisTask?.cancel()
        cleanupOptions = []
        isAnalyzingCleanup = true

        cleanupAnalysisTask = Task {
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            await runCleanupAnalysisAsync()
        }
    }

    private func runCleanupAnalysisAsync() async {
        guard let cacheData = document.textExportCache,
              let pageNumber = navigationState.currentPage?.pageNumber else {
            isAnalyzingCleanup = false
            return
        }

        // Run expensive analysis off the MainActor
        let options = await Task.detached(priority: .userInitiated) {
            guard let cache = TextExportCacheService.decodeCache(from: cacheData) else {
                return [TextManipulationService.CleanupOption]()
            }
            let result = TextManipulationService.analyzeForSmartCleanup(cache: cache)
            return TextManipulationService.buildOptions(from: result, forPageNumber: pageNumber)
        }.value

        guard !Task.isCancelled else { return }
        cleanupOptions = options
        isAnalyzingCleanup = false
    }

    /// Removes line breaks from the current page's text, modifying the model directly.
    private func removeLineBreaksFromCurrentPage() {
        guard let page = navigationState.currentPage else { return }
        let cleaned = TextManipulationService.removingLineBreaks(from: page.attributedText)
        page.attributedText = cleaned
        TextExportCacheService.updateEntry(pageNumber: page.pageNumber, attributedText: cleaned, in: document)
        refreshTextSheet()
    }

    private func executeCleanupOption(_ option: TextManipulationService.CleanupOption) {
        switch option {
        case .removePageNumber(let detection):
            removeToken(detection.numberText, fromPage: detection.pageNumber)

        case .removeSectionHeaderFromPage(let header, let pageNumber):
            removeLine(header.headerText, fromPage: pageNumber, stripNumbers: true)

        case .removeSectionHeaderFromRange(let header):
            for pageNumber in header.affectedPages {
                removeLine(header.headerText, fromPage: pageNumber, stripNumbers: true)
            }

        case .removeConsecutiveNumbers(let group, let pageNumber):
            guard let numberTexts = group.pageMapping[pageNumber] else { return }
            for text in numberTexts {
                removeToken(text, fromPage: pageNumber)
            }

        case .removeConsecutiveNumbersFromRange(let group):
            for (pageNumber, numberTexts) in group.pageMapping {
                for text in numberTexts {
                    removeToken(text, fromPage: pageNumber)
                }
            }

        case .removeAllPageNumbers(let detections, let consecutiveGroups):
            for detection in detections {
                removeToken(detection.numberText, fromPage: detection.pageNumber)
            }
            for group in consecutiveGroups {
                for (pageNumber, numberTexts) in group.pageMapping {
                    for text in numberTexts {
                        removeToken(text, fromPage: pageNumber)
                    }
                }
            }
        }

        refreshTextSheet()

        // Re-analyze immediately
        cleanupAnalysisTask?.cancel()
        cleanupOptions = []
        isAnalyzingCleanup = true
        cleanupAnalysisTask = Task {
            await runCleanupAnalysisAsync()
        }
    }

    private func removeToken(_ numberText: String, fromPage pageNumber: Int) {
        guard let cache = TextExportCacheService.loadCache(from: document),
              let entry = cache.pages.first(where: { $0.pageNumber == pageNumber }),
              let decoded = entry.decodedText() else { return }
        let cleaned = TextManipulationService.removingPageNumberToken(numberText, from: decoded)
        if let page = document.unwrappedPages.first(where: { $0.pageNumber == pageNumber }) {
            page.attributedText = cleaned
            TextExportCacheService.updateEntry(pageNumber: pageNumber, attributedText: cleaned, in: document)
        }
    }

    private func removeLine(_ normalizedLine: String, fromPage pageNumber: Int, stripNumbers: Bool) {
        guard let cache = TextExportCacheService.loadCache(from: document),
              let entry = cache.pages.first(where: { $0.pageNumber == pageNumber }),
              let decoded = entry.decodedText() else { return }
        let cleaned = TextManipulationService.removingLine(matching: normalizedLine, from: decoded, stripNumbers: stripNumbers)
        if let page = document.unwrappedPages.first(where: { $0.pageNumber == pageNumber }) {
            page.attributedText = cleaned
            TextExportCacheService.updateEntry(pageNumber: pageNumber, attributedText: cleaned, in: document)
        }
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

                    if isAnalyzingCleanup {
                        Label("Checking…", systemImage: "sparkle.magnifyingglass")
                    } else if cleanupOptions.isEmpty {
                        Label("No suggestions", systemImage: "sparkles")
                    } else {
                        Menu {
                            ForEach(cleanupOptions) { option in
                                Button(option.label) {
                                    executeCleanupOption(option)
                                }
                            }
                        } label: {
                            Label("\(cleanupOptions.count) suggestions", systemImage: "sparkles")
                        }
                    }
                }

                Divider()

                // Review
                Button { navigationState.toggleCurrentPageDone() } label: {
                    Label(
                        navigationState.currentPage?.isDone == true ? "Mark as Not Reviewed" : "Mark as Reviewed",
                        systemImage: navigationState.currentPage?.isDone == true ? "checkmark.circle.fill" : "checkmark.circle"
                    )
                }

                Button { navigationState.toggleRandomization() } label: {
                    Label(
                        navigationState.isRandomized ? "Sequential Order" : "Shuffled Order",
                        systemImage: navigationState.isRandomized ? "shuffle.circle.fill" : "shuffle.circle"
                    )
                }

                Divider()

                // Image adjustments
                if let page = navigationState.currentPage {
                    Section("Image") {
                        Button {
                            page.rotation = (page.rotation + 90) % 360
                        } label: {
                            Label("Rotate Clockwise", systemImage: "rotate.right")
                        }

                        Button {
                            page.rotation = (page.rotation + 270) % 360
                        } label: {
                            Label("Rotate Counterclockwise", systemImage: "rotate.left")
                        }

                        Toggle(isOn: Binding(
                            get: { page.increaseContrast },
                            set: { page.increaseContrast = $0 }
                        )) {
                            Label("Increase Contrast", systemImage: "circle.lefthalf.filled")
                        }

                        Toggle(isOn: Binding(
                            get: { page.increaseBlackPoint },
                            set: { page.increaseBlackPoint = $0 }
                        )) {
                            Label("Increase Black Point", systemImage: "circle.bottomhalf.filled")
                        }
                    }
                }

                Divider()

                // Export
                Section("Export") {
                    Button { showExportPanel = true } label: {
                        Label("Export Project Text…", systemImage: "square.and.arrow.up.on.square")
                    }
                }

                Divider()

                // Statistics
                if let page = navigationState.currentPage {
                    let wordCount = page.plainText.split(separator: " ").count
                    let charCount = page.plainText.count
                    Label("\(wordCount) words, \(charCount) characters", systemImage: "textformat")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: - Add Pages

    @MainActor
    private func processFileURLs(_ urls: [URL], insertAfter: Int? = nil) async {
        isAddingPages = true
        defer { isAddingPages = false }

        let result = await importService.processFileURLs(urls, optimizeImages: optimizeImagesOnImport)
        var allImages = result.images

        if !result.pdfURLs.isEmpty {
            let pdfService = PDFImportService()
            for pdfURL in result.pdfURLs {
                let accessed = pdfURL.startAccessingSecurityScopedResource()
                defer { if accessed { pdfURL.stopAccessingSecurityScopedResource() } }
                do {
                    let pdfImages = try await pdfService.renderPDF(at: pdfURL)
                    allImages.append(contentsOf: pdfImages)
                } catch {
                    print("PDF import error: \(error)")
                }
            }
        }

        guard !allImages.isEmpty else { return }
        await addPagesToDocument(images: allImages, insertAfter: insertAfter)
    }

    @MainActor
    private func processSelectedPhotos(_ items: [PhotosPickerItem], insertAfter: Int? = nil) async {
        guard !items.isEmpty else { return }
        isAddingPages = true
        defer { isAddingPages = false }
        let images = await importService.processSelectedPhotos(items, optimizeImages: optimizeImagesOnImport)
        guard !images.isEmpty else { return }
        await addPagesToDocument(images: images, insertAfter: insertAfter)
    }

    /// Adds pages to the document, inserting after a specific page number.
    /// - Parameters:
    ///   - images: The images to process and add
    ///   - insertAfter: Page number to insert after (nil = append to end, 0 = insert at beginning)
    @MainActor
    private func addPagesToDocument(images: [(data: Data, fileName: String)], insertAfter: Int? = nil) async {
        let insertAfterNum = insertAfter ?? document.totalPages
        let insertStart = insertAfterNum + 1
        let isAppend = insertAfterNum >= document.totalPages

        do {
            let results = try await ocrService.processImages(images, startingPageNumber: insertStart)
            let newCount = results.count

            // Shift existing pages that come after the insertion point
            for page in document.unwrappedPages where page.pageNumber >= insertStart {
                page.pageNumber += newCount
            }

            var newPages: [Page] = []
            for result in results {
                let page = Page(
                    pageNumber: result.pageNumber,
                    text: result.text,
                    imageData: result.imageData,
                    originalFileName: result.originalFileName,
                    boundingBoxesData: result.boundingBoxesData
                )
                page.thumbnailData = result.thumbnailData
                page.document = document
                document.pages?.append(page)
                newPages.append(page)
            }

            document.totalPages += newCount
            document.recalculateStorageSize()

            if isAppend {
                TextExportCacheService.addEntries(for: newPages, to: document)
            } else {
                // Page numbers shifted — update cache entries in memory (no external storage loads)
                TextExportCacheService.insertEntries(for: newPages, in: document, shiftingFrom: insertStart, by: newCount)
            }

            try modelContext.save()
            navigationState.setupNavigation(for: document)

            // Navigate to the first new page
            if let firstNew = newPages.first {
                navigationState.goToPage(pageNumber: firstNew.pageNumber)
                selectedPageNumber = firstNew.pageNumber
            }
        } catch {
            print("Failed to add pages: \(error)")
        }
    }
}
#endif
