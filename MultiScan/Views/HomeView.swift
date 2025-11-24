import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var documents: [Document]
    @StateObject private var ocrService = OCRService()
    @State private var selectedFolderURL: URL?
    @State private var showingFolderPicker = false
    @State private var showingError = false
    @State private var documentToDelete: Document?
    @State private var showingDeleteConfirmation = false
    @State private var processingDocumentIDs: Set<PersistentIdentifier> = []
    @State private var isDragOver = false
    
    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)
            
            Text("MultiScan")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Select a folder containing images to start")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Button(action: selectFolder) {
                Label("Select Folder", systemImage: "folder")
                    .frame(minWidth: 200)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            
            if !documents.isEmpty {
                Divider()
                
                VStack(alignment: .leading, spacing: 10) {
                    Text("Recent Documents")
                        .font(.headline)
                    
                    ForEach(documents.sorted(by: { $0.createdAt > $1.createdAt }).prefix(5)) { document in
                        HStack {
                            Image(systemName: "doc.text.fill")
                            VStack(alignment: .leading) {
                                Text(document.name)
                                    .font(.subheadline)
                                Text("\(document.totalPages) pages")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            
                            HStack(spacing: 8) {
                                if processingDocumentIDs.contains(document.persistentModelID) {
                                    HStack(spacing: 10) {
                                        ProgressView(value: ocrService.progress, total: 1.0)
                                            .progressViewStyle(.linear)
                                            .frame(width: 200)
                                        ProgressView()
                                            .controlSize(.small)
                                    }
                                } else {
                                    NavigationLink(destination: ReviewView(document: document)) {
                                        Text("Review")
                                            .font(.caption)
                                    }
                                }
                                
                                Button(action: { 
                                    documentToDelete = document
                                    showingDeleteConfirmation = true
                                }) {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                                .help("Delete document")
                                .disabled(processingDocumentIDs.contains(document.persistentModelID))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .frame(maxWidth: 400)
            }
        }
        .padding(50)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isDragOver ? Color.accentColor.opacity(0.1) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
            handleDrop(providers: providers)
            return true
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    // Start accessing the security-scoped resource immediately
                    if url.startAccessingSecurityScopedResource() {
                        selectedFolderURL = url
                        // Start OCR processing immediately
                        startOCRImmediately(for: url, needsSecurityScope: true)
                    } else {
                        print("Failed to access security-scoped resource")
                    }
                }
            case .failure(let error):
                print("Folder selection error: \(error)")
            }
        }
        .alert("Error", isPresented: $showingError, presenting: ocrService.error) { _ in
            Button("OK") { }
        } message: { error in
            Text(error.localizedDescription)
        }
        .onDisappear {
            // Clean up any security-scoped resource access
            if let url = selectedFolderURL {
                url.stopAccessingSecurityScopedResource()
            }
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
            Text("Are you sure you want to delete the MultiScan project for \"\(document.name)\"? This will delete the OCR data and can't be undone.")
        }
    }
    
    private func selectFolder() {
        showingFolderPicker = true
    }
    
    private func deleteDocument(_ document: Document) {
        // Delete the document from the model context
        modelContext.delete(document)
        
        // Save the changes
        do {
            try modelContext.save()
        } catch {
            print("Failed to delete document: \(error)")
        }
    }
    
    @MainActor
    private func startOCRImmediately(for folderURL: URL, needsSecurityScope: Bool = false) {
        do {
            let bookmarkData = SecurityScopedResourceManager.shared.createBookmark(for: folderURL)
            
            let document = Document(
                name: folderURL.lastPathComponent,
                folderPath: folderURL.path,
                folderBookmark: bookmarkData,
                totalPages: 0
            )
            
            modelContext.insert(document)
            try modelContext.save()
            
            let documentID = document.persistentModelID
            
            processingDocumentIDs.insert(documentID)
            selectedFolderURL = nil
            
            Task.detached(priority: .userInitiated) { [ocrService, bookmarkData, needsSecurityScope, folderURL, documentID] in
                do {
                    let results = try await ocrService.processImagesInFolder(at: folderURL, bookmarkData: bookmarkData)
                    
                    if needsSecurityScope {
                        folderURL.stopAccessingSecurityScopedResource()
                    }
                    
                    await MainActor.run {
                        updateDocument(with: results, id: documentID)
                    }
                } catch {
                    if needsSecurityScope {
                        folderURL.stopAccessingSecurityScopedResource()
                    }
                    
                    await MainActor.run {
                        handleProcessingFailure(for: documentID, error: error)
                    }
                }
            }
        } catch {
            self.ocrService.error = error
            self.showingError = true
            if needsSecurityScope {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }
    }

    @MainActor
    private func updateDocument(with results: [(pageNumber: Int, text: String, fileName: String, thumbnailData: Data?, boundingBoxesData: Data?)], id: PersistentIdentifier) {
        guard let document = modelContext.model(for: id) as? Document else { return }
        
        document.totalPages = results.count
        
        for result in results {
            let page = Page(
                pageNumber: result.pageNumber,
                text: result.text,
                imageFileName: result.fileName,
                boundingBoxesData: result.boundingBoxesData
            )
            page.thumbnailData = result.thumbnailData
            page.document = document
            document.pages.append(page)
        }
        
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
    
    private func handleDrop(providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (item, error) in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                return
            }
            
            // Check if it's a directory
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                // Not a folder, ignore
                return
            }
            
            DispatchQueue.main.async {
                // For drag and drop, the URL already has implicit access
                self.selectedFolderURL = url
                // Start OCR processing immediately
                self.startOCRImmediately(for: url)
            }
        }
    }
}
