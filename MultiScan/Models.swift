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

    // MARK: - 2.0 additive fields (no SwiftData schema-version bump needed — see CLAUDE.md "Storage additions")

    /// Structured Vision result for this page's image: paragraphs, lines, tables, and their normalized regions, encoded as a `VisionDocumentLayout` (binary plist).
    ///
    /// **Always written by Vision, whatever OCR engine produced the page text.** When the user picks a local transformer model (Core AI / LM Studio), Vision still runs so Smart Separate, future layout features, and the `visionTranscript` fallback have the geometry they need. External storage: a dense page can carry several hundred lines.
    @Attribute(.externalStorage)
    var visionLayoutData: Data?

    /// Vision's plain transcript of this page's image (`DocumentObservation.Container.Text.transcript`), stored even when another engine wrote `richTextData`, so both results survive side by side. `nil` for legacy rows and for pages created before 2.0.
    var visionTranscript: String?

    /// Identifier of the OCR engine whose output became `richTextData` at import — see `OCREngineKind.provenanceIdentifier(…)` (e.g. `"vision"`, `"server:qwen2.5-vl-7b"`). `nil` for legacy rows (which were all Vision).
    var ocrEngine: String?

    /// Non-nil when this page begins a chapter / section / part. The value is the heading shown in the thumbnail sidebar, the page grid, the Digest, and exports.
    /// Set by hand (page context menu ▸ Mark Chapter Start…). Reordering treats chapters as containers, so the mark can move to another page — see `ChapterSections`.
    var sectionTitle: String?

    /// `true` when `sectionTitle` was assigned by automatic chapter detection rather than by the user. Detection is on hold (see `ChapterDetector.swift`), so nothing sets or reads this today; it stays in the schema for marks earlier builds made and for the feature's return.
    var sectionTitleIsAutomatic: Bool = false

    /// Smart Separate: `0` = the page shows a whole scanned image; `1` / `2` = the first (left) / second (right) page of a two-page scan that was separated — at import or later (`PageSeparationService`).
    var splitPosition: Int = 0

    /// The scan this page shows a region of, when Smart Separate split it off a two-page scan. `nil` for an ordinary page, whose image is its own `imageData`. See `SharedScan.swift`.
    var sharedScan: SharedScan?

    /// The region of the image this page shows: normalized (0…1), upper-left origin, in the EXIF-upright image *before* the user's `rotation`. The default (0, 0, 1, 1) is the whole image. Four scalars rather than a blob so the fields stay plain and mergeable in CloudKit (same reasoning as `PageCapture`'s rectangle). Use `imageCrop`.
    var cropX: Double = 0
    var cropY: Double = 0
    var cropWidth: Double = 1
    var cropHeight: Double = 1

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

    /// Decodes the structured Vision layout, if this page has one (2.0+ imports).
    var visionLayout: VisionDocumentLayout? {
        VisionDocumentLayout.decode(visionLayoutData)
    }

    /// Non-optional captures array for convenient read access.
    var unwrappedCaptures: [PageCapture] {
        captures ?? []
    }

    // MARK: - Image source (whole scan or a region of a shared one)

    /// The region of the image this page shows, or `nil` for the whole image. See `cropX`.
    var imageCrop: CGRect? {
        get {
            guard cropX != 0 || cropY != 0 || cropWidth != 1 || cropHeight != 1 else { return nil }
            return CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
        }
        set {
            let rect = newValue ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            cropX = rect.origin.x
            cropY = rect.origin.y
            cropWidth = rect.width
            cropHeight = rect.height
        }
    }

    /// Whether Smart Separate split this page off a two-page scan.
    var isSeparated: Bool {
        sharedScan != nil
    }

    /// The image bytes this page draws from — its own, or the scan it shares with its facing page. **Every reader of a page's image goes through this (or `imageSource`), never `imageData` directly**, or separated pages show nothing.
    var sourceImageData: Data? {
        imageData ?? sharedScan?.imageData
    }

    /// Bytes + crop, ready to hand to `PlatformImage.processedCGImage(from:)` off the main actor.
    var imageSource: PageImageSource? {
        guard let data = sourceImageData else { return nil }
        return PageImageSource(data: data, crop: imageCrop)
    }

    /// The other page(s) cut from the same scan.
    var facingPages: [Page] {
        (sharedScan?.unwrappedPages ?? []).filter { $0 !== self }
    }

    /// `true` once the page's text has been changed since import or the page was marked reviewed — what "this will replace the page's text" confirmations key on. Imports stamp `createdAt` and `lastModified` together; every later text write moves `lastModified`.
    var hasBeenEditedOrReviewed: Bool {
        isDone || lastModified.timeIntervalSince(createdAt) > 2
    }

    /// The localized "Page N" label used by thumbnails, the page grid, rotors, and accessibility labels.
    var title: String {
        String(localized: "Page \(pageNumber)", comment: "Thumbnail label with page number")
    }

    /// The number printed on the physical page, per the project's numbering settings (`PageNumbering`), e.g. "iv" for front matter or "17" once counting starts. `nil` when the project hasn't configured printed numbering.
    ///
    /// Resolves the whole plan on every call (it has to find where each range's anchor page currently sits). Fine for one page; anything drawing many pages — the sidebar, the page grid, export — asks `Document.printedPageLabels()` once instead.
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

    // MARK: - 2.0 additive fields

    /// Printed page numbering plan (`PrintedNumberingPlan`, JSON): ranges with a numbering style and start value — typically Roman front matter from the first page and Arabic numbering from the first body page, optionally more (an appendix restarting at 1). Each range is anchored to the **page it starts on** (`Page.uuid`), not to a position, so labels follow their pages through inserts, deletes, reorders, and Smart Separate. `nil` = not configured; the UI then shows project page numbers only. One small blob rather than scattered scalars so a CloudKit merge can never mix two devices' half-plans.
    ///
    /// Earlier schema-3 development builds wrote position-based ranges into this same field (plan version 1); `printedNumbering` converts those on read and `ProjectMaintenance` rewrites them at launch. See `PageNumbering.swift`.
    var printedNumberingData: Data?

    /// `true` when `name` was proposed by the on-device model (`ProjectTitleSuggester`) and the user hasn't renamed it since. Renaming by hand clears it, so an automatic pass never overwrites a user's title.
    var isAutoTitled: Bool = false

    /// Original scans shared by pages that Smart Separate split apart (`SharedScan.swift`). Cascade: deleting the project deletes them.
    @Relationship(deleteRule: .cascade, inverse: \SharedScan.document)
    var sharedScans: [SharedScan]? = []

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

    /// Typed view of `printedNumberingData`. Setting `nil` turns printed numbering off.
    /// Reads accept the position-based plan earlier development builds wrote and anchor it to the pages currently at those positions; writes always produce the current form.
    var printedNumbering: PrintedNumberingPlan? {
        get { PrintedNumberingPlan.decode(printedNumberingData, pages: sortedPages) }
        set { printedNumberingData = newValue?.encoded() }
    }

    /// Printed label for every numbered page, keyed by project page number — one resolution of the plan for callers that draw many pages. Empty when printed numbering is off.
    func printedPageLabels() -> [Int: String] {
        let pages = sortedPages
        guard let plan = PrintedNumberingPlan.decode(printedNumberingData, pages: pages) else { return [:] }
        return plan.resolved(against: pages).labels(pageCount: pages.count)
    }

    /// Non-optional shared scans for convenient read access.
    var unwrappedSharedScans: [SharedScan] {
        sharedScans ?? []
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
        // A separated scan is stored once, however many pages show it.
        for scan in unwrappedSharedScans {
            totalBytes += Int64(scan.imageData?.count ?? 0)
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
