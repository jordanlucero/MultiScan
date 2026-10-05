//
//  ArtworkCaptureView.swift
//  MultiScan
//
//  The macOS-screenshot-style capture overlay: the page image with a draggable, resizable rectangle; confirm to crop that region into a `PageCapture` that lands inline in the page text.
//
//  ## Flow
//  1. Something opens a session — right-click / long-press on the viewer (seeded at that point), the Image menu or More menu (seeded on the page's center), a page's context menu, or an existing capture's "Recapture…" (seeded with its rectangle).
//  2. `ArtworkCaptureView` decodes the page the way the viewer shows it (`PlatformImage.processedCGImage`: EXIF + rotation + adjustments baked in) and lets the user adjust the rectangle. Everything is in **normalized, upper-left-origin coordinates of that displayed image** — the same space `PageCapture.normalizedRect` is stored in, so a recapture starts exactly where the old one was.
//  3. Capture → `CaptureService.makeCapture` crops off the main actor, encodes HEIC + a 400 px thumbnail, and creates (or updates) the `PageCapture`. The host (`ReviewView`) then inserts the reference attachment into the page text.
//
//  Presented as a sheet (macOS/iPad) or full-screen cover (iPhone) by `ReviewView`; `ArtworkCaptureSession` is the `Identifiable` item that drives the presentation.
//
//  Snapping the rectangle to Vision's text/figure regions is a natural follow-up (the layout is on the page); 2.0 keeps the gesture free-form.
//

import SwiftUI
import SwiftData
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Session

/// The in-progress capture. `@Observable` so the overlay's controls and the crop rectangle stay in sync; `Identifiable` so `.sheet(item:)` can present it.
@Observable
final class ArtworkCaptureSession: Identifiable {
    let id = UUID()
    let page: Page
    /// Non-nil when re-cropping an existing illustration: the capture is updated in place instead of a new one being created.
    let existingCapture: PageCapture?

    /// Normalized (0…1), upper-left origin, in displayed-image space.
    var rect: CGRect
    var isDraft: Bool

    /// Default size of a fresh rectangle around the seed point (fraction of the image).
    static let seedSize = CGSize(width: 0.3, height: 0.2)

    init(page: Page, seedPoint: CGPoint?, existingCapture: PageCapture? = nil) {
        self.page = page
        self.existingCapture = existingCapture
        if let existingCapture {
            self.rect = existingCapture.normalizedRect
            self.isDraft = existingCapture.isDraft
        } else {
            let center = seedPoint ?? CGPoint(x: 0.5, y: 0.5)
            let size = Self.seedSize
            self.rect = CGRect(
                x: min(max(center.x - size.width / 2, 0), 1 - size.width),
                y: min(max(center.y - size.height / 2, 0), 1 - size.height),
                width: size.width,
                height: size.height
            )
            self.isDraft = false
        }
    }
}

// MARK: - Service

/// Cropping and model creation for captures.
nonisolated enum CaptureService {
    static let thumbnailMaxPixelSize = 400

    struct CropResult: Sendable {
        let imageData: Data
        let thumbnailData: Data?
        let pixelSize: CGSize
    }

    /// Crops `rect` (normalized, upper-left origin) out of the displayed page image and encodes it. Off the main actor: the page image can be tens of megapixels.
    @concurrent
    static func crop(_ image: CGImage, normalizedRect rect: CGRect) async -> CropResult? {
        let size = CGSize(width: image.width, height: image.height)
        let pixelRect = CGRect(
            x: rect.origin.x * size.width,
            y: rect.origin.y * size.height,
            width: rect.width * size.width,
            height: rect.height * size.height
        ).integral.intersection(CGRect(origin: .zero, size: size))
        guard pixelRect.width >= 4, pixelRect.height >= 4, let cropped = image.cropping(to: pixelRect) else { return nil }
        guard let data = PlatformImage.encode(cropped, as: .heic, quality: 0.9) else { return nil }
        let thumbnail = PlatformImage.thumbnailData(from: data, maxPixelSize: thumbnailMaxPixelSize, as: .heic, quality: 0.7)
        return CropResult(imageData: data, thumbnailData: thumbnail, pixelSize: CGSize(width: cropped.width, height: cropped.height))
    }

    /// Creates a new capture (or updates `existing`) on `page` from a crop result. Main actor: writes the model context.
    @MainActor
    @discardableResult
    static func store(_ crop: CropResult, rect: CGRect, isDraft: Bool, on page: Page, replacing existing: PageCapture?) -> PageCapture {
        let capture: PageCapture
        if let existing {
            capture = existing
            capture.imageData = crop.imageData
            capture.thumbnailData = crop.thumbnailData
            capture.normalizedRect = rect
            capture.pixelWidth = Int(crop.pixelSize.width)
            capture.pixelHeight = Int(crop.pixelSize.height)
            capture.isDraft = isDraft
            capture.lastModified = Date()
        } else {
            capture = PageCapture(page: page, imageData: crop.imageData, thumbnailData: crop.thumbnailData, normalizedRect: rect, pixelSize: crop.pixelSize, isDraft: isDraft)
            page.modelContext?.insert(capture)
            page.captures?.append(capture)
        }
        page.document?.lastModified = Date()
        page.document?.recalculateStorageSize()
        try? page.modelContext?.save()
        return capture
    }

    /// Appends the reference attachment to a page's *stored* text — for captures made on a page that isn't open in the editor (sidebar context menu). The editor path is `PageTextController.insertCapture`.
    @MainActor
    static func appendAttachmentToStoredText(for capture: PageCapture, on page: Page) {
        guard let id = capture.uuid else { return }
        let existing = NSMutableAttributedString(attributedString: page.attributedText)
        let font = PageTextStyle.storageFont
        if existing.length > 0, !existing.string.hasSuffix("\n") {
            existing.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        }
        existing.append(InlineAttachments.attributedString(for: InlineAttachments.makeCaptureAttachment(captureID: id), font: font))
        let updated = NSAttributedString(attributedString: existing)
        page.attributedText = updated
        if let document = page.document {
            TextExportCacheService.updateEntry(pageNumber: page.pageNumber, attributedText: updated, pageLastModified: page.lastModified, in: document)
        }
        try? page.modelContext?.save()
    }
}

// MARK: - View

struct ArtworkCaptureView: View {
    @Bindable var session: ArtworkCaptureSession
    let onCancel: () -> Void
    /// Called with the stored capture (new or updated) and whether it was newly created.
    let onCapture: (PageCapture, _ isNew: Bool) -> Void

    @State private var image: CGImage?
    @State private var isCapturing = false
    @State private var errorMessage: String?

    var body: some View {
        content
            .task(id: session.page.persistentModelID) { await loadImage() }
            .alert("Couldn't Capture", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
        NavigationStack {
            canvas
                .navigationTitle(session.existingCapture == nil ? "Capture Artwork" : "Recapture Artwork")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Toggle(isOn: $session.isDraft) {
                            Label("Draft", systemImage: session.isDraft ? "flag.fill" : "flag")
                        }
                        .toggleStyle(.button)
                        .help("Flag this capture as a draft to be rescanned later")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isCapturing ? "Capturing…" : "Capture") { Task { await capture() } }
                            .disabled(image == nil || isCapturing)
                            .buttonStyle(.glassProminent)
                    }
                }
        }
        #else
        VStack(spacing: 0) {
            canvas
            Divider()
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Toggle(isOn: $session.isDraft) {
                    Label("Draft — rescan later", systemImage: session.isDraft ? "flag.fill" : "flag")
                }
                .toggleStyle(.checkbox)
                .help("Flag this capture as a draft so exports remind you to rescan the page")
                Spacer()
                Button(isCapturing ? "Capturing…" : (session.existingCapture == nil ? "Capture" : "Recapture")) { Task { await capture() } }
                    .disabled(image == nil || isCapturing)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 640, idealWidth: 900, minHeight: 480, idealHeight: 700)
        #endif
    }

    private var canvas: some View {
        ZStack {
            Color.black.opacity(0.9)
            if let image {
                CropCanvas(image: image, rect: $session.rect)
                    .padding(16)
            } else {
                ProgressView("Loading page…")
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .accessibilityLabel("Artwork capture area")
        .accessibilityHint("Drag the rectangle or its handles to frame the illustration, then choose Capture.")
    }

    // MARK: Actions

    private func loadImage() async {
        let page = session.page
        guard let data = page.imageData else { return }
        let rotation = page.rotation
        let contrast = page.increaseContrast
        let blackPoint = page.increaseBlackPoint
        image = await Self.decode(data, rotation: rotation, contrast: contrast, blackPoint: blackPoint)
    }

    @concurrent
    private nonisolated static func decode(_ data: Data, rotation: Int, contrast: Bool, blackPoint: Bool) async -> CGImage? {
        PlatformImage.processedCGImage(from: data, userRotation: rotation, increaseContrast: contrast, increaseBlackPoint: blackPoint)
    }

    private func capture() async {
        guard let image, !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        guard let crop = await CaptureService.crop(image, normalizedRect: session.rect) else {
            errorMessage = String(localized: "The selected area is too small to capture.")
            return
        }
        let isNew = session.existingCapture == nil
        let capture = CaptureService.store(crop, rect: session.rect, isDraft: session.isDraft, on: session.page, replacing: session.existingCapture)
        onCapture(capture, isNew)
    }
}

// MARK: - Crop canvas

/// The image, letterboxed to fit, with the crop rectangle on top. All geometry is converted between view points and normalized image coordinates here.
private struct CropCanvas: View {
    let image: CGImage
    @Binding var rect: CGRect

    @State private var dragStartRect: CGRect?

    private let minimumSize: CGFloat = 0.03
    private let handleSize: CGFloat = 22

    var body: some View {
        GeometryReader { geometry in
            let imageFrame = fittedFrame(in: geometry.size)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .offset(x: imageFrame.minX, y: imageFrame.minY)

                // Dim everything outside the selection.
                DimmingMask(selection: viewRect(in: imageFrame))
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                selectionOverlay(in: imageFrame)
            }
            .contentShape(Rectangle())
            // Drag anywhere outside the selection to draw a new rectangle, like a screenshot.
            .gesture(drawGesture(in: imageFrame))
        }
    }

    private func fittedFrame(in size: CGSize) -> CGRect {
        let imageAspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        var width = size.width
        var height = width / imageAspect
        if height > size.height {
            height = size.height
            width = height * imageAspect
        }
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    private func viewRect(in frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX + rect.minX * frame.width,
            y: frame.minY + rect.minY * frame.height,
            width: rect.width * frame.width,
            height: rect.height * frame.height
        )
    }

    private func normalized(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(
            x: min(max((point.x - frame.minX) / frame.width, 0), 1),
            y: min(max((point.y - frame.minY) / frame.height, 0), 1)
        )
    }

    // MARK: Selection + handles

    @ViewBuilder
    private func selectionOverlay(in frame: CGRect) -> some View {
        let selection = viewRect(in: frame)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .stroke(Color.white, lineWidth: 1.5)
                .background(Color.white.opacity(0.001)) // hit-testable interior
                .frame(width: selection.width, height: selection.height)
                .offset(x: selection.minX, y: selection.minY)
                .gesture(moveGesture(in: frame))
                .accessibilityLabel("Selection")
                .accessibilityHint("Drag to move")

            ForEach(Handle.allCases, id: \.self) { handle in
                let center = handle.position(in: selection)
                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                    .frame(width: handleSize * 0.6, height: handleSize * 0.6)
                    .frame(width: handleSize, height: handleSize)
                    .contentShape(Rectangle())
                    .position(center)
                    .gesture(resizeGesture(handle, in: frame))
                    .accessibilityLabel(handle.accessibilityLabel)
            }
        }
    }

    private func moveGesture(in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartRect == nil { dragStartRect = rect }
                guard let start = dragStartRect else { return }
                let dx = value.translation.width / frame.width
                let dy = value.translation.height / frame.height
                var moved = start
                moved.origin.x = min(max(start.minX + dx, 0), 1 - start.width)
                moved.origin.y = min(max(start.minY + dy, 0), 1 - start.height)
                rect = moved
            }
            .onEnded { _ in dragStartRect = nil }
    }

    private func resizeGesture(_ handle: Handle, in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartRect == nil { dragStartRect = rect }
                guard let start = dragStartRect else { return }
                let dx = value.translation.width / frame.width
                let dy = value.translation.height / frame.height
                rect = handle.resized(start, dx: dx, dy: dy, minimumSize: minimumSize)
            }
            .onEnded { _ in dragStartRect = nil }
    }

    private func drawGesture(in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let start = normalized(value.startLocation, in: frame)
                let current = normalized(value.location, in: frame)
                let origin = CGPoint(x: min(start.x, current.x), y: min(start.y, current.y))
                let size = CGSize(width: max(abs(current.x - start.x), minimumSize), height: max(abs(current.y - start.y), minimumSize))
                rect = CGRect(origin: origin, size: size).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            }
    }

    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        func position(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
            case .top: CGPoint(x: rect.midX, y: rect.minY)
            case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
            case .right: CGPoint(x: rect.maxX, y: rect.midY)
            case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
            case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
            case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
            case .left: CGPoint(x: rect.minX, y: rect.midY)
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .topLeft: String(localized: "Top left handle")
            case .top: String(localized: "Top handle")
            case .topRight: String(localized: "Top right handle")
            case .right: String(localized: "Right handle")
            case .bottomRight: String(localized: "Bottom right handle")
            case .bottom: String(localized: "Bottom handle")
            case .bottomLeft: String(localized: "Bottom left handle")
            case .left: String(localized: "Left handle")
            }
        }

        /// Applies a normalized drag to the edges this handle controls, keeping the rectangle inside 0…1 and at least `minimumSize`.
        func resized(_ start: CGRect, dx: CGFloat, dy: CGFloat, minimumSize: CGFloat) -> CGRect {
            var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
            switch self {
            case .topLeft: minX += dx; minY += dy
            case .top: minY += dy
            case .topRight: maxX += dx; minY += dy
            case .right: maxX += dx
            case .bottomRight: maxX += dx; maxY += dy
            case .bottom: maxY += dy
            case .bottomLeft: minX += dx; maxY += dy
            case .left: minX += dx
            }
            minX = min(max(minX, 0), 1); maxX = min(max(maxX, 0), 1)
            minY = min(max(minY, 0), 1); maxY = min(max(maxY, 0), 1)
            if maxX - minX < minimumSize {
                if [.topLeft, .left, .bottomLeft].contains(self) { minX = maxX - minimumSize } else { maxX = minX + minimumSize }
            }
            if maxY - minY < minimumSize {
                if [.topLeft, .top, .topRight].contains(self) { minY = maxY - minimumSize } else { maxY = minY + minimumSize }
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }
}

/// Everything except `selection`, for the even-odd dimming fill.
private nonisolated struct DimmingMask: Shape {
    let selection: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRect(selection)
        return path
    }
}
