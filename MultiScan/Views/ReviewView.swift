import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

struct ReviewView: View {
    let document: Document
    @Environment(\.modelContext) private var modelContext
    @StateObject private var navigationState = NavigationState()
    @StateObject private var ocrService = OCRService()
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
    @AppStorage("showTextPanel") private var inspectorIsShown = true

    var body: some View {
        mainContent
            .sheet(isPresented: $showExportPanel) {
                ExportPanelView(pages: document.pages)
            }
            .sheet(isPresented: $showAddFromPhotos) {
                addFromPhotosSheet
            }
            .fileImporter(
                isPresented: $showAddFromFiles,
                allowedContentTypes: [.image, .folder],
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
        .inspector(isPresented: $inspectorIsShown) {
            RichTextSidebar(
                document: document,
                navigationState: navigationState
            )
            .inspectorColumnWidth(min: 250, ideal: 350, max: 500)
        }
        .focusedSceneValue(\.document, document)
        .focusedSceneValue(\.navigationState, navigationState)
        .focusedSceneValue(\.showExportPanel, $showExportPanel)
        .focusedSceneValue(\.fullDocumentText, navigationState.fullDocumentPlainText)
        .focusedSceneValue(\.showAddFromPhotos, $showAddFromPhotos)
        .focusedSceneValue(\.showAddFromFiles, $showAddFromFiles)
        .navigationTitle(String(document.name.prefix(30)) + (document.name.count > 30 ? "..." : ""))
        .navigationSubtitle(Text("\(document.totalPages) pages"))
        .toolbarRole(.editor)
        .toolbar { toolbarContent }
    }

    // MARK: - Toolbar Content

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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
                Label(navigationState.isRandomized ? "Sequential Order" : "Shuffled Order",
                      systemImage: navigationState.isRandomized ? "shuffle.circle.fill" : "shuffle.circle")
                    .labelStyle(.iconOnly)
            }
            .help(navigationState.isRandomized ? "Switch to Sequential Order" : "Switch to Shuffled Order")

            Spacer()
                .frame(width: 20)

            Button(action: { navigationState.toggleCurrentPageDone() }) {
                Label("Mark as Reviewed",
                      systemImage: navigationState.currentPage?.isDone == true ? "checkmark.circle.fill" : "checkmark.circle")
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

            ShareLink(item: RichText(navigationState.currentPage?.richText ?? AttributedString()),
                      preview: SharePreview("Page Text")) {
                Label("Share Page Text", systemImage: "square.and.arrow.up")
                    .labelStyle(.iconOnly)
            }
            .help("Share Current Page Text")
            .disabled(navigationState.currentPage == nil)

            Button(action: { showExportPanel = true }) {
                Label("Export All Pages", systemImage: "doc.on.doc")
                    .labelStyle(.iconOnly)
            }
            .help("Export All Pages Text")

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

        var images: [(data: Data, fileName: String)] = []

        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }

            if isDirectory.boolValue {
                if let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.contentTypeKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    while let fileURL = enumerator.nextObject() as? URL {
                        if let contentType = try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType,
                           contentType.conforms(to: .image),
                           let data = try? Data(contentsOf: fileURL) {
                            let finalData = optimizeImagesOnImport ? (OCRService.compressImageData(data) ?? data) : data
                            images.append((data: finalData, fileName: fileURL.lastPathComponent))
                        }
                    }
                }
            } else {
                if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
                   contentType.conforms(to: .image),
                   let data = try? Data(contentsOf: url) {
                    let finalData = optimizeImagesOnImport ? (OCRService.compressImageData(data) ?? data) : data
                    images.append((data: finalData, fileName: url.lastPathComponent))
                }
            }
        }

        guard !images.isEmpty else { return }

        images.sort { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        await addPagesToDocument(images: images)
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

        var images: [(data: Data, fileName: String)] = []

        for (index, item) in items.enumerated() {
            if let result = await loadPhotoWithFilename(item: item, index: index) {
                let finalData = optimizeImagesOnImport ? (OCRService.compressImageData(result.data) ?? result.data) : result.data
                images.append((data: finalData, fileName: result.fileName))
            }
        }

        guard !images.isEmpty else { return }

        await addPagesToDocument(images: images)
    }

    private func loadPhotoWithFilename(item: PhotosPickerItem, index: Int) async -> (data: Data, fileName: String)? {
        do {
            let result = try await item.loadTransferable(type: PhotoFileTransferable.self)
            if let result = result {
                return (data: result.data, fileName: result.fileName)
            }
        } catch {
            print("Failed to load file representation: \(error)")
        }

        if let data = try? await item.loadTransferable(type: Data.self) {
            return (data: data, fileName: String(localized: "Photo \(index + 1)", comment: "Fallback filename for imported photo"))
        }

        return nil
    }

    // MARK: - Add Pages to Document

    @MainActor
    private func addPagesToDocument(images: [(data: Data, fileName: String)]) async {
        let startingPageNumber = document.totalPages + 1

        do {
            let results = try await ocrService.processImages(images, startingPageNumber: startingPageNumber)

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
            }

            document.totalPages += results.count
            document.recalculateStorageSize()

            try modelContext.save()

            // Refresh navigation state with new pages
            navigationState.setupNavigation(for: document)

        } catch {
            print("Failed to add pages: \(error)")
        }
    }
}
