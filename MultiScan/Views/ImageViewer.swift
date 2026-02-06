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

    // Processed image ready for display (rotated + adjusted)
    @State private var processedImage: CGImage?
    // Identity of the current page — changes trigger zoom reset in ZoomableImageView
    @State private var imageIdentity: String = ""
    // Zoom scale reported back from platform scroll view (1.0 = fit-to-window)
    @State private var currentScale: CGFloat = 1.0
    @State private var isHovering: Bool = false
    @FocusState private var focusedButton: ZoomButton?

    // Task management for cleanup on view dismissal
    @State private var imageLoadingTask: Task<Void, Never>?
    @State private var isViewActive: Bool = true

    enum ZoomButton {
        case fit, zoomIn, zoomOut
    }

    var body: some View {
        ZStack {
            // Background color
            if let backgroundColor = viewerBackground.color {
                backgroundColor
                    .backgroundExtensionEffect()
            }

            if let cgImage = processedImage {
                GeometryReader { geometry in
                    ZoomableImageView(
                        cgImage: cgImage,
                        imageIdentity: imageIdentity,
                        currentScale: $currentScale,
                        safeAreaInsets: geometry.safeAreaInsets
                    )
                    .ignoresSafeArea()
                }
                .accessibilityLabel("Page image")
                .accessibilityValue("Zoom \(Int(currentScale * 100)) percent")
                .accessibilityAction(named: "Zoom In") {
                    NotificationCenter.default.post(name: .zoomIn, object: nil)
                }
                .accessibilityAction(named: "Zoom Out") {
                    NotificationCenter.default.post(name: .zoomOut, object: nil)
                }
                .accessibilityAction(named: "Fit to Window") {
                    NotificationCenter.default.post(name: .zoomActualSize, object: nil)
                }
            } else {
                ProgressView("Loading image…")
            }
        }
        .overlay(alignment: .topTrailing) {
            zoomControls
                .padding()
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .onChange(of: navigationState.currentPage) { _, newPage in
            processImage(for: newPage, isNewPage: true)
        }
        .onChange(of: navigationState.currentPage?.rotation) { _, _ in
            processImage(for: navigationState.currentPage, isNewPage: true)
        }
        .onChange(of: navigationState.currentPage?.increaseContrast) { _, _ in
            processImage(for: navigationState.currentPage, isNewPage: false)
        }
        .onChange(of: navigationState.currentPage?.increaseBlackPoint) { _, _ in
            processImage(for: navigationState.currentPage, isNewPage: false)
        }
        .onAppear {
            isViewActive = true
            processImage(for: navigationState.currentPage, isNewPage: true)
        }
        .onDisappear {
            isViewActive = false
            imageLoadingTask?.cancel()
            imageLoadingTask = nil
        }
    }

    @ViewBuilder
    private var zoomControls: some View {
        HStack {
            Button(action: {
                NotificationCenter.default.post(name: .zoomActualSize, object: nil)
            }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .accessibilityLabel("Fit to Window")
            .help("Fit to Window")
            .focused($focusedButton, equals: .fit)

            Button(action: {
                NotificationCenter.default.post(name: .zoomIn, object: nil)
            }) {
                Image(systemName: "plus.magnifyingglass")
            }
            .accessibilityLabel("Zoom In")
            .help("Zoom In")
            .focused($focusedButton, equals: .zoomIn)

            Button(action: {
                NotificationCenter.default.post(name: .zoomOut, object: nil)
            }) {
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

    // MARK: - Image Processing

    private func processImage(for page: Page?, isNewPage: Bool) {
        imageLoadingTask?.cancel()
        imageLoadingTask = nil

        guard let page = page,
              let imageData = page.imageData else {
            processedImage = nil
            return
        }

        let rotation = page.rotation
        let contrast = page.increaseContrast
        let blackPoint = page.increaseBlackPoint
        let identity = "\(page.pageNumber)-\(rotation)"

        imageLoadingTask = Task {
            guard !Task.isCancelled else { return }

            let cgImage = PlatformImage.processedCGImage(
                from: imageData,
                userRotation: rotation,
                increaseContrast: contrast,
                increaseBlackPoint: blackPoint
            )

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard self.isViewActive else { return }
                if isNewPage {
                    self.imageIdentity = identity
                }
                self.processedImage = cgImage
            }
        }
    }
}
