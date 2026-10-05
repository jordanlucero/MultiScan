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

// `nonisolated`: the project builds with default main-actor isolation, but model objects are also read on `ProjectStore`'s model actor (App Intents, Spotlight, search). SwiftData, not an actor, owns their thread-safety — a model must only be touched on the actor that owns its context.
@Model
nonisolated final class Page {
    // MARK: - CloudKit Compatibility
    // All properties must have default values for CloudKit sync. Relationships must be optional.

    var pageNumber: Int = 0
    var document: Document?
    var createdAt: Date = Date()
    var isDone: Bool = false
    var thumbnailData: Data?

    /// Legacy (1.x/2.0) encoded array of `CGRect` line boxes from `VNRecognizeTextRequest`.
    /// Kept for existing rows; new imports write the richer `visionLayoutData` instead and leave this nil.
    var boundingBoxesData: Data?
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

    /// Rich text content stored as RTF (text only) or RTFD (text + inline attachments) data for CloudKit compatibility.
    /// Pre-2.0 data is JSON-encoded AttributedString; `RichTextArchiver` sniffs the format on read and migrates lazily (every write produces RTF/RTFD).
    /// Use the `attributedText` computed property for convenient access.
    @Attribute(.externalStorage)
    var richTextData: Data?

    /// Stable, device-independent identity used by App Intents, Spotlight, and `SyncableEntity`.
    /// Optional on purpose: a non-optional `UUID()` default can stamp the *same* value onto every pre-existing row during lightweight migration. `ProjectMaintenance.backfill` assigns missing values.
    var uuid: UUID?

    /// Plain-text mirror of `richTextData`, kept in sync by the `attributedText` setter (and `init`).
    /// Stored as a real column so `#Predicate` full-text search runs in SQLite, Spotlight gets `textContent` without decoding RTF, and per-keystroke page filtering never touches external storage.
    ///
    /// Inline attachments (artwork captures, tables) are *not* mirrored here: their U+FFFC placeholder characters are stripped (`String.strippingAttachmentCharacters()`), so search and statistics see only real text.
    ///
    /// **Encrypted in CloudKit.** This is the only plaintext copy of a page's OCR output that mirrors as a readable CloudKit field — every other text/image blob is `.externalStorage`, which maps to a `CKAsset` and is encrypted by CloudKit automatically. Encryption is CloudKit-side only: locally it stays an ordinary SQLite column, so `#Predicate` search is unaffected. Do not add `#Index` here — CloudKit rejects indexes on encrypted fields.
    @Attribute(.allowsCloudEncryption)
    var plainText: String = ""

    /// When `plainText` was last derived from `richTextData`. `nil` or older than `lastModified` means the mirror is stale (e.g., written by a build without this column) and is re-derived on backfill.
    var plainTextUpdatedAt: Date?

    // MARK: - 2.1 additive fields (no SwiftData schema-version bump needed — see CLAUDE.md "Storage additions")

    /// Structured Vision result for this page's image: paragraphs, lines, tables, and their normalized regions, encoded as a `VisionDocumentLayout` (binary plist).
    ///
    /// **Always written by Vision, whatever OCR engine produced the page text.** When the user picks a local transformer model (Core AI / LM Studio), Vision still runs so Smart Separate, future layout features, and the `visionTranscript` fallback have the geometry they need. External storage: a dense page can carry several hundred lines.
    @Attribute(.externalStorage)
    var visionLayoutData: Data?

    /// Vision's plain transcript of this page's image (`DocumentObservation.Container.Text.transcript`), stored even when another engine wrote `richTextData`, so both results survive side by side. `nil` for legacy rows and for pages created before 2.1.
    var visionTranscript: String?

    /// Identifier of the OCR engine whose output became `richTextData` at import — see `OCREngineKind.provenanceIdentifier(…)` (e.g. `"vision"`, `"lmstudio:qwen2.5-vl-7b"`). `nil` for legacy rows (which were all Vision).
    var ocrEngine: String?

    /// Non-nil when this page begins a chapter / section / part. The value is the heading shown in the thumbnail sidebar, the page grid, the Digest, and exports.
    /// Set manually (page context menu ▸ Chapter) or by `ChapterDetector` from repeated-header analysis; the user's manual edits win (`sectionTitleIsAutomatic` records which).
    var sectionTitle: String?

    /// `true` when `sectionTitle` was assigned by `ChapterDetector`, so a later automatic pass may revise it; `false` once the user edited it by hand (automatic passes then leave it alone).
    var sectionTitleIsAutomatic: Bool = false

    /// Smart Separate provenance: `0` = the page is a whole scanned image; `1` / `2` = the first (left) / second (right) half of a two-page spread the import split automatically. Display only — lets the UI explain where a page came from.
    var splitPosition: Int = 0

    /// Artwork / illustration captures cropped from this page's image and placed inline in its text. Cascade: deleting the page deletes its captures.
    @Relationship(deleteRule: .cascade) var captures: [PageCapture]? = []

    #Index<Page>([\.uuid])

    /// Rich text accessor that encodes/decodes `richTextData` via RichTextArchiver.
    /// This is the single funnel for local text writes. Refreshes the plain-text mirror and timestamps.
    ///
    /// Encoding picks the format: RTF when the text has no attachments, RTFD (flattened package) when it does — see `RichTextArchiver.richTextData(from:)`.
    var attributedText: NSAttributedString {
        get {
            RichTextArchiver.attributedString(from: richTextData)
        }
        set {
            richTextData = RichTextArchiver.richTextData(from: newValue)
            plainText = InlineAttachments.searchablePlainText(of: newValue)
            let now = Date()
            lastModified = now
            plainTextUpdatedAt = now
            document?.lastModified = now
        }
    }

    /// Creates a page from OCR output.
    /// - Parameters:
    ///   - text: plain transcript, used for `plainText` and — when `richTextData` is nil — encoded as the page's rich text on the storage font.
    ///   - richTextData: pre-encoded RTF/RTFD when the engine produced formatting (markdown-based transcribers). `nil` encodes `text`.
    ///   - boundingBoxesData: legacy line boxes (new imports pass `nil` and supply `visionLayoutData`).
    init(
        pageNumber: Int,
        text: String,
        imageData: Data?,
        originalFileName: String? = nil,
        boundingBoxesData: Data? = nil,
        richTextData: Data? = nil,
        visionLayoutData: Data? = nil,
        visionTranscript: String? = nil,
        ocrEngine: String? = nil
    ) {
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
        self.plainText = text.strippingAttachmentCharacters()
        self.plainTextUpdatedAt = now
        self.visionLayoutData = visionLayoutData
        self.visionTranscript = visionTranscript
        self.ocrEngine = ocrEngine
        self.captures = []
        // Encode directly to avoid touching lastModified via the computed setter during init
        self.richTextData = richTextData ?? RichTextArchiver.rtfData(
            from: NSAttributedString(string: text, attributes: [.font: PageTextStyle.storageFont])
        )
    }

    /// Decode stored legacy bounding boxes (1.x/2.0 imports). New imports use `visionLayout`.
    var boundingBoxes: [CGRect] {
        guard let data = boundingBoxesData,
              let boxes = try? JSONDecoder().decode([CGRect].self, from: data) else {
            return []
        }
        return boxes
    }

    /// Decodes the structured Vision layout, if this page has one (2.1+ imports).
    var visionLayout: VisionDocumentLayout? {
        VisionDocumentLayout.decode(visionLayoutData)
    }

    /// Non-optional captures array for convenient read access.
    var unwrappedCaptures: [PageCapture] {
        captures ?? []
    }

    /// The localized "Page N" label used by thumbnails, the page grid, rotors, and accessibility labels.
    var title: String {
        String(localized: "Page \(pageNumber)", comment: "Thumbnail label with page number")
    }

    /// The number printed on the physical page, per the project's numbering settings (`PageNumbering`), e.g. "iv" for front matter or "17" once counting starts. `nil` when the project hasn't configured printed numbering.
    var printedPageLabel: String? {
        guard let document else { return nil }
        return PageNumbering.printedLabel(forProjectPage: pageNumber, in: document)
    }
}

@Model
nonisolated final class Document {
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

    // MARK: - 2.1 additive fields

    /// Printed page numbering: the *project* page number on which the physical book's Arabic numbering begins (e.g. 9 when the first eight scans are a foreword numbered i–viii). `nil` = not configured; the UI then shows project page numbers only.
    var printedNumberingStartPage: Int?

    /// The printed number shown on `printedNumberingStartPage` (usually 1, but a scan of chapters 3–5 might start at 41).
    var printedNumberingStartValue: Int = 1

    /// How pages *before* `printedNumberingStartPage` are labelled — `FrontMatterNumberingStyle` raw value (`roman` → i, ii, iii…; `none` → no printed label).
    var frontMatterNumberingStyle: String = FrontMatterNumberingStyle.roman.rawValue

    /// `true` when `name` was proposed by the on-device model (`ProjectTitleSuggester`) and the user hasn't renamed it since. Renaming by hand clears it, so an automatic pass never overwrites a user's title.
    var isAutoTitled: Bool = false

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

    /// Pages sorted by page number — the order every list, export, and the Digest show.
    var sortedPages: [Page] {
        unwrappedPages.sorted { $0.pageNumber < $1.pageNumber }
    }

    /// Typed view of `frontMatterNumberingStyle`.
    var frontMatterStyle: FrontMatterNumberingStyle {
        get { FrontMatterNumberingStyle(rawValue: frontMatterNumberingStyle) ?? .roman }
        set { frontMatterNumberingStyle = newValue.rawValue }
    }

    /// Every artwork capture in the project that is still flagged as a draft, in page order — the export panel lists these as "revisit this page" reminders.
    var draftCaptures: [PageCapture] {
        sortedPages.flatMap { page in
            page.unwrappedCaptures.filter(\.isDraft).sorted { $0.createdAt < $1.createdAt }
        }
    }

    /// Pages that begin a chapter/section, in page order.
    var chapterStartPages: [Page] {
        sortedPages.filter { $0.sectionTitle != nil }
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
            if let visionLayoutData = page.visionLayoutData {
                totalBytes += Int64(visionLayoutData.count)
            }
            for capture in page.unwrappedCaptures {
                totalBytes += Int64(capture.imageData?.count ?? 0) + Int64(capture.thumbnailData?.count ?? 0)
            }
        }
        if let textExportCache = textExportCache {
            totalBytes += Int64(textExportCache.count)
        }
        cachedStorageBytes = totalBytes
    }
}

// MARK: - Attachment placeholder stripping

nonisolated extension String {
    /// Removes the U+FFFC object-replacement characters that stand in for inline attachments (artwork captures, tables) in `NSAttributedString.string`, so plain-text mirrors, statistics, search, and Smart Cleanup only ever see real text.
    func strippingAttachmentCharacters() -> String {
        guard contains("\u{FFFC}") else { return self }
        return replacingOccurrences(of: "\u{FFFC}", with: "")
    }
}
