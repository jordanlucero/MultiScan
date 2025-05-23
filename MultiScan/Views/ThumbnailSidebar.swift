import SwiftUI

struct ThumbnailSidebar: View {
    let document: Document
    @ObservedObject var navigationState: NavigationState
    @Binding var selectedPageNumber: Int?
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(document.pages.sorted(by: { $0.pageNumber < $1.pageNumber })) { page in
                        ThumbnailView(
                            page: page,
                            document: document,
                            isSelected: selectedPageNumber == page.pageNumber
                        ) {
                            navigationState.goToPage(pageNumber: page.pageNumber)
                            selectedPageNumber = page.pageNumber
                        }
                        .id(page.pageNumber)
                    }
                }
                .padding()
            }
            .background(Color(NSColor.controlBackgroundColor))
            .onChange(of: selectedPageNumber) { _, newValue in
                if let pageNumber = newValue {
                    withAnimation {
                        proxy.scrollTo(pageNumber, anchor: .center)
                    }
                }
            }
        }
    }
}

struct ThumbnailView: View {
    let page: Page
    let document: Document
    let isSelected: Bool
    let action: () -> Void
    
    @State private var thumbnail: NSImage?
    
    var body: some View {
        VStack(spacing: 4) {
            Button(action: action) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.controlColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                        )
                    
                    if let thumbnail = thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(4)
                    } else {
                        ProgressView()
                            .scaleEffect(0.5)
                    }
                }
                .aspectRatio(8.5/11, contentMode: .fit)
            }
            .buttonStyle(.plain)
            
            Text(page.imageFileName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(isSelected ? .accentColor : .secondary)
        }
        .onAppear {
            loadThumbnail()
        }
    }
    
    private func loadThumbnail() {
        Task {
            guard let folderURL = document.resolvedFolderURL() else { return }
            
            let accessed = folderURL.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    folderURL.stopAccessingSecurityScopedResource()
                }
            }
            
            let imageURL = folderURL.appendingPathComponent(page.imageFileName)
            
            if let image = NSImage(contentsOf: imageURL) {
                let thumbnailSize = NSSize(width: 150, height: 200)
                let thumbnailImage = NSImage(size: thumbnailSize)
                
                thumbnailImage.lockFocus()
                image.draw(in: NSRect(origin: .zero, size: thumbnailSize),
                          from: NSRect(origin: .zero, size: image.size),
                          operation: .copy,
                          fraction: 1.0)
                thumbnailImage.unlockFocus()
                
                await MainActor.run {
                    self.thumbnail = thumbnailImage
                }
            }
        }
    }
}