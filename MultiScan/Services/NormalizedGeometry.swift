//
//  NormalizedGeometry.swift
//  MultiScan
//
//  Arithmetic on normalized (0…1, upper-left origin) rectangles — the one coordinate convention shared by `VisionDocumentLayout`, `PageCapture.normalizedRect`, and `Page.imageCrop`.
//
//  Two spaces come up for a page image, and they differ only by the user's rotation:
//  - **upright space**: the EXIF-upright image as stored. `Page.imageCrop` and the Vision layout written at import live here.
//  - **display space**: upright space turned clockwise by `Page.rotation`. Artwork captures and the capture overlay live here, because that is what the user sees.
//
//  Smart Separate after import works on what the user sees (a spread they rotated upright by hand must be recognized upright), so it finds its cut in display space and converts it to upright space for storage; captures on the page are carried into the new pages the same way. Pure and unit-tested (`PageSeparationTests`).
//

import Foundation
import CoreGraphics

nonisolated enum NormalizedGeometry {
    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Where `rect` ends up when its image is turned clockwise by `degrees` (a multiple of 90).
    static func rotated(_ rect: CGRect, clockwise degrees: Int) -> CGRect {
        switch ((degrees % 360) + 360) % 360 {
        case 90:
            // (x, y) → (1 − y, x): the top-left corner moves to the top-right.
            return CGRect(x: 1 - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        case 180:
            return CGRect(x: 1 - rect.maxX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
        case 270:
            // (x, y) → (y, 1 − x)
            return CGRect(x: rect.minY, y: 1 - rect.maxX, width: rect.height, height: rect.width)
        default:
            return rect
        }
    }

    /// The inverse of `rotated(_:clockwise:)`: display space back to upright space.
    static func unrotated(_ rect: CGRect, clockwise degrees: Int) -> CGRect {
        rotated(rect, clockwise: 360 - (((degrees % 360) + 360) % 360))
    }

    /// `rect` re-expressed in the 0…1 space of `container` (both given in the same outer space) — a capture's rectangle on a whole scan, as seen from the half it falls in.
    static func relative(_ rect: CGRect, to container: CGRect) -> CGRect {
        guard container.width > 0, container.height > 0 else { return rect }
        return CGRect(
            x: (rect.minX - container.minX) / container.width,
            y: (rect.minY - container.minY) / container.height,
            width: rect.width / container.width,
            height: rect.height / container.height
        )
    }

    /// The inverse of `relative(_:to:)`: a rectangle in `container`'s 0…1 space, expressed in the outer space.
    static func absolute(_ rect: CGRect, in container: CGRect) -> CGRect {
        CGRect(
            x: container.minX + rect.minX * container.width,
            y: container.minY + rect.minY * container.height,
            width: rect.width * container.width,
            height: rect.height * container.height
        )
    }

    /// `rect` clamped into the unit square (never empty: at least `minimumSize` on each side).
    static func clampedToUnit(_ rect: CGRect, minimumSize: CGFloat = 0.01) -> CGRect {
        let minX = min(max(rect.minX, 0), 1 - minimumSize)
        let minY = min(max(rect.minY, 0), 1 - minimumSize)
        let maxX = min(max(rect.maxX, minX + minimumSize), 1)
        let maxY = min(max(rect.maxY, minY + minimumSize), 1)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
