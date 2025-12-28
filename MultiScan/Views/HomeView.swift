import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import PhotosUI

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var documents: [Document]
    @StateObject private var ocrService = OCRService()

    // Import state
    @State private var showingFilePicker = false
    @State private var selectedPhotos: [PhotosPickerItem] = []

    // UI state
    @State private var showingError = false
    @State private var documentToDelete: Document?
    @State private var showingDeleteConfirmation = false
    @State private var processingDocumentIDs: Set<PersistentIdentifier> = []
    @State private var isDragOver = false
    @State private var isOptimizing = false
    @State private var optimizingDocumentID: PersistentIdentifier?

    // Settings
    @AppStorage("optimizeImagesOnImport") private var optimizeImagesOnImport = false

    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            Text("MultiScan")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Import images to start scanning")
                .font(.headline)
                .foregroundColor(.secondary)

            // Import buttons
            VStack(spacing: 12) {
                // Photos picker
                PhotosPicker(
                    selection: $selectedPhotos,
                    maxSelectionCount: nil,
                    matching: .images
                ) {
                    Label("Import from Photos", systemImage: "photo.on.rectangle")
                        .frame(minWidth: 200)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .onChange(of: selectedPhotos) { _, items in
                    Task { await processSelectedPhotos(items) }
                }

                // Files picker (individual files OR folders)
                Button(action: { showingFilePicker = true }) {
                    Label("Import from Files", systemImage: "folder")
                        .frame(minWidth: 200)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)

                #if os(macOS)
                // Camera (Continuity Camera on Mac)
                Button(action: { /* TODO: Implement Continuity Camera */ }) {
                    Label("Import from iPhone or iPad", systemImage: "camera")
                        .frame(minWidth: 200)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .disabled(true) // TODO: Enable when implemented
                #endif
            }

            if !documents.isEmpty {
                Divider()

                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 16)
                    ], spacing: 16) {
                        ForEach(documents.sorted(by: { $0.createdAt > $1.createdAt })) { document in
                            NavigationLink {
                                ReviewView(document: document)
                            } label: {
                                DocumentCard(
                                    document: document,
                                    isProcessing: processingDocumentIDs.contains(document.persistentModelID),
                                    ocrProgress: ocrService.progress,
                                    onDelete: {
                                        documentToDelete = document
                                        showingDeleteConfirmation = true
                                    },
                                    onOptimize: { optimizeImages(for: document) }
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(processingDocumentIDs.contains(document.persistentModelID))
                        }
                    }
                    .padding()
                }
            }
        }
        .padding(.vertical, 50)
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isDragOver ? Color.accentColor.opacity(0.1) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
            handleDrop(providers: providers)
            return true
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.image, .folder],
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
            "Delete Document",
            isPresented: $showingDeleteConfirmation,
            presenting: documentToDelete
        ) { document in
            Button("Delete", role: .destructive) {
                deleteDocument(document)
            }
            Button("Cancel", role: .cancel) {}
        } message: { document in
            Text("Are you sure you want to delete the MultiScan project for \"\(document.name)\"? This can't be undone.")
        }
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
        var images: [(data: Data, fileName: String)] = []

        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }

            if isDirectory.boolValue {
                // It's a folder - enumerate contents
                if let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.contentTypeKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    while let fileURL = enumerator.nextObject() as? URL {
                        // Check if file conforms to image type using UTType
                        if let contentType = try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType,
                           contentType.conforms(to: .image),
                           let data = try? Data(contentsOf: fileURL) {
                            let finalData = optimizeImagesOnImport ? (OCRService.compressImageData(data) ?? data) : data
                            images.append((data: finalData, fileName: fileURL.lastPathComponent))
                        }
                    }
                }
            } else {
                // It's an individual file - check if it's an image using UTType
                if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
                   contentType.conforms(to: .image),
                   let data = try? Data(contentsOf: url) {
                    let finalData = optimizeImagesOnImport ? (OCRService.compressImageData(data) ?? data) : data
                    images.append((data: finalData, fileName: url.lastPathComponent))
                }
            }
        }

        guard !images.isEmpty else {
            print("No valid images found")
            return
        }

        // Sort by filename
        images.sort { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }

        // Generate document name
        let documentName: String
        if urls.count == 1, let firstURL = urls.first {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: firstURL.path, isDirectory: &isDir)
            if isDir.boolValue {
                documentName = firstURL.lastPathComponent
            } else {
                documentName = "Import \(Date().formatted(date: .abbreviated, time: .shortened))"
            }
        } else {
            documentName = "Import \(Date().formatted(date: .abbreviated, time: .shortened))"
        }

        await startOCRProcessing(images: images, documentName: documentName)
    }

    // MARK: - Photos Import Handling

    @MainActor
    private func processSelectedPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }

        var images: [(data: Data, fileName: String)] = []

        for (index, item) in items.enumerated() {
            // Use loadFileRepresentation to get both data and original filename
            if let result = await loadPhotoWithFilename(item: item, index: index) {
                let finalData = optimizeImagesOnImport ? (OCRService.compressImageData(result.data) ?? result.data) : result.data
                images.append((data: finalData, fileName: result.fileName))
            }
        }

        guard !images.isEmpty else {
            print("No photos could be loaded")
            selectedPhotos = []
            return
        }

        let documentName = "Import \(Date().formatted(date: .abbreviated, time: .shortened))"
        await startOCRProcessing(images: images, documentName: documentName)
        selectedPhotos = []
    }

    /// Load photo data and retrieve original filename using file representation
    private func loadPhotoWithFilename(item: PhotosPickerItem, index: Int) async -> (data: Data, fileName: String)? {
        // Try to load as file representation to get the original filename
        do {
            let result = try await item.loadTransferable(type: PhotoFileTransferable.self)
            if let result = result {
                return (data: result.data, fileName: result.fileName)
            }
        } catch {
            print("Failed to load file representation: \(error)")
        }

        // Fallback: load as raw data without filename
        if let data = try? await item.loadTransferable(type: Data.self) {
            return (data: data, fileName: String(localized: "Photo \(index + 1)", comment: "Fallback filename for imported photo"))
        }

        return nil
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

        do {
            try modelContext.save()
        } catch {
            print("Failed to save OCR results: \(error)")
        }

        processingDocumentIDs.remove(id)
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

// MARK: - Photo File Transferable

/// Custom Transferable type to load photos with their original filenames
struct PhotoFileTransferable: Transferable {
    let data: Data
    let fileName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let fileName = received.file.lastPathComponent
            let data = try Data(contentsOf: received.file)
            return PhotoFileTransferable(data: data, fileName: fileName)
        }
    }
}

// Previews use ContentView since HomeView now requires coordinator
#Preview("English") {
    ContentView()
        .modelContainer(for: [Document.self, Page.self], inMemory: true)
        .environment(\.locale, Locale(identifier: "en"))
}

#Preview("es-419") {
    ContentView()
        .modelContainer(for: [Document.self, Page.self], inMemory: true)
        .environment(\.locale, Locale(identifier: "es-419"))
}
