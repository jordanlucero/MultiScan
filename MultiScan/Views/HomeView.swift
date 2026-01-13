import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import PhotosUI

struct HomeView: View {
    var onDocumentSelected: (Document) -> Void

    @Environment(\.modelContext) private var modelContext
    @Query private var documents: [Document]
    @StateObject private var ocrService = OCRService()
    private let importService = ImageImportService()

    // Import state
    @State private var showingFilePicker = false
    @State private var showingPhotosPicker = false
    @State private var selectedPhotos: [PhotosPickerItem] = []

    // UI state
    @State private var showingError = false
    @State private var documentToDelete: Document?
    @State private var showingDeleteConfirmation = false
    @State private var processingDocumentIDs: Set<PersistentIdentifier> = []
    @State private var isDragOver = false
    @State private var isOptimizing = false
    @State private var optimizingDocumentID: PersistentIdentifier?
    @State private var isPreparingImport = false

    // Settings
    @AppStorage("optimizeImagesOnImport") private var optimizeImagesOnImport = false

    // Accessibility announcement tracking
    @State private var hasAnnouncedHalfway = false
    @State private var processingPageCount = 0

    // Selection state for focused document
    @State private var selectedDocumentID: PersistentIdentifier?

    // Export panel state for menu bar command
    @State private var showingExportPanel = false

    /// The currently selected document (for menu bar commands)
    private var selectedDocument: Document? {
        guard let id = selectedDocumentID else { return nil }
        return documents.first { $0.persistentModelID == id }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 24, alignment: .top)
            ], alignment: .leading, spacing: 16) {
                newDocumentCard
                    .frame(maxHeight: .infinity, alignment: .top)
                ForEach(documents.sorted(by: { $0.createdAt > $1.createdAt })) { document in
                    documentLink(for: document)
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onTapGesture {
            // Deselect when clicking empty space
            selectedDocumentID = nil
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
        .alert("Error", isPresented: $showingError, presenting: ocrService.error) { _ in
            Button("OK") { }
        } message: { error in
            Text(error.localizedDescription)
        }
        .confirmationDialog(
            "Delete \"\(documentToDelete?.name ?? "Project")\"?",
            isPresented: $showingDeleteConfirmation,
            presenting: documentToDelete
        ) { document in
            Button("Delete", role: .destructive) {
                deleteDocument(document)
            }
            Button("Cancel", role: .cancel) {}
        } message: { document in
            Text("Are you sure you want to delete this project? This cannot be undone.")
        }
        .onChange(of: selectedPhotos) { _, items in
            Task { await processSelectedPhotos(items) }
        }
        .onChange(of: ocrService.progress) { oldValue, newValue in
            // Announce when progress crosses 50%
            if !hasAnnouncedHalfway && oldValue < 0.5 && newValue >= 0.5 {
                hasAnnouncedHalfway = true
                AccessibilityNotification.Announcement("Processing is 50% done.").post()
            }
        }
        .focusedSceneValue(\.document, selectedDocument)
        .focusedSceneValue(\.showExportPanel, $showingExportPanel)
        .sheet(isPresented: $showingExportPanel) {
            if let document = selectedDocument {
                ExportPanelView(document: document)
            }
        }
    }

    // MARK: - View Components

    private var newDocumentCard: some View {
        Menu {
            Button("Import from Photos…", systemImage: "photo.on.rectangle") {
                showingPhotosPicker = true
            }

            Button("Import from Files…", systemImage: "folder") {
                showingFilePicker = true
            }

        } label: {
            VStack(alignment: .leading, spacing: 12) {
                // White page with plus sign or spinner
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.1))

                    if isPreparingImport {
                        VStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.large)
                            Text("Preparing…")
                                .font(.caption)
                                .foregroundStyle(.primary)
                        }
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 40, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .aspectRatio(8.5/11, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Title
                Text("New Project")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(isPreparingImport)
        .accessibilityLabel(isPreparingImport ? "Preparing import" : "New Project")
        .accessibilityHint(isPreparingImport ? "Import in progress" : "Activate to start a project using imported images from your photos or files")
    }

    private func documentLink(for document: Document) -> some View {
        let isProcessing = processingDocumentIDs.contains(document.persistentModelID)

        return DocumentCard(
            document: document,
            isProcessing: isProcessing,
            ocrProgress: ocrService.progress,
            isSelected: selectedDocumentID == document.persistentModelID,
            onSelect: {
                selectedDocumentID = document.persistentModelID
            },
            onOpen: {
                onDocumentSelected(document)
            },
            onDelete: {
                documentToDelete = document
                showingDeleteConfirmation = true
            },
            onOptimize: { optimizeImages(for: document) }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(documentAccessibilityLabel(for: document))
        .accessibilityHint(isProcessing ? "Processing in progress" : "Activate to open project")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) {
            guard !isProcessing else { return }
            onDocumentSelected(document)
        }
    }

    // MARK: - Accessibility

    private func documentAccessibilityLabel(for document: Document) -> String {
        let emoji = document.emoji ?? ""
        let emojiPrefix = emoji.isEmpty ? "" : "\(emoji), "
        let pageWord = document.totalPages == 1 ? "page" : "pages"
        let dateString = document.lastModifiedDate.formatted(date: .abbreviated, time: .shortened)

        return "\(emojiPrefix)\(document.name), \(document.totalPages) \(pageWord), \(document.completionPercentage)% reviewed, last modified \(dateString)"
    }

    // MARK: - Document Actions

    private func deleteDocument(_ document: Document) {
        modelContext.delete(document)
        do {
            try modelContext.save()
        } catch {
            print("Failed to delete document: \(error)")
        }
    }

    private func optimizeImages(for document: Document) {
        guard !isOptimizing else { return }

        let documentID = document.persistentModelID
        optimizingDocumentID = documentID
        isOptimizing = true

        // Gather image data from pages on main actor
        let pageData: [(page: Page, imageData: Data)] = document.pages.compactMap { page in
            guard let imageData = page.imageData else { return nil }
            return (page, imageData)
        }

        Task {
            var updates: [(page: Page, compressed: Data)] = []

            for (page, imageData) in pageData {
                let originalSize = imageData.count
                if let compressed = OCRService.compressImageData(imageData, quality: 0.8) {
                    // Only replace if we actually saved space
                    if compressed.count < originalSize {
                        updates.append((page, compressed))
                    }
                }
            }

            // Apply updates on main actor
            for (page, compressed) in updates {
                page.imageData = compressed
            }

            // Recalculate storage
            document.recalculateStorageSize()

            // Save changes
            try? modelContext.save()

            isOptimizing = false
            optimizingDocumentID = nil
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
            ocrService.error = error
            showingError = true
        }
    }

    @MainActor
    private func processFileURLs(_ urls: [URL]) async {
        isPreparingImport = true

        let result = await importService.processFileURLs(urls, optimizeImages: optimizeImagesOnImport)

        // Quick page count for immediate announcement (images + PDF pages)
        var estimatedPageCount = result.images.count
        for pdfURL in result.pdfURLs {
            let accessed = pdfURL.startAccessingSecurityScopedResource()
            estimatedPageCount += PDFImportService.pageCount(for: pdfURL)
            if accessed { pdfURL.stopAccessingSecurityScopedResource() }
        }

        // Announce immediately if we have content to process
        if estimatedPageCount > 0 {
            hasAnnouncedHalfway = false
            processingPageCount = estimatedPageCount
            let pageWord = estimatedPageCount == 1 ? "page" : "pages"
            AccessibilityNotification.Announcement("Processing \(estimatedPageCount) \(pageWord). This will take a few moments.").post()
        }

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
                    ocrService.error = error
                    showingError = true
                    isPreparingImport = false
                    return
                }
            }
        }

        guard !allImages.isEmpty else {
            print("No valid images found")
            isPreparingImport = false
            return
        }

        // Spinner will be replaced by document card's progress indicator
        isPreparingImport = false

        let documentName = result.suggestedName ?? "Import \(Date().formatted(date: .abbreviated, time: .shortened))"
        await startOCRProcessing(images: allImages, documentName: documentName)
    }

    // MARK: - Photos Import Handling

    @MainActor
    private func processSelectedPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }

        let images = await importService.processSelectedPhotos(items, optimizeImages: optimizeImagesOnImport)

        guard !images.isEmpty else {
            print("No photos could be loaded")
            selectedPhotos = []
            return
        }

        // Announce processing start before document card appears
        hasAnnouncedHalfway = false
        processingPageCount = images.count
        let pageWord = images.count == 1 ? "page" : "pages"
        AccessibilityNotification.Announcement("Processing \(images.count) \(pageWord). This will take a few moments.").post()

        let documentName = "Import \(Date().formatted(date: .abbreviated, time: .shortened))"
        await startOCRProcessing(images: images, documentName: documentName)
        selectedPhotos = []
    }

    // MARK: - Drag and Drop

    private func handleDrop(providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (item, error) in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                return
            }

            Task { @MainActor in
                await processFileURLs([url])
            }
        }
    }

    // MARK: - OCR Processing

    @MainActor
    private func startOCRProcessing(images: [(data: Data, fileName: String)], documentName: String) async {
        // Create document
        let document = Document(name: documentName, totalPages: 0)
        modelContext.insert(document)

        do {
            try modelContext.save()
        } catch {
            print("Failed to save document: \(error)")
            ocrService.error = error
            showingError = true
            return
        }

        let documentID = document.persistentModelID
        processingDocumentIDs.insert(documentID)

        // Process images in background
        Task.detached(priority: .userInitiated) { [ocrService, images, documentID] in
            do {
                let results = try await ocrService.processImages(images)

                await MainActor.run {
                    self.updateDocument(with: results, id: documentID)
                }
            } catch {
                await MainActor.run {
                    self.handleProcessingFailure(for: documentID, error: error)
                }
            }
        }
    }

    @MainActor
    private func updateDocument(with results: [ProcessedImage], id: PersistentIdentifier) {
        guard let document = modelContext.model(for: id) as? Document else { return }

        document.totalPages = results.count

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

        // Calculate storage size after all pages are added
        document.recalculateStorageSize()

        // Build text export cache while page richText is still in memory
        // This avoids external storage loads when exporting later
        TextExportCacheService.buildInitialCache(for: document, from: document.pages)

        do {
            try modelContext.save()
        } catch {
            print("Failed to save OCR results: \(error)")
        }

        processingDocumentIDs.remove(id)

        // Announce completion
        let pageCount = results.count
        let pageWord = pageCount == 1 ? "page" : "pages"
        AccessibilityNotification.Announcement("Scan complete. \(pageCount) \(pageWord) ready for review.").post()
    }

    @MainActor
    private func handleProcessingFailure(for documentID: PersistentIdentifier, error: Error) {
        if let document = modelContext.model(for: documentID) as? Document {
            modelContext.delete(document)
        }
        try? modelContext.save()

        processingDocumentIDs.remove(documentID)

        ocrService.error = error
        showingError = true
    }

}

#Preview("English") {
    HomeView(onDocumentSelected: { _ in })
        .modelContainer(for: [Document.self, Page.self], inMemory: true)
        .environment(\.locale, Locale(identifier: "en"))
}

#Preview("es-419") {
    HomeView(onDocumentSelected: { _ in })
        .modelContainer(for: [Document.self, Page.self], inMemory: true)
        .environment(\.locale, Locale(identifier: "es-419"))
}
