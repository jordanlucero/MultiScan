import SwiftUI
import SwiftData

/// Background color options for the image viewer
enum ViewerBackground: String, CaseIterable {
    case `system` = "system"
    case white = "white"
    case lightGray = "lightGray"
    case gray = "gray"
    case mediumGray = "mediumGray"
    case darkGray = "darkGray"
    case black = "black"

    var label: LocalizedStringResource {
        switch self {
        case .system: LocalizedStringResource("System", comment: "Viewer background option: system default")
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
        case .system: nil
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
    @ObservedObject var navigationState: NavigationState

    // Settings
    @AppStorage("viewerBackground") private var viewerBackgroundRaw = ViewerBackground.system.rawValue
    /// Show HDR photos with full headroom; when off, the system tone-maps them to SDR.
    /// Toggled from the Image menu (macOS + iPadOS menu bar).
    @AppStorage("viewerShowsHDR") private var viewerShowsHDR = true

    private var viewerBackground: ViewerBackground {
        ViewerBackground(rawValue: viewerBackgroundRaw) ?? .system
    }

    /// Zoom command/state bridge shared with the platform scroll view and menu commands
    @State private var zoomController = ImageZoomController()
    /// Processed image ready for display (rotation + adjustments baked in)
    @State private var displayImage: ProcessedPageImage?
    @State private var isHovering: Bool = false
    @FocusState private var focusedButton: ZoomButton?

    enum ZoomButton {
        case fit, zoomIn, zoomOut
    }

    /// Everything that requires re-decoding the display image. Drives `.task(id:)`,
    /// which cancels any in-flight decode when the page or its settings change.
    private struct ImageRequest: Equatable {
        var pageID: PersistentIdentifier?
        var rotation: Int
        var increaseContrast: Bool
        var increaseBlackPoint: Bool
    }

    private var imageRequest: ImageRequest {
        let page = navigationState.currentPage
        return ImageRequest(
            pageID: page?.persistentModelID,
            rotation: page?.rotation ?? 0,
            increaseContrast: page?.increaseContrast ?? false,
            increaseBlackPoint: page?.increaseBlackPoint ?? false
        )
    }

    var body: some View {
        ZStack {
            // Background color
            if let backgroundColor = viewerBackground.color {
                backgroundColor
                    .backgroundExtensionEffect()
            }

            if let displayImage {
                GeometryReader { geometry in
                    ZoomableImageView(
                        image: displayImage,
                        controller: zoomController,
                        displaysHDR: viewerShowsHDR,
                        safeAreaInsets: geometry.safeAreaInsets
                    )
                    .ignoresSafeArea()
                }
                .accessibilityLabel("Page image")
                .accessibilityValue("Zoom \(Int(zoomController.zoomLevel * 100)) percent")
                .accessibilityAction(named: "Zoom In") {
                    zoomController.zoomIn()
                }
                .accessibilityAction(named: "Zoom Out") {
                    zoomController.zoomOut()
                }
                .accessibilityAction(named: "Fit to Window") {
                    zoomController.zoomToFit()
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
        .task(id: imageRequest) {
            await loadImage(for: imageRequest)
        }
        .focusedSceneValue(\.imageZoomController, zoomController)
    }

    @ViewBuilder
    private var zoomControls: some View {
        HStack {
            Button(action: { zoomController.zoomToFit() }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .accessibilityLabel("Fit to Window")
            .help("Fit to Window")
            .focused($focusedButton, equals: .fit)

            Button(action: { zoomController.zoomIn() }) {
                Image(systemName: "plus.magnifyingglass")
            }
            .accessibilityLabel("Zoom In")
            .help("Zoom In")
            .focused($focusedButton, equals: .zoomIn)

            Button(action: { zoomController.zoomOut() }) {
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

    private func loadImage(for request: ImageRequest) async {
        guard let page = navigationState.currentPage,
              page.persistentModelID == request.pageID,
              let imageData = page.imageData else {
            displayImage = nil
            return
        }

        // Decode + rotate + adjust off the main actor
        let cgImage = await Task.detached(priority: .userInitiated) {
            PlatformImage.processedCGImage(
                from: imageData,
                userRotation: request.rotation,
                increaseContrast: request.increaseContrast,
                increaseBlackPoint: request.increaseBlackPoint
            )
        }.value

        guard !Task.isCancelled else { return }

        if let cgImage {
            displayImage = ProcessedPageImage(
                cgImage: cgImage,
                contentID: .init(pageID: request.pageID, rotation: request.rotation)
            )
        } else {
            displayImage = nil
        }
    }
}
