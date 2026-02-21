// Platform-native zoomable image view using UIScrollView (iOS) / NSScrollView (macOS)

import SwiftUI

/// Wraps a platform scroll view to display a zoomable image with native zoom behavior.
/// Zoom commands are received via NotificationCenter (.zoomIn, .zoomOut, .zoomActualSize).
struct ZoomableImageView: View {
    /// Pre-processed CGImage (rotated and adjusted, ready to display)
    let cgImage: CGImage
    /// Identity string for the current page — when this changes, zoom resets to fit-to-window
    let imageIdentity: String
    /// Reports current zoom scale back to parent (1.0 = fit-to-window)
    @Binding var currentScale: CGFloat
    /// Safe area insets from the SwiftUI layout (sidebar, inspector, toolbar).
    /// Applied as content insets so the image centers in the visible area
    /// while still rendering behind the glass panels.
    var safeAreaInsets: EdgeInsets = EdgeInsets()

    var body: some View {
        #if os(iOS)
        IOSZoomableImageView(
            cgImage: cgImage,
            imageIdentity: imageIdentity,
            currentScale: $currentScale,
            safeAreaInsets: safeAreaInsets
        )
        #else
        MacZoomableImageView(
            cgImage: cgImage,
            imageIdentity: imageIdentity,
            currentScale: $currentScale,
            safeAreaInsets: safeAreaInsets
        )
        #endif
    }
}

// MARK: - macOS Implementation

#if os(macOS)
import AppKit

struct MacZoomableImageView: NSViewRepresentable {
    let cgImage: CGImage
    let imageIdentity: String
    @Binding var currentScale: CGFloat
    var safeAreaInsets: EdgeInsets

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.maxMagnification = 10.0
        scrollView.minMagnification = 0.1
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false

        // Use centering clip view so content is centered when smaller than viewport
        let clipView = CenteringClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView

        let imageView = NSImageView()
        imageView.imageScaling = .scaleNone
        imageView.wantsLayer = true
        scrollView.documentView = imageView

        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView
        context.coordinator.registerObservers()

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parentBinding = $currentScale

        // Update content insets from SwiftUI safe area
        let newInsets = NSEdgeInsets(
            top: safeAreaInsets.top,
            left: safeAreaInsets.leading,
            bottom: safeAreaInsets.bottom,
            right: safeAreaInsets.trailing
        )
        let old = scrollView.contentInsets
        let insetsChanged = old.top != newInsets.top || old.left != newInsets.left
            || old.bottom != newInsets.bottom || old.right != newInsets.right
        if insetsChanged {
            scrollView.contentInsets = newInsets
        }

        let isNewPage = coordinator.lastImageIdentity != imageIdentity

        // Detect if the image content changed
        if coordinator.lastCGImage !== cgImage {
            coordinator.lastCGImage = cgImage
            coordinator.lastImageIdentity = imageIdentity

            let nsImage = NSImage(cgImage: cgImage, size: NSSize(
                width: cgImage.width,
                height: cgImage.height
            ))

            let imageView = coordinator.imageView!
            imageView.image = nsImage
            imageView.frame = NSRect(origin: .zero, size: nsImage.size)

            // Recalculate fit-to-window magnification using visible area
            let fitScale = coordinator.fitToWindowScale(for: nsImage.size)
            scrollView.minMagnification = fitScale

            if isNewPage {
                scrollView.magnification = fitScale
                coordinator.reportScale()
            }
        } else if insetsChanged {
            // Insets changed (inspector opened/closed) — recalculate fit scale
            guard let nsImage = coordinator.imageView?.image else { return }
            let fitScale = coordinator.fitToWindowScale(for: nsImage.size)
            let wasAtFit = abs(scrollView.magnification - scrollView.minMagnification) < 0.001
            scrollView.minMagnification = fitScale
            if wasAtFit {
                scrollView.magnification = fitScale
            }
            coordinator.reportScale()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    class Coordinator: NSObject {
        weak var scrollView: NSScrollView?
        weak var imageView: NSImageView?
        var lastCGImage: CGImage?
        var lastImageIdentity: String?
        var parentBinding: Binding<CGFloat>?

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        /// Calculate the magnification that fits the image in the visible area (frame minus insets)
        func fitToWindowScale(for imageSize: NSSize) -> CGFloat {
            guard let scrollView else { return 1.0 }
            let insets = scrollView.contentInsets
            let visibleWidth = scrollView.frame.width - insets.left - insets.right
            let visibleHeight = scrollView.frame.height - insets.top - insets.bottom
            guard visibleWidth > 0, visibleHeight > 0,
                  imageSize.width > 0, imageSize.height > 0 else { return 1.0 }
            return min(visibleWidth / imageSize.width, visibleHeight / imageSize.height)
        }

        func registerObservers() {
            guard let scrollView else { return }

            // Zoom command notifications
            NotificationCenter.default.addObserver(self, selector: #selector(handleZoomIn), name: .zoomIn, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(handleZoomOut), name: .zoomOut, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(handleZoomToFit), name: .zoomActualSize, object: nil)

            // Magnification change notifications
            NotificationCenter.default.addObserver(self, selector: #selector(handleMagnificationEnd), name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)

            // Frame change for window resize
            scrollView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(handleFrameChange), name: NSView.frameDidChangeNotification, object: scrollView)
        }

        @objc private func handleZoomIn() { zoomIn() }
        @objc private func handleZoomOut() { zoomOut() }
        @objc private func handleZoomToFit() { zoomToFit() }
        @objc private func handleMagnificationEnd() { reportScale() }

        @objc private func handleFrameChange() {
            guard let scrollView, let imageView,
                  let nsImage = imageView.image else { return }

            let wasAtFit = abs(scrollView.magnification - scrollView.minMagnification) < 0.001
            let fitScale = fitToWindowScale(for: nsImage.size)
            scrollView.minMagnification = fitScale

            if wasAtFit {
                scrollView.magnification = fitScale
            } else if scrollView.magnification < fitScale {
                scrollView.magnification = fitScale
            }
            reportScale()
        }

        func zoomIn() {
            guard let scrollView else { return }
            let newMag = min(scrollView.magnification * 1.25, scrollView.maxMagnification)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                scrollView.animator().magnification = newMag
            }
            reportScale()
        }

        func zoomOut() {
            guard let scrollView else { return }
            let newMag = max(scrollView.magnification * 0.8, scrollView.minMagnification)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                scrollView.animator().magnification = newMag
            }
            reportScale()
        }

        func zoomToFit() {
            guard let scrollView else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                scrollView.animator().magnification = scrollView.minMagnification
            }
            reportScale()
        }

        func reportScale() {
            guard let scrollView else { return }
            let minMag = scrollView.minMagnification
            guard minMag > 0 else { return }
            let relativeScale = scrollView.magnification / minMag
            parentBinding?.wrappedValue = relativeScale
        }
    }
}

/// Custom NSClipView that centers content when it is smaller than the scroll view.
/// Accounts for content insets so centering uses the visible area, not the full frame.
class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }

        let documentFrame = documentView.frame
        let insets = enclosingScrollView?.contentInsets ?? NSEdgeInsets()

        // Visible area is the clip view bounds minus content insets
        let visibleWidth = rect.width - insets.left - insets.right
        let visibleHeight = rect.height - insets.top - insets.bottom

        if documentFrame.width < visibleWidth {
            rect.origin.x = (documentFrame.width - visibleWidth) / 2.0 - insets.left
        }
        if documentFrame.height < visibleHeight {
            rect.origin.y = (documentFrame.height - visibleHeight) / 2.0 - insets.bottom
        }
        return rect
    }
}

#endif

// MARK: - iOS Implementation

#if os(iOS)
import UIKit

struct IOSZoomableImageView: UIViewRepresentable {
    let cgImage: CGImage
    let imageIdentity: String
    @Binding var currentScale: CGFloat
    var safeAreaInsets: EdgeInsets

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 0.1
        scrollView.maximumZoomScale = 10.0
        scrollView.showsVerticalScrollIndicator = true
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.bouncesZoom = true
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView()
        imageView.contentMode = .scaleToFill
        scrollView.addSubview(imageView)

        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView
        context.coordinator.registerObservers()

        // Double-tap to toggle zoom
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parentBinding = $currentScale

        // Update content insets from SwiftUI safe area
        let newInsets = UIEdgeInsets(
            top: safeAreaInsets.top,
            left: safeAreaInsets.leading,
            bottom: safeAreaInsets.bottom,
            right: safeAreaInsets.trailing
        )
        let insetsChanged = scrollView.contentInset != newInsets
        if insetsChanged {
            scrollView.contentInset = newInsets
        }

        let isNewPage = coordinator.lastImageIdentity != imageIdentity

        if coordinator.lastCGImage !== cgImage {
            coordinator.lastCGImage = cgImage
            coordinator.lastImageIdentity = imageIdentity

            let uiImage = UIImage(cgImage: cgImage)
            let imageView = coordinator.imageView!
            imageView.image = uiImage
            imageView.frame = CGRect(origin: .zero, size: uiImage.size)
            scrollView.contentSize = uiImage.size
            coordinator.imageSize = uiImage.size

            // Calculate fit-to-window minimum zoom using visible area
            let fitScale = coordinator.fitToWindowScale(for: uiImage.size)
            scrollView.minimumZoomScale = fitScale

            if isNewPage {
                scrollView.zoomScale = fitScale
                coordinator.centerContent(in: scrollView)
                coordinator.reportScale()
            }
        } else if insetsChanged {
            let fitScale = coordinator.fitToWindowScale(for: coordinator.imageSize)
            let wasAtFit = abs(scrollView.zoomScale - scrollView.minimumZoomScale) < 0.001
            scrollView.minimumZoomScale = fitScale
            if wasAtFit {
                scrollView.zoomScale = fitScale
                coordinator.centerContent(in: scrollView)
            }
            coordinator.reportScale()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?
        var lastCGImage: CGImage?
        var lastImageIdentity: String?
        var imageSize: CGSize = .zero
        var parentBinding: Binding<CGFloat>?

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        /// Calculate the zoom scale that fits the image in the visible area (bounds minus insets)
        func fitToWindowScale(for imageSize: CGSize) -> CGFloat {
            guard let scrollView else { return 1.0 }
            let insets = scrollView.contentInset
            let visibleWidth = scrollView.bounds.width - insets.left - insets.right
            let visibleHeight = scrollView.bounds.height - insets.top - insets.bottom
            guard visibleWidth > 0, visibleHeight > 0,
                  imageSize.width > 0, imageSize.height > 0 else { return 1.0 }
            return min(visibleWidth / imageSize.width, visibleHeight / imageSize.height)
        }

        // MARK: UIScrollViewDelegate

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerContent(in: scrollView)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            reportScale()
        }

        // MARK: Content Centering

        func centerContent(in scrollView: UIScrollView) {
            guard let imageView else { return }
            let insets = scrollView.contentInset
            let visibleWidth = scrollView.bounds.width - insets.left - insets.right
            let visibleHeight = scrollView.bounds.height - insets.top - insets.bottom

            let offsetX: CGFloat
            if scrollView.contentSize.width < visibleWidth {
                offsetX = (visibleWidth - scrollView.contentSize.width) / 2.0 + insets.left
            } else {
                offsetX = 0
            }

            let offsetY: CGFloat
            if scrollView.contentSize.height < visibleHeight {
                offsetY = (visibleHeight - scrollView.contentSize.height) / 2.0 + insets.top
            } else {
                offsetY = 0
            }

            imageView.center = CGPoint(
                x: scrollView.contentSize.width / 2.0 + offsetX,
                y: scrollView.contentSize.height / 2.0 + offsetY
            )
        }

        // MARK: Notifications

        func registerObservers() {
            NotificationCenter.default.addObserver(self, selector: #selector(handleZoomIn), name: .zoomIn, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(handleZoomOut), name: .zoomOut, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(handleZoomToFit), name: .zoomActualSize, object: nil)
        }

        @objc private func handleZoomIn() { zoomIn() }
        @objc private func handleZoomOut() { zoomOut() }
        @objc private func handleZoomToFit() { zoomToFit() }

        func zoomIn() {
            guard let scrollView else { return }
            let newScale = min(scrollView.zoomScale * 1.25, scrollView.maximumZoomScale)
            scrollView.setZoomScale(newScale, animated: true)
            reportScale()
        }

        func zoomOut() {
            guard let scrollView else { return }
            let newScale = max(scrollView.zoomScale * 0.8, scrollView.minimumZoomScale)
            scrollView.setZoomScale(newScale, animated: true)
            reportScale()
        }

        func zoomToFit() {
            guard let scrollView else { return }
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            reportScale()
        }

        // MARK: Double-Tap Zoom

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }

            if scrollView.zoomScale > scrollView.minimumZoomScale * 1.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let tapPoint = gesture.location(in: imageView)
                let targetScale = min(scrollView.minimumZoomScale * 2.5, scrollView.maximumZoomScale)
                let zoomRect = zoomRectForScale(targetScale, center: tapPoint, in: scrollView)
                scrollView.zoom(to: zoomRect, animated: true)
            }
            reportScale()
        }

        private func zoomRectForScale(_ scale: CGFloat, center: CGPoint, in scrollView: UIScrollView) -> CGRect {
            let size = CGSize(
                width: scrollView.bounds.width / scale,
                height: scrollView.bounds.height / scale
            )
            let origin = CGPoint(
                x: center.x - size.width / 2.0,
                y: center.y - size.height / 2.0
            )
            return CGRect(origin: origin, size: size)
        }

        // MARK: Scale Reporting

        func reportScale() {
            guard let scrollView else { return }
            let minScale = scrollView.minimumZoomScale
            guard minScale > 0 else { return }
            let relativeScale = scrollView.zoomScale / minScale
            parentBinding?.wrappedValue = relativeScale
        }
    }
}

#endif
