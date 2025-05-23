import SwiftUI

struct ImageViewer: View {
    let document: Document
    @ObservedObject var navigationState: NavigationState
    @State private var image: NSImage?
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(NSColor.controlBackgroundColor)
                
                if let image = image {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .scaleEffect(scale)
                            .frame(
                                width: geometry.size.width * scale,
                                height: geometry.size.height * scale
                            )
                    }
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = lastScale * value
                            }
                            .onEnded { value in
                                lastScale = scale
                            }
                    )
                } else {
                    ProgressView("Loading image...")
                }
            }
            .overlay(alignment: .topTrailing) {
                HStack {
                    Button(action: { scale = 1.0; lastScale = 1.0 }) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .help("Fit to Window")
                    
                    Button(action: { scale *= 1.25; lastScale = scale }) {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .help("Zoom In")
                    
                    Button(action: { scale *= 0.8; lastScale = scale }) {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .help("Zoom Out")
                }
                .padding()
                .background(.regularMaterial)
                .cornerRadius(8)
                .padding()
            }
        }
        .onChange(of: navigationState.currentPage) { _, newPage in
            loadImage(for: newPage)
        }
        .onAppear {
            loadImage(for: navigationState.currentPage)
        }
    }
    
    private func loadImage(for page: Page?) {
        guard let page = page else {
            image = nil
            return
        }
        
        Task {
            guard let folderURL = document.resolvedFolderURL() else { return }
            
            let accessed = folderURL.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    folderURL.stopAccessingSecurityScopedResource()
                }
            }
            
            let imageURL = folderURL.appendingPathComponent(page.imageFileName)
            
            if let loadedImage = NSImage(contentsOf: imageURL) {
                await MainActor.run {
                    self.image = loadedImage
                    self.scale = 1.0
                    self.lastScale = 1.0
                }
            } else {
                print("Failed to load image from: \(imageURL.path)")
                print("File exists: \(FileManager.default.fileExists(atPath: imageURL.path))")
            }
        }
    }
}