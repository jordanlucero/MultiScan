import SwiftUI

/// Background color options for the image viewer
enum ViewerBackground: String, CaseIterable {
    case `default` = "default"
    case white = "white"
    case lightGray = "lightGray"
    case gray = "gray"
    case mediumGray = "mediumGray"
    case darkGray = "darkGray"
    case black = "black"

    var label: LocalizedStringResource {
        switch self {
        case .default: LocalizedStringResource("Default", comment: "Viewer background option: system default")
        case .white: LocalizedStringResource("White", comment: "Viewer background option: white color")
        case .lightGray: LocalizedStringResource("Light Gray", comment: "Viewer background option: light gray color")
        case .gray: LocalizedStringResource("Gray", comment: "Viewer background option: gray color")
        case .mediumGray: LocalizedStringResource("Medium Gray", comment: "Viewer background option: medium gray color")
        case .darkGray: LocalizedStringResource("Dark Gray", comment: "Viewer background option: dark gray color")
        case .black: LocalizedStringResource("Black", comment: "Viewer background option: black color")
        }
    }

    var color: Color? {
        switch self {
        case .default: nil
        case .white: .white
        case .lightGray: Color(white: 0.9)
        case .gray: Color(white: 0.6)
        case .mediumGray: Color(white: 0.4)
        case .darkGray: Color(white: 0.2)
        case .black: .black
        }
    }
}

struct ImageViewer: View {
    let document: Document
    @ObservedObject var navigationState: NavigationState

    // Settings
    @AppStorage("viewerBackground") private var viewerBackgroundRaw = ViewerBackground.default.rawValue

    private var viewerBackground: ViewerBackground {
        ViewerBackground(rawValue: viewerBackgroundRaw) ?? .default
    }

    // Use SwiftUI Image for cross-platform compatibility
    @State private var displayImage: Image?
    @State private var imageSize: CGSize = .zero
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var isHovering: Bool = false
    @FocusState private var focusedButton: ZoomButton?

    // Task management for cleanup on view dismissal
    @State private var imageLoadingTask: Task<Void, Never>?
    @State private var isViewActive: Bool = true

    enum ZoomButton {
        case fit, zoomIn, zoomOut
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Use user-selected selected background color, or let system decide for default
                if let backgroundColor = viewerBackground.color {
                    backgroundColor
                        .backgroundExtensionEffect()
                }

                if let image = displayImage {
                    ScrollView([.horizontal, .vertical]) {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .contrast(navigationState.currentPage?.increaseContrast == true ? 1.3 : 1.0)
                            .brightness(navigationState.currentPage?.increaseBlackPoint == true ? -0.1 : 0.0)
                            .frame(
                                width: fittedImageSize(in: geometry.size).width * scale,
                                height: fittedImageSize(in: geometry.size).height * scale
                            )
                            .frame(
                                minWidth: geometry.size.width,
                                minHeight: geometry.size.height
                            )
                    }
                    .scrollContentBackground(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollIndicators(.automatic)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let newScale = lastScale * value
                                scale = min(max(newScale, 0.1), 10.0) // Clamp between 0.1x and 10x
                            }
                            .onEnded { _ in
                                lastScale = scale
                            }
                    )
                    .accessibilityLabel("Page image")
                    .accessibilityValue("Zoom \(Int(scale * 100)) percent")
                    .accessibilityAction(named: "Zoom In") {
                        scale *= 1.25
                        lastScale = scale
                    }
                    .accessibilityAction(named: "Zoom Out") {
                        scale *= 0.8
                        lastScale = scale
                    }
                    .accessibilityAction(named: "Fit to Window") {
                        scale = 1.0
                        lastScale = 1.0
                    }
                } else {
                    ProgressView("Loading image…")
                }
            }
            .overlay(alignment: .topTrailing) {
                zoomControls
            }
            .onHover { hovering in
                isHovering = hovering
            }
        }
        .onChange(of: navigationState.currentPage) { _, newPage in
            loadImage(for: newPage)
        }
        .onChange(of: navigationState.currentPage?.rotation) { _, _ in
            reloadImageForRotation()
        }
        .onAppear {
            isViewActive = true
            loadImage(for: navigationState.currentPage)
        }
        .onDisappear {
            // Cancel any pending image loading task and mark view as inactive
            // This prevents crashes when the view hierarchy is torn down while
            // an async task is still loading an image for a large document
            isViewActive = false
            imageLoadingTask?.cancel()
            imageLoadingTask = nil
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

    @ViewBuilder
    private var zoomControls: some View {
        HStack {
            Button(action: { scale = 1.0; lastScale = 1.0 }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .accessibilityLabel("Fit to Window")
            .help("Fit to Window")
            .focused($focusedButton, equals: .fit)

            Button(action: { scale *= 1.25; lastScale = scale }) {
                Image(systemName: "plus.magnifyingglass")
            }
            .accessibilityLabel("Zoom In")
            .help("Zoom In")
            .focused($focusedButton, equals: .zoomIn)

            Button(action: { scale *= 0.8; lastScale = scale }) {
                Image(systemName: "minus.magnifyingglass")
            }
            .accessibilityLabel("Zoom Out")
            .help("Zoom Out")
            .focused($focusedButton, equals: .zoomOut)
        }
        .padding()
        .glassEffect()
        .opacity(controlsVisible ? 1.0 : 0.0)
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        .accessibilityHidden(false) // Keep accessible to VoiceOver regardless of opacity
    }

    private var controlsVisible: Bool {
        isHovering || focusedButton != nil
    }

    /// Calculate the size the image would be when fit into the container while preserving aspect ratio
    private func fittedImageSize(in containerSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return containerSize
        }

        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = containerSize.width / containerSize.height

        if imageAspect > containerAspect {
            // Image is wider than container - fit to width
            let width = containerSize.width
            let height = width / imageAspect
            return CGSize(width: width, height: height)
        } else {
            // Image is taller than container - fit to height
            let height = containerSize.height
            let width = height * imageAspect
            return CGSize(width: width, height: height)
        }
    }

    private func loadImage(for page: Page?) {
        // Cancel any existing loading task before starting a new one
        imageLoadingTask?.cancel()
        imageLoadingTask = nil

        guard let page = page,
              let imageData = page.imageData else {
            displayImage = nil
            return
        }

        let rotation = page.rotation

        imageLoadingTask = Task { [weak navigationState] in
            // Check if task was cancelled before doing work
            guard !Task.isCancelled else { return }

            // Use cross-platform helper to create SwiftUI Image from Data with rotation
            if let image = PlatformImage.from(data: imageData, userRotation: rotation) {
                let size = PlatformImage.dimensions(of: imageData, userRotation: rotation) ?? .zero

                // Check cancellation again before updating UI
                guard !Task.isCancelled else { return }

                await MainActor.run { [weak navigationState] in
                    // Guard against updating state after view has disappeared
                    // This prevents crashes when the window is deallocating
                    guard self.isViewActive, navigationState != nil else { return }
                    self.displayImage = image
                    self.imageSize = size
                    self.scale = 1.0
                    self.lastScale = 1.0
                }
            } else {
                print("Failed to load image for page: \(page.pageNumber)")
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.isViewActive else { return }
                    self.displayImage = nil
                }
            }
        }
    }

    /// Reload image when rotation changes
    private func reloadImageForRotation() {
        loadImage(for: navigationState.currentPage)
    }
}
