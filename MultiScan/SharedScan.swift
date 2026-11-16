//
//  SharedScan.swift
//  MultiScan
//
//  The original scanned image behind pages that Smart Separate split apart.
//
//  ## Why a separate model
//  A scan of an open book shows two physical pages. Smart Separate turns it into two `Page`s — each with its own text, review status, thumbnail, and Vision layout — that both show a *region* of the same image. The image bytes therefore can't live on either page (`Page.imageData`): they live here once, and each page records which part of the scan it shows (`Page.imageCrop`). Nothing is cropped or re-encoded on disk, so:
//  - separating is non-destructive — "Rejoin Separated Pages" puts the scan back on one page with no quality loss;
//  - it can run at import or any time afterwards (`PageSeparationService`);
//  - a spread costs the same storage whether or not it is separated.
//
//  A page that was never separated keeps its image in `Page.imageData` and has no `SharedScan`. `Page.imageSource` hides the difference from every reader (viewer, capture overlay, exports).
//
//  ## Lifetime
//  - Deleting the project cascades here (`Document.sharedScans`).
//  - Deleting a page that was the scan's last reader deletes the scan (`NavigationState.deletePage`).
//  - Scans are **never** swept up at launch for having no pages: CloudKit delivers `SharedScan` and `Page` as separate records in no guaranteed order, so a scan that looks unreferenced may simply be ahead of its pages. An unreferenced scan only wastes storage; deleting a referenced one loses the user's image on every device.
//
//  ## CloudKit rules
//  Every property has a default and both relationships are optional, like the other models. Additive to schema 3 (which never shipped), so there is no version bump; the development CloudKit schema needs `-initializeCloudKitSchema` once for the new `CD_SharedScan` record type.
//

import Foundation
import SwiftData

@Model
nonisolated final class SharedScan {
    /// Stable identity (optional for the same lightweight-migration reason as `Page.uuid`).
    var uuid: UUID?

    var createdAt: Date = Date()

    /// The scan as imported (or as "Optimize images" re-encoded it). EXIF orientation is part of the data; pages' crops are expressed against the EXIF-upright image.
    @Attribute(.externalStorage)
    var imageData: Data?

    /// File name of the imported scan, before the "(1 of 2)" suffix the pages show.
    var originalFileName: String?

    /// Owning project. Optional (CloudKit); the project cascades to its scans.
    var document: Document?

    /// The pages showing a region of this scan (normally two).
    @Relationship(deleteRule: .nullify, inverse: \Page.sharedScan)
    var pages: [Page]? = []

    init(imageData: Data?, originalFileName: String?, document: Document?) {
        self.uuid = UUID()
        self.createdAt = Date()
        self.imageData = imageData
        self.originalFileName = originalFileName
        self.document = document
        self.pages = []
    }

    var unwrappedPages: [Page] {
        pages ?? []
    }
}

/// What a reader needs to show a page's image: the bytes, and the part of them this page shows.
///
/// `Sendable` so the viewer, the capture overlay, and `ProjectStore` can hand it to `@concurrent` decoding (`PlatformImage.processedCGImage(from:)`). Deliberately not `Equatable` — comparing would walk megabytes of image data.
nonisolated struct PageImageSource: Sendable {
    let data: Data
    /// Normalized (0…1), upper-left origin, in the EXIF-upright image and *before* the page's user rotation. `nil` shows the whole image.
    let crop: CGRect?
}
