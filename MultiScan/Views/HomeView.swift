import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var documents: [Document]
    @StateObject private var ocrService = OCRService()
    @State private var selectedFolderURL: URL?
    @State private var showingFolderPicker = false
    @State private var showingProgress = false
    @State private var showingError = false
    
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
            
            if let folderURL = selectedFolderURL {
                VStack(spacing: 10) {
                    Label(folderURL.lastPathComponent, systemImage: "folder.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button(action: startOCR) {
                        Label("Start OCR Processing", systemImage: "text.viewfinder")
                            .frame(minWidth: 200)
                    }
                    .controlSize(.large)
                    .disabled(ocrService.isProcessing)
                }
            }
            
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
                            NavigationLink(destination: ReviewView(document: document)) {
                                Text("Review")
                                    .font(.caption)
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
                        // We'll stop accessing after creating the bookmark in startOCR
                    } else {
                        print("Failed to access security-scoped resource")
                    }
                }
            case .failure(let error):
                print("Folder selection error: \(error)")
            }
        }
        .sheet(isPresented: $showingProgress) {
            OCRProgressView(ocrService: ocrService)
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
    }
    
    private func selectFolder() {
        showingFolderPicker = true
    }
    
    private func startOCR() {
        guard let folderURL = selectedFolderURL else { return }
        
        showingProgress = true
        
        Task {
            do {
                // Create bookmark while we have access
                let bookmarkData = SecurityScopedResourceManager.shared.createBookmark(for: folderURL)
                
                // Process images (OCRService will handle its own security scope)
                let results = try await ocrService.processImagesInFolder(at: folderURL, bookmarkData: bookmarkData)
                
                // Stop accessing the original URL since we have a bookmark now
                folderURL.stopAccessingSecurityScopedResource()
                
                let document = Document(
                    name: folderURL.lastPathComponent,
                    folderPath: folderURL.path,
                    folderBookmark: bookmarkData,
                    totalPages: results.count
                )
                
                modelContext.insert(document)
                
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
                
                try modelContext.save()
                showingProgress = false
                
            } catch {
                ocrService.error = error
                showingProgress = false
                showingError = true
                // Make sure to stop accessing on error too
                folderURL.stopAccessingSecurityScopedResource()
            }
        }
    }
}