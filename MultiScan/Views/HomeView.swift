import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import PhotosUI

struct HomeView: View {
    var onDocumentSelected: (Document) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    /// Sorted by the store, not per body evaluation. Result changes (create, delete, sync) arrive animated, so the grid's cards slide into place.
    @Query(sort: \Document.createdAt, order: .reverse, animation: .default) private var documents: [Document]

    /// Shared import → OCR → project pipeline (also driven by the "Start New Project" intent).
    private let pipeline = ProjectImportPipeline.shared

    // Import state
    @State private var showingFilePicker = false
    @State private var showingPhotosPicker = false
    @State private var selectedPhotos: [PhotosPickerItem] = []

    // UI state
    @State private var showingError = false
    @State private var importError: Error?
    @State private var isDragOver = false
    @State private var isOptimizing = false
    @State private var isPreparingLocalImport = false

    /// Share-sheet imports are prepared outside this view; they show the same placeholder card.
    private let sharedImports = SharedImportCoordinator.shared

    private var isPreparingImport: Bool {
        isPreparingLocalImport || sharedImports.isPreparing
    }

    // Settings
    @AppStorage(DefaultsKey.optimizeImagesOnImport) private var optimizeImagesOnImport = false

    // Settings sheet (iOS only — macOS uses the Settings window)
    #if os(iOS)
    @State private var showingSettings = false
    #endif

    var body: some View {
        #if os(iOS)
        // iOS needs a NavigationStack for the toolbar; macOS uses the window toolbar
        NavigationStack {
            homeContent
                .navigationTitle("MultiScan")
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheetView()
        }
        #else
        homeContent
        #endif
    }

    /// Whether the app-wide search results replace the project grid.
    private var isShowingSearchResults: Bool {
        router.isSearchPresented && !router.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var homeContent: some View {
        @Bindable var router = router

        return Group {
            if isShowingSearchResults {
                SearchResultsView(term: router.searchText.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if documents.isEmpty && !isPreparingImport {
                HomeEmptyState()
            } else {
                DocumentsGrid(
                    documents: documents,
                    columns: gridColumns,
                    isPreparingImport: isPreparingImport,
                    onSelect: onDocumentSelected,
                    onDelete: deleteDocument,
                    onOptimize: { document in optimizeImages(for: document) }
                )
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
            handleDrop(providers: providers)
            return true
        }
        .photosPicker(
            isPresented: $showingPhotosPicker,
            selection: $selectedPhotos,
            matching: .images
        )
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.image, .pdf, .folder],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
        .alert("Error", isPresented: $showingError, presenting: importError) { _ in
            Button("OK") { }
        } message: { error in
            Text(error.localizedDescription)
        }
        .onChange(of: selectedPhotos) { _, items in
            Task { await processSelectedPhotos(items) }
        }
        // `pipeline.progress` is read only for the announcement, so it lives in a modifier
        .modifier(OCRProgressAnnouncer())
        // App-wide search: projects by name, pages by recognized text. The system `searchInApp` intent lands here with the field presented and populated.
        .searchable(
            text: $router.searchText,
            isPresented: $router.isSearchPresented,
            prompt: Text("Search")
        )
        .toolbar { toolbarContent }
    }

    /// Grid columns: fixed 2 on iPhone portrait, adaptive everywhere else
    private var gridColumns: [GridItem] {
        #if os(iOS)
        if horizontalSizeClass == .compact && verticalSizeClass == .regular {
            return Array(repeating: GridItem(.flexible(), spacing: 24, alignment: .top), count: 2)
        }
        #endif
        return [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 24, alignment: .top)]
    }

    // MARK: - Toolbar Content

    /// The system search field is positioned explicitly: left of the "+" button in the trailing toolbar on macOS and iPad, and in the bottom bar on iPhone (compact width).
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(iOS)
        // Settings live in a sheet on iOS (macOS has a Settings window via the app menu)
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showingSettings = true
            } label: {
                Label("Settings", systemImage: "gear")
            }
            .accessibilityLabel("Settings")
        }

        if horizontalSizeClass == .compact {
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
        } else {
            DefaultToolbarItem(kind: .search)
        }
        #else
        DefaultToolbarItem(kind: .search)
        #endif

        ToolbarItem(placement: .primaryAction) {
            AddProjectMenu(
                isPreparingImport: isPreparingImport,
                onImportFromPhotos: { showingPhotosPicker = true },
                onImportFromFiles: { showingFilePicker = true }
            )
        }
    }

    // MARK: - Document Actions

    private func deleteDocument(_ document: Document) {
        let uuid = document.uuid
        modelContext.delete(document)
        do {
            try modelContext.save()
            MultiScanShortcuts.updateAppShortcutParameters()
            // Donations outlive the data they point at unless we prune them.
            ProjectMaintenance.deleteDonations(forProjects: [uuid].compactMap { $0 })
        } catch {
            print("Failed to delete document: \(error)")
        }
    }

    /// Re-encodes every page image as HEIC, keeping the smaller of the two. Encoding runs on the cooperative pool; the model writes stay here on the main actor.
    private func optimizeImages(for document: Document) {
        guard !isOptimizing else { return }
        isOptimizing = true

        Task {
            defer { isOptimizing = false }
            for page in document.unwrappedPages {
                guard let imageData = page.imageData,
                      let compressed = await PlatformImage.heicReencodingInBackground(imageData),
                      compressed.count < imageData.count else { continue }
                page.imageData = compressed
            }
            document.recalculateStorageSize()
            try? modelContext.save()
        }
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
            presentError(error)
        }
    }

    private func processFileURLs(_ urls: [URL]) async {
        isPreparingLocalImport = true

        let prepared: ProjectImportPipeline.PreparedImport
        do {
            prepared = try await pipeline.prepare(urls: urls, optimizeImages: optimizeImagesOnImport) { estimatedPageCount in
                // Announce immediately if we have content to process
                if estimatedPageCount > 0 {
                    AccessibilityNotification.Announcement(String(localized: "Processing \(estimatedPageCount) pages. This will take a few moments.")).post()
                }
            }
        } catch {
            print("Import error: \(error)")
            isPreparingLocalImport = false
            presentError(error)
            return
        }

        guard !prepared.images.isEmpty else {
            print("No valid images found")
            isPreparingLocalImport = false
            return
        }

        // Spinner will be replaced by document card's progress indicator
        isPreparingLocalImport = false

        // A picked folder names the project; otherwise the date placeholder goes in and the on-device model may propose a real title afterwards.
        let documentName = prepared.suggestedName ?? ProjectImportPipeline.defaultProjectName()
        await startOCRProcessing(images: prepared.images, documentName: documentName, allowsAutomaticTitle: prepared.suggestedName == nil)
    }

    // MARK: - Photos Import Handling

    private func processSelectedPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }

        isPreparingLocalImport = true
        let images = await pipeline.loadPhotos(items, optimizeImages: optimizeImagesOnImport)
        isPreparingLocalImport = false

        guard !images.isEmpty else {
            print("No photos could be loaded")
            selectedPhotos = []
            return
        }

        // Announce processing start before document card appears
        AccessibilityNotification.Announcement(String(localized: "Processing \(images.count) pages. This will take a few moments.")).post()

        await startOCRProcessing(images: images, documentName: ProjectImportPipeline.defaultProjectName(), allowsAutomaticTitle: true)
        selectedPhotos = []
    }

    // MARK: - Drag and Drop

    private func handleDrop(providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }

        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }

            Task { @MainActor in
                await processFileURLs([url])
            }
        }
    }

    // MARK: - OCR Processing

    private func startOCRProcessing(images: [(data: Data, fileName: String)], documentName: String, allowsAutomaticTitle: Bool) async {
        do {
            try await pipeline.createProject(named: documentName, images: images, allowsAutomaticTitle: allowsAutomaticTitle)
            AccessibilityNotification.Announcement(String(localized: "Scan complete. \(images.count) pages ready for review.")).post()
        } catch {
            print("Failed to create project: \(error)")
            presentError(error)
        }
    }

    private func presentError(_ error: Error) {
        importError = error
        showingError = true
    }
}

// MARK: - Empty State

struct HomeEmptyState: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Projects", systemImage: "document.viewfinder")
        } description: {
            Text("Choose the + button in the toolbar to start a project from your photos or files.")
        }
    }
}

// MARK: - Projects Grid

struct DocumentsGrid: View {
    let documents: [Document]
    let columns: [GridItem]
    let isPreparingImport: Bool
    let onSelect: (Document) -> Void
    let onDelete: (Document) -> Void
    let onOptimize: (Document) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                if isPreparingImport {
                    NewProjectPlaceholderCard()
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                ForEach(documents) { document in
                    DocumentGridItem(
                        document: document,
                        onSelect: onSelect,
                        onDelete: onDelete,
                        onOptimize: onOptimize
                    )
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .padding()
            // The placeholder is view state, not a query result, so it needs its own animation.
            .animation(.default, value: isPreparingImport)
        }
    }
}

struct DocumentGridItem: View {
    let document: Document
    let onSelect: (Document) -> Void
    let onDelete: (Document) -> Void
    let onOptimize: (Document) -> Void

    private let pipeline = ProjectImportPipeline.shared

    var body: some View {
        let isProcessing = pipeline.processingDocumentIDs.contains(document.persistentModelID)

        DocumentCard(
            document: document,
            isProcessing: isProcessing,
            ocrProgress: isProcessing ? pipeline.progress : 0,
            onOpen: { onSelect(document) },
            onDelete: { onDelete(document) },
            onOptimize: { onOptimize(document) }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(isProcessing ? "Processing in progress" : "Activate to open project")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) {
            guard !isProcessing else { return }
            onSelect(document)
        }
    }

    private var accessibilityLabel: String {
        let emoji = document.emoji ?? ""
        let emojiPrefix = emoji.isEmpty ? "" : "\(emoji), "
        let pageCount = document.totalPages == 1
            ? String(localized: "1 page")
            : String(localized: "\(document.totalPages) pages")
        let dateString = document.lastModifiedDate.formatted(date: .abbreviated, time: .shortened)

        return String(localized: "\(emojiPrefix)\(document.name), \(pageCount), \(document.completionPercentage.formatted(.percent)) reviewed, last modified \(dateString)", comment: "VoiceOver label for a project card: emoji, name, page count, percent reviewed, last-modified date")
    }
}

struct NewProjectPlaceholderCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.1))

                ProgressView()
                    .controlSize(.large)
            }
            .aspectRatio(8.5/11, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text("New Project")
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preparing new project")
    }
}

// MARK: - Toolbar

struct AddProjectMenu: View {
    let isPreparingImport: Bool
    let onImportFromPhotos: () -> Void
    let onImportFromFiles: () -> Void

    var body: some View {
        Menu {
            Button("Import from Photos…", systemImage: "photo.on.rectangle") {
                onImportFromPhotos()
            }
            Button("Import from Files…", systemImage: "folder") {
                onImportFromFiles()
            }
        } label: {
            Label("Start Project", systemImage: "plus")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .disabled(isPreparingImport)
        .help(isPreparingImport ? "Preparing import" : "Start a new project")
        .accessibilityLabel(isPreparingImport ? "Preparing import" : "Start Project")
        .accessibilityHint(isPreparingImport ? "Import in progress" : "Start a project using imported images from your photos or files")
    }
}

// MARK: - Accessibility Side Effects

/// Isolates the read of `pipeline.progress`
private struct OCRProgressAnnouncer: ViewModifier {
    private let pipeline = ProjectImportPipeline.shared
    @State private var hasAnnouncedHalfway = false

    func body(content: Content) -> some View {
        content
            .onChange(of: pipeline.progress) { oldValue, newValue in
                // Progress dropping means a new import started — re-arm.
                if newValue < oldValue {
                    hasAnnouncedHalfway = false
                }
                // Announce when progress crosses 50%
                if !hasAnnouncedHalfway && oldValue < 0.5 && newValue >= 0.5 {
                    hasAnnouncedHalfway = true
                    AccessibilityNotification.Announcement(String(localized: "Processing is \(50.formatted(.percent)) done.", comment: "VoiceOver announcement when OCR progress passes the halfway point")).post()
                }
            }
    }
}

#Preview("English") {
    HomeView(onDocumentSelected: { _ in })
        .modelContainer(previewContainer())
        .environment(AppRouter.shared)
        .environment(\.locale, Locale(identifier: "en"))
}

#Preview("es-419") {
    HomeView(onDocumentSelected: { _ in })
        .modelContainer(previewContainer())
        .environment(AppRouter.shared)
        .environment(\.locale, Locale(identifier: "es-419"))
}
