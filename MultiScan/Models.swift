//
//  Models.swift
//  MultiScan
//
//  Created by Jordan Lucero on 5/23/25.
//

import Foundation
import SwiftData
import CoreGraphics
import SwiftUI

@Model
final class Page {
    // MARK: - CloudKit Compatibility
    // All properties must have default values for CloudKit sync. Relationships must be optional.

    var pageNumber: Int = 0
    var document: Document?
    var createdAt: Date = Date()
    var isDone: Bool = false
    var thumbnailData: Data?
    var boundingBoxesData: Data? // Encoded array of CGRect from VisionKit
    var lastModified: Date = Date()

    /// User rotation in degrees (0, 90, 180, 270) - non-destructive, applied at display time
    var rotation: Int = 0

    /// Toggle for increased contrast display adjustment
    var increaseContrast: Bool = false

    /// Toggle for increased black point display adjustment
    var increaseBlackPoint: Bool = false

    /// Original filename for display purposes
    var originalFileName: String?

    /// Full image data stored externally for efficiency
    @Attribute(.externalStorage)
    var imageData: Data?

    /// Rich text content stored as RTF data for CloudKit compatibility.
    /// Pre-2.0 data is JSON-encoded AttributedString; `RichTextArchiver` sniffs the format on read and migrates lazily (every write produces RTF).
    /// Use the `attributedText` computed property for convenient access.
    @Attribute(.externalStorage)
    var richTextData: Data?

    /// Stable, device-independent identity used by App Intents, Spotlight, and `SyncableEntity`.
    /// Optional on purpose: a non-optional `UUID()` default can stamp the *same* value onto every pre-existing row during lightweight migration. `ProjectMaintenance.backfill` assigns missing values.
    var uuid: UUID?

    /// Plain-text mirror of `richTextData`, kept in sync by the `attributedText` setter (and `init`).
    /// Stored as a real column so `#Predicate` full-text search runs in SQLite, Spotlight gets `textContent` without decoding RTF, and per-keystroke page filtering never touches external storage.
    ///
    /// **Encrypted in CloudKit.** This is the only plaintext copy of a page's OCR output that mirrors as a readable CloudKit field — every other text/image blob is `.externalStorage`, which maps to a `CKAsset` and is encrypted by CloudKit automatically. Encryption is CloudKit-side only: locally it stays an ordinary SQLite column, so `#Predicate` search is unaffected. Do not add `#Index` here — CloudKit rejects indexes on encrypted fields.
    @Attribute(.allowsCloudEncryption)
    var plainText: String = ""

    /// When `plainText` was last derived from `richTextData`. `nil` or older than `lastModified` means the mirror is stale (e.g., written by a build without this column) and is re-derived on backfill.
    var plainTextUpdatedAt: Date?

    #Index<Page>([\.uuid])

    /// Rich text accessor that encodes/decodes `richTextData` via RichTextArchiver.
    /// This is the single funnel for local text writes. Refreshes the plain-text mirror and timestamps.
    var attributedText: NSAttributedString {
        get {
            RichTextArchiver.attributedString(from: richTextData)
        }
        set {
            richTextData = RichTextArchiver.rtfData(from: newValue)
            plainText = newValue.string
            let now = Date()
            lastModified = now
            plainTextUpdatedAt = now
            document?.lastModified = now
        }
    }

    init(pageNumber: Int, text: String, imageData: Data?, originalFileName: String? = nil, boundingBoxesData: Data? = nil) {
        self.pageNumber = pageNumber
        self.imageData = imageData
        self.originalFileName = originalFileName
        self.createdAt = Date()
        self.isDone = false
        self.thumbnailData = nil
        self.boundingBoxesData = boundingBoxesData
        let now = Date()
        self.lastModified = now
        self.uuid = UUID()
        self.plainText = text
        self.plainTextUpdatedAt = now
        // Encode directly to avoid touching lastModified via the computed setter during init
        self.richTextData = RichTextArchiver.rtfData(
            from: NSAttributedString(string: text, attributes: [.font: PageTextStyle.storageFont])
        )
    }

    /// Decode stored bounding boxes
    var boundingBoxes: [CGRect] {
        guard let data = boundingBoxesData,
              let boxes = try? JSONDecoder().decode([CGRect].self, from: data) else {
            return []
        }
        return boxes
    }
}

@Model
final class Document {
    // MARK: - CloudKit Compatibility
    // All properties must have default values for CloudKit sync. Relationships must be optional.

    var name: String = ""
    var totalPages: Int = 0
    var createdAt: Date = Date()
    @Relationship(deleteRule: .cascade) var pages: [Page]? = []

    /// Optional project emoji for visual customization
    var emoji: String?

    /// Cached storage size in bytes (external storage size isn't easily queryable)
    var cachedStorageBytes: Int64 = 0

    /// Pre-computed cache of all page text data for efficient export.
    /// Stored as JSON-encoded `TextExportCache` to avoid loading individual page external storage files.
    /// See `TextExportCacheService` for cache management.
    @Attribute(.externalStorage)
    var textExportCache: Data?

    /// Stable, device-independent identity (see `Page.uuid` for why this is optional).
    var uuid: UUID?

    /// Last local edit to the project itself or any of its pages (rename, emoji, page text).
    /// Optional so legacy rows fall back to the derived page dates in `lastModifiedDate`.
    var lastModified: Date?

    #Index<Document>([\.uuid])

    init(name: String, totalPages: Int = 0) {
        self.name = name
        self.totalPages = totalPages
        self.createdAt = Date()
        self.pages = []
        self.emoji = nil
        self.cachedStorageBytes = 0
        self.uuid = UUID()
        self.lastModified = nil
    }

    // MARK: - Convenience Accessors

    /// Non-optional pages array for convenient access. Returns empty array if nil.
    var unwrappedPages: [Page] {
        pages ?? []
    }

    // MARK: - Computed Properties

    /// Returns the most recently modified page (for thumbnail preview)
    var lastModifiedPage: Page? {
        unwrappedPages.max(by: { $0.lastModified < $1.lastModified })
    }

    /// Returns the date of the most recent modification (project metadata or any page)
    var lastModifiedDate: Date {
        [lastModifiedPage?.lastModified, lastModified, createdAt].compactMap { $0 }.max() ?? createdAt
    }

    /// Completion percentage as integer (0-100)
    var completionPercentage: Int {
        guard totalPages > 0 else { return 0 }
        return Int(Double(unwrappedPages.filter { $0.isDone }.count) / Double(totalPages) * 100)
    }

    /// Formatted storage size string (e.g., "45.2 MB")
    var formattedStorageSize: String {
        ByteCountFormatter.string(fromByteCount: cachedStorageBytes, countStyle: .file)
    }

    /// Recalculates and updates the cached storage size
    func recalculateStorageSize() {
        var totalBytes: Int64 = 0
        for page in unwrappedPages {
            if let imageData = page.imageData {
                totalBytes += Int64(imageData.count)
            }
            if let thumbnailData = page.thumbnailData {
                totalBytes += Int64(thumbnailData.count)
            }
            if let richTextData = page.richTextData {
                totalBytes += Int64(richTextData.count)
            }
            if let boundingBoxesData = page.boundingBoxesData {
                totalBytes += Int64(boundingBoxesData.count)
            }
        }
        if let textExportCache = textExportCache {
            totalBytes += Int64(textExportCache.count)
        }
        cachedStorageBytes = totalBytes
    }
}

// MARK: - Accessibility Extensions

extension Page {
    /// Label for VoiceOver rotor navigation
    var rotorLabel: String {
        "Page \(pageNumber)"
    }
}

