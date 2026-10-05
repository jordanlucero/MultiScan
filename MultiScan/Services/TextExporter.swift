//
//  TextExporter.swift
//  MultiScan
//
//  Builds the combined NSAttributedString for export with configurable separators, chapter headings, embedded artwork captures, and draft reminders.
//
//  ## Performance Architecture
//  `snapshots(for:options:)` gathers Sendable per-page inputs in one of two ways:
//
//  1. **Cache-based (preferred)**: the pre-computed `TextExportCache` (RTF/RTFD + statistics for every page) — a single external-storage read, used whenever it is still fresh against the pages.
//  2. **Direct page access (fallback)**: each page's raw `richTextData` — N external-storage reads. Only used when the cache is unavailable or stale.
//
//  Chapter titles and printed labels are stored columns (cheap in both modes). Capture pixels are external storage and are read only when `options.includeCaptures` is on — one read per capture, which is rare relative to pages.
//
//  In both modes the expensive work — decoding page RTF/RTFD, swapping reference attachments for real images, and appending into the combined string — happens off the main actor in `buildResult`. `NSMutableAttributedString.append` is O(n) per page.
//
//  `export(_:options:)` is nonisolated and runs on its caller: the export panel calls it on the main actor, `ProjectStore` on its model actor, so neither hands a `@Model` object across actors.
//
//  ## Attachments in the output
//  - Capture references → a real image attachment (JPEG bytes, bounds scaled to ≤ 400 pt wide) when `includeCaptures`; otherwise an `[Illustration]` note. Drafts additionally get an inline `[Draft — rescan page N]` marker and a list at the end when `includeDraftReminders`.
//  - Table references → tab-separated text on both platforms (RTF tables via `NSTextTable` exist only in AppKit; flattening keeps the output identical across Mac and iPhone). Follow-up: macOS-only `NSTextTable` export.
//

import SwiftUI
import SwiftData
import ImageIO
import UniformTypeIdentifiers

/// The finished export: attributed text for preview plus pre-encoded share payloads.
///
/// `NSAttributedString` is not Sendable, but the instance here is built fresh inside the export task and never mutated afterward — immutable NSAttributedStrings are safe to read from any thread once ownership is transferred.
nonisolated struct TextExportResult: @unchecked Sendable {
    let attributedText: NSAttributedString
    let rtfData: Data?
    /// Flattened RTFD with embedded capture images; nil when the output has no images.
    let rtfdData: Data?
    let plainText: String
    /// Human-readable reminders for draft captures ("Illustration on page 12 (printed p. 7)"), for the export panel's notice.
    let draftReminders: [String]
    /// Project name, for the share payload's suggested filename.
    let documentName: String

    static let empty = TextExportResult(attributedText: NSAttributedString(), rtfData: nil, rtfdData: nil, plainText: "", draftReminders: [], documentName: "")

    /// Sendable share wrapper for ShareLink / Copy / Save As.
    var richText: RichText {
        RichText(rtfData: rtfData, rtfdData: rtfdData, plainText: plainText, suggestedName: documentName.isEmpty ? String(localized: "Exported Text", comment: "Default export file name") : documentName)
    }
}

nonisolated enum TextExporter {

    /// A capture's export inputs.
    struct CaptureSnapshot: Sendable {
        let id: UUID
        /// Encoded image bytes (HEIC as stored); nil when `includeCaptures` is off or the asset hasn't synced.
        let imageData: Data?
        let isDraft: Bool
        let caption: String?
        let reminder: String
    }

    /// Sendable snapshot of one page's export inputs, gathered on the actor that owns the page.
    struct PageSnapshot: Sendable {
        let pageNumber: Int
        let fileName: String?
        /// Raw persisted bytes — RTF/RTFD (current) or legacy JSON; decoded off-main.
        let textData: Data?
        /// Pre-computed statistics when coming from the cache; computed after decode otherwise.
        let wordCount: Int?
        let charCount: Int?
        /// Chapter title when this page begins one.
        var sectionTitle: String? = nil
        /// Printed page label ("iv", "17") when the project has printed numbering configured.
        var printedLabel: String? = nil
        var captures: [CaptureSnapshot] = []
    }

    // MARK: - Export

    /// Builds the combined export result for a project. Runs on the caller's actor up to the snapshot, then decodes and combines on the cooperative pool.
    static func export(_ document: Document, options: ExportOptions) async -> TextExportResult {
        let snapshots = snapshots(for: document, options: options)
        guard !snapshots.isEmpty else { return .empty }
        return await buildResult(from: snapshots, options: options, documentName: document.name)
    }

    /// Per-page inputs, from the export cache when it is fresh (one read) and from the pages otherwise (N reads). Chapter/printed-number/capture metadata always comes from the models (stored columns; capture images read only when requested).
    static func snapshots(for document: Document, options: ExportOptions = .simple(separatePages: false)) -> [PageSnapshot] {
        let pages = document.sortedPages
        let pagesByNumber = Dictionary(pages.map { ($0.pageNumber, $0) }, uniquingKeysWith: { first, _ in first })

        func decorate(_ snapshot: PageSnapshot) -> PageSnapshot {
            var result = snapshot
            guard let page = pagesByNumber[snapshot.pageNumber] else { return result }
            result.sectionTitle = page.sectionTitle
            result.printedLabel = page.printedPageLabel
            result.captures = page.unwrappedCaptures.compactMap { capture in
                guard let id = capture.uuid else { return nil }
                return CaptureSnapshot(
                    id: id,
                    imageData: options.includeCaptures ? capture.imageData : nil,
                    isDraft: capture.isDraft,
                    caption: capture.caption,
                    reminder: capture.reminderDescription
                )
            }
            return result
        }

        if let data = document.textExportCache,
           let cache = TextExportCacheService.decodeCache(from: data),
           TextExportCacheService.isFresh(cache, against: TextExportCacheService.fingerprints(of: document)) {
            return cache.pages
                .sorted { $0.pageNumber < $1.pageNumber }
                .map {
                    decorate(PageSnapshot(
                        pageNumber: $0.pageNumber,
                        fileName: $0.fileName,
                        textData: $0.rtfData,
                        wordCount: $0.wordCount,
                        charCount: $0.charCount
                    ))
                }
        }
        // Fallback path: raw Data only — decode happens off-main.
        return pages.map {
            decorate(PageSnapshot(
                pageNumber: $0.pageNumber,
                fileName: $0.originalFileName,
                textData: $0.richTextData,
                wordCount: nil,
                charCount: nil
            ))
        }
    }

    // MARK: - Combining (off the main actor)

    @concurrent
    static func buildResult(from snapshots: [PageSnapshot], options: ExportOptions, documentName: String = "") async -> TextExportResult {
        let combined = NSMutableAttributedString()
        let baseFont = PageTextStyle.storageFont
        let separatorAttributes: [NSAttributedString.Key: Any] = [.font: baseFont]
        let totalPages = snapshots.count
        var draftReminders: [String] = []
        var hasImages = false

        for (index, snapshot) in snapshots.enumerated() {
            if index > 0 && index % 50 == 0 && Task.isCancelled {
                return .empty
            }

            let decoded = RichTextArchiver.attributedString(from: snapshot.textData)
            let pageText = resolveAttachments(in: decoded, captures: snapshot.captures, options: options, baseFont: baseFont, hasImages: &hasImages)

            if index > 0 || options.createVisualSeparation {
                let separator = separatorString(
                    pageNumber: snapshot.pageNumber,
                    fileName: snapshot.fileName,
                    wordCount: snapshot.wordCount ?? TextStatistics.wordCount(of: pageText.string),
                    charCount: snapshot.charCount ?? TextStatistics.characterCount(of: pageText.string),
                    totalPages: totalPages,
                    isFirstPage: index == 0,
                    options: options
                )
                if !separator.isEmpty {
                    combined.append(NSAttributedString(string: separator, attributes: separatorAttributes))
                }
            }

            // Chapter heading on its own paragraph before the page's text.
            if options.includeChapterHeadings, let title = snapshot.sectionTitle, !title.isEmpty {
                if combined.length > 0, !combined.string.hasSuffix("\n") {
                    combined.append(NSAttributedString(string: options.createVisualSeparation ? "\n" : "\n\n", attributes: separatorAttributes))
                }
                combined.append(NSAttributedString(string: title + "\n", attributes: [.font: PageTextStyle.headingFont(level: 2, base: baseFont)]))
            }

            combined.append(pageText)

            if options.includeDraftReminders {
                draftReminders.append(contentsOf: snapshot.captures.filter(\.isDraft).map(\.reminder))
            }
        }

        // The "revisit these pages" list.
        if options.includeDraftReminders, !draftReminders.isEmpty {
            combined.append(NSAttributedString(string: "\n\n", attributes: separatorAttributes))
            combined.append(NSAttributedString(
                string: String(localized: "Illustrations to rescan", comment: "Heading of the draft-capture reminder list at the end of an export") + "\n",
                attributes: [.font: PageTextStyle.headingFont(level: 3, base: baseFont)]
            ))
            for reminder in draftReminders {
                combined.append(NSAttributedString(string: "• " + reminder + "\n", attributes: separatorAttributes))
            }
        }

        let attributedText = NSAttributedString(attributedString: combined)
        return TextExportResult(
            attributedText: attributedText,
            rtfData: RichTextArchiver.rtfData(from: attributedText),
            rtfdData: hasImages ? RichTextArchiver.rtfdData(from: attributedText) : nil,
            plainText: InlineAttachments.searchablePlainText(of: attributedText),
            draftReminders: draftReminders,
            documentName: documentName
        )
    }

    /// Swaps MultiScan's reference attachments for export-friendly content: real images (or notes) for captures, tab-separated text for tables.
    static func resolveAttachments(
        in text: NSAttributedString,
        captures: [CaptureSnapshot],
        options: ExportOptions,
        baseFont: PlatformFont,
        hasImages: inout Bool
    ) -> NSAttributedString {
        guard RichTextArchiver.containsAttachments(text) else { return text }
        let capturesByID = Dictionary(captures.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let result = NSMutableAttributedString(attributedString: text)
        var replacements: [(NSRange, NSAttributedString)] = []
        let noteAttributes: [NSAttributedString.Key: Any] = [.font: baseFont.applyingTraits(bold: false, italic: true)]

        InlineAttachments.enumerateAttachments(in: result) { attachment, range in
            switch InlineAttachments.kind(of: attachment) {
            case .capture(let id):
                let capture = capturesByID[id]
                let piece = NSMutableAttributedString()
                if options.includeCaptures, let data = capture?.imageData, let image = imageAttachment(from: data) {
                    piece.append(InlineAttachments.attributedString(for: image, font: baseFont))
                    hasImages = true
                } else {
                    piece.append(NSAttributedString(string: String(localized: "[Illustration]", comment: "Placeholder written into exported text where an artwork capture sits"), attributes: noteAttributes))
                }
                if let caption = capture?.caption, !caption.isEmpty {
                    piece.append(NSAttributedString(string: "\n" + caption, attributes: noteAttributes))
                }
                if options.includeDraftReminders, capture?.isDraft == true {
                    piece.append(NSAttributedString(string: " " + String(localized: "[Draft — rescan this illustration]", comment: "Inline marker next to a draft capture in exported text"), attributes: noteAttributes))
                }
                replacements.append((range, piece))
            case .table(let table):
                replacements.append((range, NSAttributedString(string: "\n" + table.tabSeparatedText + "\n", attributes: [.font: baseFont])))
            case .image:
                hasImages = true // keep as-is
            case .unknown:
                replacements.append((range, NSAttributedString(string: "", attributes: [.font: baseFont])))
            }
        }
        for (range, replacement) in replacements.reversed() {
            result.replaceCharacters(in: range, with: replacement)
        }
        return result
    }

    /// A real image attachment for export, re-encoded as JPEG (RTFD readers universally handle JPEG; HEIC support varies) and sized to ≤ 400 pt wide.
    static func imageAttachment(from data: Data, maxWidth: CGFloat = 400) -> NSTextAttachment? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = PlatformImage.thumbnail(from: source, maxPixelSize: 1600),
              let jpeg = PlatformImage.encode(cgImage, as: .jpeg, quality: 0.85) else { return nil }
        let attachment = NSTextAttachment(data: jpeg, ofType: UTType.jpeg.identifier)
        let wrapper = FileWrapper(regularFileWithContents: jpeg)
        wrapper.preferredFilename = "illustration-\(UUID().uuidString.prefix(8)).jpg"
        attachment.fileWrapper = wrapper
        let aspect = CGFloat(cgImage.height) / CGFloat(max(cgImage.width, 1))
        let width = min(maxWidth, CGFloat(cgImage.width))
        attachment.bounds = CGRect(x: 0, y: 0, width: width, height: width * aspect)
        return attachment
    }

    /// Builds the separator text between pages (empty string = no separator).
    static func separatorString(
        pageNumber: Int,
        fileName: String?,
        wordCount: Int,
        charCount: Int,
        totalPages: Int,
        isFirstPage: Bool,
        options: ExportOptions
    ) -> String {
        guard options.createVisualSeparation else {
            return " "
        }

        var components: [String] = []

        if options.includePageNumber {
            components.append(String(localized: "Page \(pageNumber) of \(totalPages)", comment: "Page number indicator in export separator"))
        }

        if options.includeFilename, let filename = fileName {
            components.append(filename)
        }

        if options.includeStatistics {
            components.append(String(localized: "\(wordCount) words, \(charCount) characters", comment: "Word and character count in export separator"))
        }

        if isFirstPage && options.separatorStyle == .lineBreak && components.isEmpty {
            return ""
        }

        var separator = isFirstPage ? "" : "\n\n"

        switch options.separatorStyle {
        case .lineBreak:
            if !components.isEmpty {
                separator += "[\(components.joined(separator: " | "))]"
            }

        case .hyphenatedDivider:
            separator += String(repeating: "-", count: 40)
            if !components.isEmpty {
                separator += "\n"
                separator += components.joined(separator: " | ")
            }
        }

        separator += "\n"
        return separator
    }
}
