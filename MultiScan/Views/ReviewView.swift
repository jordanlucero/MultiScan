import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

struct ReviewView: View {
    let document: Document
    var onDismiss: () -> Void

    @Environment(\.modelContext) private var modelContext
    @StateObject private var navigationState = NavigationState()
    @StateObject private var ocrService = OCRService()
    private let importService = ImageImportService()
    @State private var selectedPageNumber: Int?
    @State private var showProgress: Bool = false
    @State private var showExportPanel: Bool = false

    // Add pages state
    @State private var showAddFromPhotos: Bool = false
    @State private var showAddFromFiles: Bool = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isAddingPages: Bool = false

    // Use proper NavigationSplitViewVisibility type for animated sidebar transitions
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @AppStorage("showThumbnails") private var showThumbnails = true
    @AppStorage("optimizeImagesOnImport") private var optimizeImagesOnImport = false

    // Use AppStorage directly for inspector to sync with menu commands
    @AppStorage("showTextPanel") private var showTextPanel = true

    // Access editable text for save-before-export
    @FocusedValue(\.editableText) private var editableText

    /// Sorted pages for rotor navigation
    private var sortedPages: [Page] {
        document.pages.sorted(by: { $0.pageNumber < $1.pageNumber })
    }

    /// Unreviewed pages for rotor navigation
    private var unreviewedPages: [Page] {
        document.pages.filter { !$0.isDone }.sorted(by: { $0.pageNumber < $1.pageNumber })
    }

    var body: some View {
        mainContent
            .sheet(isPresented: $showExportPanel) {
                ExportPanelView(document: document)
            }
            .sheet(isPresented: $showAddFromPhotos) {
                addFromPhotosSheet
            }
            .fileImporter(
                isPresented: $showAddFromFiles,
                allowedContentTypes: [.image, .pdf, .folder],
                allowsMultipleSelection: true
            ) { result in
                handleFileImport(result)
            }
            .onAppear {
                navigationState.setupNavigation(for: document)
                if let firstPage = navigationState.currentPage {
                    selectedPageNumber = firstPage.pageNumber
                }
                columnVisibility = showThumbnails ? .all : .detailOnly

                // Announce document opening for VoiceOver users
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    AccessibilityNotification.Announcement("\(document.name) opened. \(document.totalPages) pages.").post()
                }
            }
            .onChange(of: navigationState.currentPageNumber) { _, newPageNumber in
                selectedPageNumber = newPageNumber
            }
            .onChange(of: showThumbnails) { _, newValue in
                columnVisibility = newValue ? .all : .detailOnly
            }
            .onChange(of: columnVisibility) { _, newValue in
                let shouldShow = (newValue != .detailOnly)
                if showThumbnails != shouldShow {
                    showThumbnails = shouldShow
                }
            }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        splitView
            .focusedSceneValue(\.document, document)
            .focusedSceneValue(\.navigationState, navigationState)
            .focusedSceneValue(\.currentPage, navigationState.currentPage)
            .focusedSceneValue(\.showExportPanel, $showExportPanel)
            .focusedSceneValue(\.fullDocumentText, navigationState.fullDocumentPlainText)
            .focusedSceneValue(\.showAddFromPhotos, $showAddFromPhotos)
            .focusedSceneValue(\.showAddFromFiles, $showAddFromFiles)
            .navigationTitle(navigationTitle)
            .navigationSubtitle(Text(document.totalPages == 1 ? "1 page" : "\(document.totalPages) pages"))
            .toolbarRole(.editor)
            .toolbar { toolbarContent }
            .accessibilityRotor("Pages") {
                ForEach(sortedPages) { page in
                    AccessibilityRotorEntry(page.rotorLabel, id: page.pageNumber) {
                        navigationState.goToPage(pageNumber: page.pageNumber)
                        selectedPageNumber = page.pageNumber
                    }
                }
            }
            .accessibilityRotor("Unreviewed") {
                ForEach(unreviewedPages) { page in
                    AccessibilityRotorEntry(page.rotorLabel, id: page.pageNumber) {
                        navigationState.goToPage(pageNumber: page.pageNumber)
                        selectedPageNumber = page.pageNumber
                    }
                }
            }
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ThumbnailSidebar(
                document: document,
                navigationState: navigationState,
                selectedPageNumber: $selectedPageNumber
            )
            .navigationSplitViewColumnWidth(min: 150, ideal: 200, max: 400)
        } detail: {
            ImageViewer(
                document: document,
                navigationState: navigationState
            )
        }
        .inspector(isPresented: $showTextPanel) {
            RichTextSidebar(
                document: document,
                navigationState: navigationState
            )
            .inspectorColumnWidth(min: 250, ideal: 350, max: 500)
        }
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
            .help(navigationState.currentPage?.isDone == true ? "Mark as Not Reviewed" : "Mark as Reviewed")

            Button(action: { showProgress.toggle() }) {
                Label("Progress", systemImage: "flag.pattern.checkered")
                    .labelStyle(.iconOnly)
            }
            .popover(isPresented: $showProgress, arrowEdge: .bottom) {
                ProgressPopover(navigationState: navigationState)
            }
            .accessibilityLabel("View Progress")
            .accessibilityValue("\(navigationState.donePageCount) of \(navigationState.totalPageCount) reviewed")
            .help("View Progress")

            //ToolbarSpacer(.fixed)
            Spacer().frame(width: 20)

            // Group 3: Share/Export
            ShareLink(item: RichText(navigationState.currentPage?.richText ?? AttributedString()),
                      preview: SharePreview("Page Text")) {
                Label("Share Page Text", systemImage: "square.and.arrow.up")
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel("Share Page Text")
            .help("Share Current Page Text")
            .disabled(navigationState.currentPage == nil)

            Button(action: {
                editableText?.saveNow()
                showExportPanel = true
            }) {
                Label("Export All Pages", systemImage: "doc.on.doc")
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel("Export All Pages")
            .help("Export All Pages Text")

            //ToolbarSpacer(.fixed)
            Spacer().frame(width: 20)

            // Group 4: Inspector toggle (edit buttons come from RichTextSidebar)
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

    // MARK: - Add Pages from Photos Sheet

    private var addFromPhotosSheet: some View {
        VStack(spacing: 20) {
            Text("Append Pages from Photos")
                .font(.headline)

            if isAddingPages {
                ProgressView("Processing \(Int(ocrService.progress * 100))%")
                    .progressViewStyle(.linear)
                    .frame(width: 200)
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
                    Task { await processSelectedPhotos(items) }
                }
            }

            Button("Cancel") {
                showAddFromPhotos = false
                selectedPhotos = []
            }
            .disabled(isAddingPages)
        }
        .padding(40)
        .frame(minWidth: 300)
    }

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

        let result = await importService.processFileURLs(urls, optimizeImages: optimizeImagesOnImport)

        var allImages = result.images

        // Process any PDFs by rendering pages to images
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

        await addPagesToDocument(images: allImages)
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

        let images = await importService.processSelectedPhotos(items, optimizeImages: optimizeImagesOnImport)

        guard !images.isEmpty else { return }

        await addPagesToDocument(images: images)
    }

    // MARK: - Add Pages to Document

    @MainActor
    private func addPagesToDocument(images: [(data: Data, fileName: String)]) async {
        let startingPageNumber = document.totalPages + 1

        do {
            let results = try await ocrService.processImages(images, startingPageNumber: startingPageNumber)

            // Collect new pages for cache update
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
                document.pages.append(page)
                newPages.append(page)
            }

            document.totalPages += results.count
            document.recalculateStorageSize()

            // Add new page entries to export cache while richText is still in memory
            TextExportCacheService.addEntries(for: newPages, to: document)

            try modelContext.save()

            // Refresh navigation state with new pages
            navigationState.setupNavigation(for: document)

        } catch {
            print("Failed to add pages: \(error)")
        }
    }
}

