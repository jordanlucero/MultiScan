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
            
            Text("Select a folder containing images to perform OCR")
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
                                    ProgressView()
                                        .controlSize(.small)
                                        .frame(width: 40)
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
            Text("Are you sure you want to delete \"\(document.name)\"? This will remove all OCR data and cannot be undone.")
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
    
    private func startOCRImmediately(for folderURL: URL, needsSecurityScope: Bool = false) {
        Task {
            do {
                // Create bookmark while we have access
                let bookmarkData = SecurityScopedResourceManager.shared.createBookmark(for: folderURL)
                
                // Create document immediately and show it in the list
                let document = Document(
                    name: folderURL.lastPathComponent,
                    folderPath: folderURL.path,
                    folderBookmark: bookmarkData,
                    totalPages: 0  // Will update after processing
                )
                
                modelContext.insert(document)
                try modelContext.save()
                
                // Track this document as processing
                processingDocumentIDs.insert(document.persistentModelID)
                
                // Clear the selected folder
                selectedFolderURL = nil
                
                // Process images in background
                Task.detached {
                    do {
                        // Process images (OCRService will handle its own security scope)
                        let results = try await self.ocrService.processImagesInFolder(at: folderURL, bookmarkData: bookmarkData)
                        
                        // Stop accessing the original URL if we started access
                        if needsSecurityScope {
                            folderURL.stopAccessingSecurityScopedResource()
                        }
                        
                        // Update the document with results on main thread
                        await MainActor.run {
                            document.totalPages = results.count
                            
                            for result in results {
                                let page = Page(
                                    pageNumber: result.pageNumber,
                                    text: result.text,
                                    imageFileName: result.fileName
                                )
                                page.thumbnailData = result.thumbnailData
                                page.document = document
                                document.pages.append(page)
                            }
                            
                            do {
                                try self.modelContext.save()
                            } catch {
                                print("Failed to save OCR results: \(error)")
                            }
                            
                            // Remove from processing set
                            self.processingDocumentIDs.remove(document.persistentModelID)
                        }
                    } catch {
                        // Handle error on main thread
                        await MainActor.run {
                            self.processingDocumentIDs.remove(document.persistentModelID)
                            // Optionally delete the failed document
                            self.modelContext.delete(document)
                            try? self.modelContext.save()
                            
                            self.ocrService.error = error
                            self.showingError = true
                        }
                        // Make sure to stop accessing on error too
                        if needsSecurityScope {
                            folderURL.stopAccessingSecurityScopedResource()
                        }
                    }
                }
            } catch {
                // Handle immediate errors (e.g., bookmark creation failure)
                self.ocrService.error = error
                self.showingError = true
                if needsSecurityScope {
                    folderURL.stopAccessingSecurityScopedResource()
                }
            }
        }
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