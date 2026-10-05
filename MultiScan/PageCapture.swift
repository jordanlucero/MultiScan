//
//  PageCapture.swift
//  MultiScan
//
//  An artwork / illustration capture: a rectangular crop of a page's image that the user placed inline in that page's text.
//
//  ## Why a separate model (and not image bytes inside the RTFD)
//  The capture's pixels live here, as their own CloudKit record (`CKAsset` via external storage). The page's rich text only carries a tiny *reference* attachment (`CaptureAttachment`, a custom-UTType file in the RTFD package whose contents are this record's `uuid`). That keeps:
//  - `Page.richTextData` and every `TextExportCache` entry small (the cache mirrors page text for all pages in one blob — embedding megabytes of crops there would make export and Smart Cleanup pay for every capture on every load);
//  - the draft flag and the source rectangle queryable without decoding any RTFD (export reminders list `Document.draftCaptures` straight from the models);
//  - CloudKit happy: one asset per capture instead of re-uploading the whole page text whenever an image is added.
//  Exports materialize the real image in place of the reference (`TextExporter`).
//
//  ## CloudKit rules
//  Every property has a default and the relationship is optional, like `Page`/`Document`. The rect is stored as four scalars rather than a `CGRect` blob so it stays a plain, mergeable field set.
//

import Foundation
import CoreGraphics
import SwiftData

@Model
nonisolated final class PageCapture {
    // MARK: - CloudKit Compatibility
    // All properties must have default values; relationships must be optional.

    /// Stable identity, also written into the reference attachment inside the page's RTFD. Optional for the same lightweight-migration reason as `Page.uuid`.
    var uuid: UUID?

    var createdAt: Date = Date()
    var lastModified: Date = Date()

    /// Owning page. Optional (CloudKit); cascade-deleted with the page.
    var page: Page?

    /// The cropped pixels (HEIC), already rotated/adjusted the way the viewer showed them when captured — what the editor renders and exports embed.
    @Attribute(.externalStorage)
    var imageData: Data?

    /// Small HEIC preview (≤ 400 px) for the editor attachment view and the Digest, so showing a page never decodes a multi-megapixel crop.
    var thumbnailData: Data?

    /// Source rectangle in the page image's *normalized, upper-left-origin, display-oriented* coordinates (0…1, after `rotation` is applied). Four scalars for CloudKit mergeability; see `normalizedRect`.
    var rectX: Double = 0
    var rectY: Double = 0
    var rectWidth: Double = 1
    var rectHeight: Double = 1

    /// Pixel size of the stored crop, so attachment bounds can be computed without decoding the image.
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0

    /// Draft: the user wants to revisit the physical page for a higher-quality scan of this artwork. The export panel surfaces every draft as a reminder; the editor badges it.
    var isDraft: Bool = false

    /// Optional caption / alt text, shown under the image in exports and read by VoiceOver.
    var caption: String?

    init(
        page: Page?,
        imageData: Data?,
        thumbnailData: Data?,
        normalizedRect: CGRect,
        pixelSize: CGSize,
        isDraft: Bool = false
    ) {
        let now = Date()
        self.uuid = UUID()
        self.createdAt = now
        self.lastModified = now
        self.page = page
        self.imageData = imageData
        self.thumbnailData = thumbnailData
        self.rectX = normalizedRect.origin.x
        self.rectY = normalizedRect.origin.y
        self.rectWidth = normalizedRect.width
        self.rectHeight = normalizedRect.height
        self.pixelWidth = Int(pixelSize.width)
        self.pixelHeight = Int(pixelSize.height)
        self.isDraft = isDraft
        self.caption = nil
    }

    /// The source rectangle as a `CGRect` in normalized (0…1), upper-left-origin coordinates of the displayed page image.
    var normalizedRect: CGRect {
        get { CGRect(x: rectX, y: rectY, width: rectWidth, height: rectHeight) }
        set {
            rectX = newValue.origin.x
            rectY = newValue.origin.y
            rectWidth = newValue.width
            rectHeight = newValue.height
        }
    }

    /// Pixel size of the stored crop (0×0 when unknown).
    var pixelSize: CGSize {
        CGSize(width: pixelWidth, height: pixelHeight)
    }

    /// Aspect ratio (width ÷ height) for layout before the image is decoded; 1 when unknown.
    var aspectRatio: CGFloat {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1 }
        return CGFloat(pixelWidth) / CGFloat(pixelHeight)
    }

    /// Localized description for reminders and accessibility: "Illustration on page 12 (printed p. 7)".
    var reminderDescription: String {
        guard let page else {
            return String(localized: "Illustration", comment: "Fallback label for a capture whose page is unavailable")
        }
        if let printed = page.printedPageLabel {
            return String(localized: "Illustration on page \(page.pageNumber) (printed p. \(printed))", comment: "Draft capture reminder with project and printed page numbers")
        }
        return String(localized: "Illustration on page \(page.pageNumber)", comment: "Draft capture reminder with the project page number")
    }
}
