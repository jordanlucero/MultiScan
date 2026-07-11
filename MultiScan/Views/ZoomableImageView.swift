// Platform-native zoomable image view using NSScrollView (macOS) / UIScrollView (iOS).
//
// All fit-to-window logic lives inside the platform view's layout pass, so the image
// tracks sidebar/inspector/window resizes synchronously, frame by frame. Zoom commands
// flow through ImageZoomController (menu bar reaches it via FocusedValues) — no
// NotificationCenter, no cross-window leakage.

import SwiftUI
import SwiftData

// MARK: - Display Model

/// A decoded, display-ready page image (rotation + adjustments baked in).
struct ProcessedPageImage {
    let cgImage: CGImage
    let contentID: ContentID

    /// Identity for zoom-reset decisions: changes on page switch or rotation
    /// (zoom resets to fit), stays constant for contrast/black point tweaks
    /// (image swaps in place, zoom and scroll position preserved).
    struct ContentID: Hashable {
        var pageID: PersistentIdentifier?
        var rotation: Int
    }
}

// MARK: - Zoom Controller

/// The platform scroll view registers itself here so commands can reach it.
@MainActor
protocol ImageZoomTarget: AnyObject {
    func zoomIn()
    func zoomOut()
    func zoomToFit()
}

/// Command/state bridge between SwiftUI (buttons, menu commands, accessibility)
/// and the platform scroll view. One per ImageViewer; exposed to the menu bar
/// via `FocusedValues.imageZoomController`.
@MainActor
@Observable
final class ImageZoomController {
    /// Current zoom relative to fit-to-window (1.0 = fit). Display-only.
    private(set) var zoomLevel: CGFloat = 1.0

    @ObservationIgnored weak var target: ImageZoomTarget?

    func zoomIn() { target?.zoomIn() }
    func zoomOut() { target?.zoomOut() }
    func zoomToFit() { target?.zoomToFit() }

    func reportZoomLevel(_ level: CGFloat) {
        if abs(level - zoomLevel) > 0.0001 {
            zoomLevel = level
        }
    }
}

// MARK: - SwiftUI Wrapper

struct ZoomableImageView: View {
    let image: ProcessedPageImage
    let controller: ImageZoomController
    /// Whether HDR content displays with its full headroom (true) or is
    /// tone-mapped to SDR by the system (false). No effect on SDR images.
    var displaysHDR: Bool = true
    /// Safe area insets from the SwiftUI layout (toolbar, sidebar, inspector).
    /// Applied as content insets so the image centers in the visible area while
    /// still rendering behind the glass panels.
    var safeAreaInsets: EdgeInsets = EdgeInsets()

    @Environment(\.layoutDirection) private var layoutDirection

    private var leftInset: CGFloat {
        layoutDirection == .rightToLeft ? safeAreaInsets.trailing : safeAreaInsets.leading
    }

    private var rightInset: CGFloat {
        layoutDirection == .rightToLeft ? safeAreaInsets.leading : safeAreaInsets.trailing
    }

    var body: some View {
        #if os(iOS)
        IOSZoomableImageView(
            image: image,
            controller: controller,
            displaysHDR: displaysHDR,
            insets: UIEdgeInsets(
                top: safeAreaInsets.top,
                left: leftInset,
                bottom: safeAreaInsets.bottom,
                right: rightInset
            )
        )
        #else
        MacZoomableImageView(
            image: image,
            controller: controller,
            displaysHDR: displaysHDR,
            insets: NSEdgeInsets(
                top: safeAreaInsets.top,
                left: leftInset,
                bottom: safeAreaInsets.bottom,
                right: rightInset
            )
        )
        #endif
    }
}

// MARK: - macOS Implementation

#if os(macOS)
import AppKit

private struct MacZoomableImageView: NSViewRepresentable {
    let image: ProcessedPageImage
    let controller: ImageZoomController
    let displaysHDR: Bool
    let insets: NSEdgeInsets

    func makeNSView(context: Context) -> MacZoomableScrollView {
        let view = MacZoomableScrollView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: MacZoomableScrollView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: MacZoomableScrollView) {
        view.zoomController = controller
        controller.target = view
        view.displaysHDR = displaysHDR
        view.baseInsets = insets
        view.setImage(image.cgImage, contentID: image.contentID)
    }
}

/// NSScrollView subclass owning all zoom/fit behavior. Fit maintenance runs
/// synchronously in `setFrameSize`/`layout`, so the image tracks animated
/// sidebar/inspector resizes without notification races.
final class MacZoomableScrollView: NSScrollView, ImageZoomTarget {
    weak var zoomController: ImageZoomController?

    private let imageView = NSImageView()
    private var lastCGImage: CGImage?
    private var currentContentID: ProcessedPageImage.ContentID?

    /// Fit state: a reset is pending until the next valid layout pass.
    private var pendingFitReset = false
    private var lastFitScale: CGFloat = 0
    private var lastLayoutViewport: CGSize = .zero

    /// System-managed HDR display: `.high` shows HDR content with full headroom,
    /// `.standard` has the system tone-map it down to SDR. No effect on SDR images.
    var displaysHDR = false {
        didSet {
            guard displaysHDR != oldValue else { return }
            imageView.preferredImageDynamicRange = displaysHDR ? .high : .standard
        }
    }

    var baseInsets = NSEdgeInsets() {
        didSet {
            guard oldValue.top != baseInsets.top || oldValue.left != baseInsets.left
                || oldValue.bottom != baseInsets.bottom || oldValue.right != baseInsets.right else { return }
            contentInsets = baseInsets
            needsLayout = true
        }
    }

    init() {
        super.init(frame: .zero)

        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        backgroundColor = .clear
        drawsBackground = false
        automaticallyAdjustsContentInsets = false

        // Native zoom + bouncy pan
        allowsMagnification = true
        minMagnification = 0.05
        maxMagnification = 10.0
        verticalScrollElasticity = .allowed
        horizontalScrollElasticity = .allowed
        usesPredominantAxisScrolling = false

        let clipView = CenteringClipView()
        clipView.drawsBackground = false
        contentView = clipView

        imageView.imageScaling = .scaleNone
        imageView.wantsLayer = true
        imageView.preferredImageDynamicRange = .standard // matches displaysHDR's initial value
        documentView = imageView

        // Live zoom-level reporting: magnification changes always resize the clip bounds.
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        imageView.addGestureRecognizer(doubleClick)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Content

    func setImage(_ cgImage: CGImage, contentID: ProcessedPageImage.ContentID) {
        guard cgImage !== lastCGImage || contentID != currentContentID else { return }

        let sameContent = (contentID == currentContentID)
        lastCGImage = cgImage
        currentContentID = contentID

        let size = NSSize(width: cgImage.width, height: cgImage.height)
        let nsImage = NSImage(cgImage: cgImage, size: size)

        if sameContent {
            // Adjustment tweak (contrast/black point): swap pixels, keep zoom and scroll.
            imageView.image = nsImage
            return
        }

        imageView.image = nsImage
        imageView.setFrameSize(size)
        pendingFitReset = true
        needsLayout = true
        fitToViewportIfNeeded() // fit immediately if we already have a viewport — no flash
    }

    // MARK: Fit Maintenance

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitToViewportIfNeeded()
    }

    override func layout() {
        super.layout()
        fitToViewportIfNeeded()
    }

    private var viewportSize: CGSize {
        CGSize(
            width: bounds.width - baseInsets.left - baseInsets.right,
            height: bounds.height - baseInsets.top - baseInsets.bottom
        )
    }

    /// Maintains the fit invariant whenever the viewport or content changes:
    /// at fit → stay at fit (tracks animated resizes); zoomed in → preserve the
    /// absolute zoom and re-clamp. Never touches magnification mid-gesture,
    /// because gestures don't change the viewport.
    private func fitToViewportIfNeeded() {
        guard let image = imageView.image,
              image.size.width > 0, image.size.height > 0 else { return }
        let viewport = viewportSize
        guard viewport.width > 1, viewport.height > 1 else { return }
        guard pendingFitReset || viewport != lastLayoutViewport else { return }

        let fit = min(viewport.width / image.size.width, viewport.height / image.size.height)
        let wasAtFit = lastFitScale == 0 || magnification <= lastFitScale + 0.001

        minMagnification = fit
        maxMagnification = max(fit * 10, 1.0)

        if pendingFitReset || wasAtFit || magnification < fit {
            magnification = fit
        } else if magnification > maxMagnification {
            magnification = maxMagnification
        }

        pendingFitReset = false
        lastFitScale = fit
        lastLayoutViewport = viewport
        reportZoomState()
    }

    // MARK: Zoom Commands

    func zoomIn() {
        animateMagnification(to: magnification * 1.25, centeredAt: visibleCenterInContentView())
    }

    func zoomOut() {
        animateMagnification(to: magnification * 0.8, centeredAt: visibleCenterInContentView())
    }

    func zoomToFit() {
        animateMagnification(to: minMagnification, centeredAt: visibleCenterInContentView())
    }

    private func animateMagnification(to target: CGFloat, centeredAt point: NSPoint) {
        let clamped = min(max(target, minMagnification), maxMagnification)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            self.setMagnification(clamped, centeredAt: point)
        }
    }

    /// Center of the visible area (bounds minus insets) in clip view coordinates.
    private func visibleCenterInContentView() -> NSPoint {
        let m = max(magnification, 0.0001)
        let b = contentView.bounds
        let left = baseInsets.left / m
        let right = baseInsets.right / m
        let top = baseInsets.top / m
        let bottom = baseInsets.bottom / m
        return NSPoint(
            x: b.minX + left + (b.width - left - right) / 2,
            y: b.minY + bottom + (b.height - top - bottom) / 2
        )
    }

    // MARK: Gestures

    /// ⌘ + scroll wheel zooms at the cursor (pinch is handled natively by NSScrollView,
    /// including rubber-banding past the limits).
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        var delta = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            delta *= 10
        }
        guard delta != 0 else { return }

        let factor = exp2(delta / 200)
        let target = min(max(magnification * factor, minMagnification), maxMagnification)
        let point = contentView.convert(event.locationInWindow, from: nil)
        setMagnification(target, centeredAt: point)
    }

    /// Double-click toggles between fit and 2.5× fit at the click point.
    @objc private func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
        let fit = minMagnification
        if magnification > fit * 1.01 {
            animateMagnification(to: fit, centeredAt: visibleCenterInContentView())
        } else {
            let point = gesture.location(in: contentView)
            animateMagnification(to: fit * 2.5, centeredAt: point)
        }
    }

    // MARK: Zoom Reporting

    @objc private func clipBoundsDidChange() {
        reportZoomState()
    }

    private func reportZoomState() {
        guard lastFitScale > 0 else { return }
        zoomController?.reportZoomLevel(magnification / lastFitScale)
    }
}

/// NSClipView that centers the document when it is smaller than the visible area.
/// Clip bounds are in document space while content insets are in window points,
/// so insets are converted through the current magnification.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView, rect.width > 0, rect.height > 0 else { return rect }

        let insets = enclosingScrollView?.contentInsets ?? NSEdgeInsets()
        let magnification = frame.width > 0 ? frame.width / rect.width : 1
        guard magnification > 0 else { return rect }

        let left = insets.left / magnification
        let right = insets.right / magnification
        let top = insets.top / magnification
        let bottom = insets.bottom / magnification

        let visibleWidth = rect.width - left - right
        let visibleHeight = rect.height - top - bottom
        let docFrame = documentView.frame

        if docFrame.width < visibleWidth {
            rect.origin.x = docFrame.minX - left - (visibleWidth - docFrame.width) / 2
        }
        if docFrame.height < visibleHeight {
            // Non-flipped coordinates: bottom inset sits at minY.
            rect.origin.y = docFrame.minY - bottom - (visibleHeight - docFrame.height) / 2
        }
        return rect
    }
}

#endif

// MARK: - iOS Implementation

#if os(iOS)
import UIKit

private struct IOSZoomableImageView: UIViewRepresentable {
    let image: ProcessedPageImage
    let controller: ImageZoomController
    let displaysHDR: Bool
    let insets: UIEdgeInsets

    func makeUIView(context: Context) -> IOSZoomableScrollView {
        let view = IOSZoomableScrollView()
        apply(to: view)
        return view
    }

    func updateUIView(_ view: IOSZoomableScrollView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: IOSZoomableScrollView) {
        view.zoomController = controller
        controller.target = view
        view.displaysHDR = displaysHDR
        view.baseInsets = insets
        view.setImage(image.cgImage, contentID: image.contentID)
    }
}

/// UIScrollView subclass owning all zoom/fit behavior. Fit maintenance runs in
/// `layoutSubviews`, so rotation, split-view resizes, and inspector changes
/// re-fit synchronously. Centering is done through contentInset, which plays
/// correctly with bouncesZoom and rubber-band panning.
final class IOSZoomableScrollView: UIScrollView, UIScrollViewDelegate, ImageZoomTarget {
    weak var zoomController: ImageZoomController?

    private let imageView = UIImageView()
    private var lastCGImage: CGImage?
    private var currentContentID: ProcessedPageImage.ContentID?

    private var pendingFitReset = false
    private var lastFitScale: CGFloat = 0
    private var lastLayoutViewport: CGSize = .zero
    private var lastLayoutInsets: UIEdgeInsets = .zero

    /// System-managed HDR display: `.high` shows HDR content with full headroom,
    /// `.standard` has the system tone-map it down to SDR. No effect on SDR images.
    var displaysHDR = false {
        didSet {
            guard displaysHDR != oldValue else { return }
            imageView.preferredImageDynamicRange = displaysHDR ? .high : .standard
        }
    }

    var baseInsets: UIEdgeInsets = .zero {
        didSet {
            if baseInsets != oldValue {
                setNeedsLayout()
            }
        }
    }

    init() {
        super.init(frame: .zero)

        delegate = self
        backgroundColor = .clear
        contentInsetAdjustmentBehavior = .never
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false

        // Bouncy zoom and pan
        bouncesZoom = true
        alwaysBounceVertical = true
        alwaysBounceHorizontal = true

        minimumZoomScale = 1
        maximumZoomScale = 1

        imageView.contentMode = .scaleToFill
        imageView.preferredImageDynamicRange = .standard // matches displaysHDR's initial value
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Content

    func setImage(_ cgImage: CGImage, contentID: ProcessedPageImage.ContentID) {
        guard cgImage !== lastCGImage || contentID != currentContentID else { return }

        let sameContent = (contentID == currentContentID)
        lastCGImage = cgImage
        currentContentID = contentID

        let uiImage = UIImage(cgImage: cgImage)

        if sameContent {
            // Adjustment tweak (contrast/black point): swap pixels, keep zoom and scroll.
            imageView.image = uiImage
            return
        }

        // Reset the zoom transform before resizing the image view so frame math stays sane.
        minimumZoomScale = 1
        maximumZoomScale = 1
        zoomScale = 1
        imageView.image = uiImage
        imageView.frame = CGRect(origin: .zero, size: uiImage.size)
        contentSize = uiImage.size

        pendingFitReset = true
        setNeedsLayout()
        fitToViewportIfNeeded() // fit immediately if we already have a viewport — no flash
        centerContent()
    }

    // MARK: Fit Maintenance

    override func layoutSubviews() {
        super.layoutSubviews()
        fitToViewportIfNeeded()
        centerContent()
    }

    /// Same invariant as macOS: at fit → stay at fit through resizes; zoomed in →
    /// preserve the absolute zoom and re-clamp to the new limits.
    private func fitToViewportIfNeeded() {
        guard let image = imageView.image,
              image.size.width > 0, image.size.height > 0 else { return }
        let viewport = bounds.inset(by: baseInsets).size
        guard viewport.width > 1, viewport.height > 1 else { return }
        guard pendingFitReset || viewport != lastLayoutViewport || baseInsets != lastLayoutInsets else { return }

        let fit = min(viewport.width / image.size.width, viewport.height / image.size.height)
        let wasAtFit = lastFitScale == 0 || zoomScale <= lastFitScale + 0.001

        minimumZoomScale = fit
        maximumZoomScale = max(fit * 10, 1.0)

        if pendingFitReset || wasAtFit || zoomScale < fit {
            zoomScale = fit
            centerContent()
            contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
        } else if zoomScale > maximumZoomScale {
            zoomScale = maximumZoomScale
        }

        pendingFitReset = false
        lastFitScale = fit
        lastLayoutViewport = viewport
        lastLayoutInsets = baseInsets
        reportZoomState()
    }

    /// Centers content smaller than the visible area by padding contentInset.
    private func centerContent() {
        let visible = bounds.inset(by: baseInsets)
        let extraX = max(0, (visible.width - contentSize.width) / 2)
        let extraY = max(0, (visible.height - contentSize.height) / 2)
        let newInset = UIEdgeInsets(
            top: baseInsets.top + extraY,
            left: baseInsets.left + extraX,
            bottom: baseInsets.bottom + extraY,
            right: baseInsets.right + extraX
        )
        if contentInset != newInset {
            contentInset = newInset
        }
    }

    // MARK: Zoom Commands

    func zoomIn() {
        setZoomScale(min(zoomScale * 1.25, maximumZoomScale), animated: true)
    }

    func zoomOut() {
        setZoomScale(max(zoomScale * 0.8, minimumZoomScale), animated: true)
    }

    func zoomToFit() {
        setZoomScale(minimumZoomScale, animated: true)
    }

    // MARK: Gestures

    /// Double-tap toggles between fit and 2.5× fit at the tap point.
    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        let fit = minimumZoomScale
        if zoomScale > fit * 1.01 {
            setZoomScale(fit, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let targetScale = min(fit * 2.5, maximumZoomScale)
            let size = CGSize(width: bounds.width / targetScale, height: bounds.height / targetScale)
            let rect = CGRect(
                x: point.x - size.width / 2,
                y: point.y - size.height / 2,
                width: size.width,
                height: size.height
            )
            zoom(to: rect, animated: true)
        }
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        reportZoomState()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        reportZoomState()
    }

    // MARK: Zoom Reporting

    private func reportZoomState() {
        guard lastFitScale > 0 else { return }
        zoomController?.reportZoomLevel(zoomScale / lastFitScale)
    }
}

#endif
