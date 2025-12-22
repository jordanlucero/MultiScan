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

    enum ZoomButton {
        case fit, zoomIn, zoomOut
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Use selected background color, or let system decide for default
                if let backgroundColor = viewerBackground.color {
                    backgroundColor
                }

                if let image = displayImage {
                    ScrollView([.horizontal, .vertical]) {
                        image
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
                zoomControls
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

    @ViewBuilder
    private var zoomControls: some View {
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
        .opacity(controlsVisible ? 1.0 : 0.0)
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
    }

    private var controlsVisible: Bool {
        isHovering || focusedButton != nil
    }

    private func loadImage(for page: Page?) {
        guard let page = page,
              let imageData = page.imageData else {
            displayImage = nil
            return
        }

        Task {
            // Use cross-platform helper to create SwiftUI Image from Data
            if let image = PlatformImage.from(data: imageData) {
                let size = PlatformImage.dimensions(of: imageData) ?? .zero
                await MainActor.run {
                    self.displayImage = image
                    self.imageSize = size
                    self.scale = 1.0
                    self.lastScale = 1.0
                }
            } else {
                print("Failed to load image for page: \(page.pageNumber)")
                await MainActor.run {
                    self.displayImage = nil
                }
            }
        }
    }
}
