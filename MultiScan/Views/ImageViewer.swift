import SwiftUI

struct ImageViewer: View {
    let document: Document
    @ObservedObject var navigationState: NavigationState
    @State private var image: NSImage?
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var isHovering: Bool = false
    @FocusState private var focusedButton: ZoomButton?

    enum ZoomButton {
        case fit, zoomIn, zoomOut
    }

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
                    .focused($focusedButton, equals: .fit)

                    Button(action: { scale *= 1.25; lastScale = scale }) {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .help("Zoom In")
                    .focused($focusedButton, equals: .zoomIn)

                    Button(action: { scale *= 0.8; lastScale = scale }) {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .help("Zoom Out")
                    .focused($focusedButton, equals: .zoomOut)
                }
                .padding()
                .glassEffect()
                .padding()
                .opacity(isHovering || focusedButton != nil ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.25), value: isHovering || focusedButton != nil)
            }
            .onHover { hovering in
                isHovering = hovering
            }
        }
        .onChange(of: navigationState.currentPage) { _, newPage in
            loadImage(for: newPage)
        }
        .onAppear {
            loadImage(for: navigationState.currentPage)
        }
        .onReceive(NotificationCenter.default.publisher(for: .zoomIn)) { _ in
            scale *= 1.25
            lastScale = scale
        }
        .onReceive(NotificationCenter.default.publisher(for: .zoomOut)) { _ in
            scale *= 0.8
            lastScale = scale
        }
        .onReceive(NotificationCenter.default.publisher(for: .zoomActualSize)) { _ in
            scale = 1.0
            lastScale = 1.0
        }
    }
    
    private func loadImage(for page: Page?) {
        guard let page = page else {
            image = nil
            return
        }
        
        Task {
            do {
                // Get the folder URL from the document
                guard let folderURL = document.resolvedFolderURL() else { 
                    print("Failed to resolve folder URL")
                    return 
                }
                
                // Construct the image URL - page.imageFileName now contains the relative path
                let imageURL = folderURL.appendingPathComponent(page.imageFileName)
                
                // First, check if the file exists
                guard FileManager.default.fileExists(atPath: imageURL.path) else {
                    print("Image file does not exist: \(imageURL.path)")
                    await MainActor.run {
                        self.image = nil
                    }
                    return
                }
                
                // Start accessing the security-scoped resource
                let accessed = folderURL.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        folderURL.stopAccessingSecurityScopedResource()
                    }
                }
                
                // Try to load the image using NSImage directly with the file URL
                var loadedImage: NSImage? = NSImage(contentsOf: imageURL)
                
                if loadedImage == nil {
                    // Load the image data
                    let imageData = try Data(contentsOf: imageURL)
                    
                    // Method 1: Direct NSImage from data
                    loadedImage = NSImage(data: imageData)
                    
                    // Method 2: Use CGImageSource for better format support
                    if loadedImage == nil {
                        if let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
                           let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                            let size = NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
                            loadedImage = NSImage(cgImage: cgImage, size: size)
                        }
                    }
                    
                    // Method 3: Try NSBitmapImageRep
                    if loadedImage == nil {
                        if let bitmapRep = NSBitmapImageRep(data: imageData) {
                            loadedImage = NSImage(size: bitmapRep.size)
                            loadedImage?.addRepresentation(bitmapRep)
                        }
                    }
                }
                
                await MainActor.run {
                    if let finalImage = loadedImage {
                        self.image = finalImage
                        self.scale = 1.0
                        self.lastScale = 1.0
                    } else {
                        print("Failed to create NSImage from data for: \(imageURL.path)")
                        self.image = nil
                    }
                }
                
            } catch {
                print("Error loading image: \(error)")
                await MainActor.run {
                    self.image = nil
                }
            }
        }
    }
}
