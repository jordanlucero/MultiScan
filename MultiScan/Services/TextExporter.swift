//
//  TextExporter.swift
//  MultiScan
//
//  Builds the combined NSAttributedString for export with configurable separators.
//
//  ## Performance Architecture
//  This exporter supports two modes:
//
//  1. **Cache-based (preferred)**: Uses `TextExportCacheService` to load pre-computed
//     page data (RTF + statistics) from a single cached file.
//
//  2. **Direct page access (fallback)**: Reads each page's raw text data from SwiftData
//     external storage. This triggers N disk reads. Only used when the cache is
//     unavailable or invalid.
//
//  In both modes the expensive work — decoding page RTF and appending into the combined
//  string — happens off the main actor. `NSMutableAttributedString.append` is O(n) per
//  page (unlike the old SwiftUI `AttributedString.append`, which was O(n²) overall).
//
//  ## Usage
//  ```swift
//  let exporter = TextExporter(document: document, settings: settings)
//  let result = await exporter.buildCombinedTextAsync()
//  // result.attributedText → preview, result.rtfData/plainText → RichText for sharing
//  ```
//

import SwiftUI
import SwiftData

/// The finished export: attributed text for preview plus pre-encoded share payloads.
///
/// `NSAttributedString` is not Sendable, but the instance here is built fresh inside
/// the export task and never mutated afterward — immutable NSAttributedStrings are
/// safe to read from any thread once ownership is transferred.
struct TextExportResult: @unchecked Sendable {
    let attributedText: NSAttributedString
    let rtfData: Data?
    let plainText: String

    static let empty = TextExportResult(attributedText: NSAttributedString(), rtfData: nil, plainText: "")

    /// Sendable share wrapper for ShareLink.
    var richText: RichText {
        RichText(rtfData: rtfData, plainText: plainText)
    }
}

struct TextExporter {
    /// Document to export from (enables cache-based export)
    private let document: Document?

    /// Direct page access (fallback when document/cache unavailable)
    private let pages: [Page]

    let settings: ExportSettings

    // MARK: - Initializers

    /// Initialize with a Document to enable cache-based export (preferred).
    ///
    /// This mode loads page data from a single cached file instead of N external
    /// storage files, dramatically improving performance for large documents.
    init(document: Document, settings: ExportSettings) {
        self.document = document
        self.pages = document.unwrappedPages
        self.settings = settings
    }

    /// Initialize with pages directly (legacy, triggers N external storage loads).
    ///
    /// **Warning**: For large documents, this can freeze the UI while loading.
    /// Prefer using `init(document:settings:)` when possible.
    init(pages: [Page], settings: ExportSettings) {
        self.document = nil
        self.pages = pages
        self.settings = settings
    }

    // MARK: - Page Snapshot

    /// Sendable snapshot of one page's export inputs, gathered on the main actor.
    private struct PageSnapshot: Sendable {
        let pageNumber: Int
        let fileName: String?
        /// Raw persisted bytes — RTF (current) or legacy JSON; decoded off-main.
        let textData: Data?
        /// Pre-computed statistics when coming from the cache; computed after decode otherwise.
        let wordCount: Int?
        let charCount: Int?
    }

    // MARK: - Async Export

    /// Builds the combined export result from all pages.
    ///
    /// Uses the cache when available (fast single-file load), falls back to direct
    /// page access if the cache is unavailable (slow N-file load).
    @MainActor
    func buildCombinedTextAsync() async -> TextExportResult {
        let snapshots: [PageSnapshot]

        if let document = document,
           let cache = TextExportCacheService.loadCache(from: document),
           cache.pages.count == document.unwrappedPages.count {
            // Cache path: one external-storage read for the whole document
            snapshots = cache.pages
                .sorted { $0.pageNumber < $1.pageNumber }
                .map {
                    PageSnapshot(
                        pageNumber: $0.pageNumber,
                        fileName: $0.fileName,
                        textData: $0.rtfData,
                        wordCount: $0.wordCount,
                        charCount: $0.charCount
                    )
                }
        } else {
            // Fallback path: N external-storage reads (raw Data only — decode happens off-main)
            snapshots = pages
                .sorted { $0.pageNumber < $1.pageNumber }
                .map {
                    PageSnapshot(
                        pageNumber: $0.pageNumber,
                        fileName: $0.originalFileName,
                        textData: $0.richTextData,
                        wordCount: nil,
                        charCount: nil
                    )
                }
        }

        guard !snapshots.isEmpty else { return .empty }

        // Capture settings on the main actor for background use
        let createVisualSeparation = settings.createVisualSeparation
        let separatorStyle = settings.separatorStyle
        let includePageNumber = settings.includePageNumber
        let includeFilename = settings.includeFilename
        let includeStatistics = settings.includeStatistics

        // Decode, combine, and encode on a background thread
        return await Task.detached(priority: .userInitiated) {
            Self.buildResult(
                from: snapshots,
                createVisualSeparation: createVisualSeparation,
                separatorStyle: separatorStyle,
                includePageNumber: includePageNumber,
                includeFilename: includeFilename,
                includeStatistics: includeStatistics
            )
        }.value
    }

    // MARK: - Combining (background thread)

    private static func buildResult(
        from snapshots: [PageSnapshot],
        createVisualSeparation: Bool,
        separatorStyle: SeparatorStyle,
        includePageNumber: Bool,
        includeFilename: Bool,
        includeStatistics: Bool
    ) -> TextExportResult {
        let combined = NSMutableAttributedString()
        let separatorAttributes: [NSAttributedString.Key: Any] = [.font: PageTextStyle.storageFont]
        let totalPages = snapshots.count

        for (index, snapshot) in snapshots.enumerated() {
            if index > 0 && index % 50 == 0 && Task.isCancelled {
                return .empty
            }

            let pageText = RichTextArchiver.attributedString(from: snapshot.textData)

            // Add separator
            if index > 0 || createVisualSeparation {
                let separator = separatorString(
                    pageNumber: snapshot.pageNumber,
                    fileName: snapshot.fileName,
                    wordCount: snapshot.wordCount ?? TextStatistics.wordCount(of: pageText.string),
                    charCount: snapshot.charCount ?? pageText.string.count,
                    totalPages: totalPages,
                    isFirstPage: index == 0,
                    createVisualSeparation: createVisualSeparation,
                    separatorStyle: separatorStyle,
                    includePageNumber: includePageNumber,
                    includeFilename: includeFilename,
                    includeStatistics: includeStatistics
                )
                if !separator.isEmpty {
                    combined.append(NSAttributedString(string: separator, attributes: separatorAttributes))
                }
            }

            // Add page content
            combined.append(pageText)
        }

        let attributedText = NSAttributedString(attributedString: combined)
        return TextExportResult(
            attributedText: attributedText,
            rtfData: RichTextArchiver.rtfData(from: attributedText),
            plainText: attributedText.string
        )
    }

    /// Builds the separator text between pages (empty string = no separator).
    private static func separatorString(
        pageNumber: Int,
        fileName: String?,
        wordCount: Int,
        charCount: Int,
        totalPages: Int,
        isFirstPage: Bool,
        createVisualSeparation: Bool,
        separatorStyle: SeparatorStyle,
        includePageNumber: Bool,
        includeFilename: Bool,
        includeStatistics: Bool
    ) -> String {
        guard createVisualSeparation else {
            return " "
        }

        var components: [String] = []

        if includePageNumber {
            components.append(String(localized: "Page \(pageNumber) of \(totalPages)", comment: "Page number indicator in export separator"))
        }

        if includeFilename, let filename = fileName {
            components.append(filename)
        }

        if includeStatistics {
            components.append(String(localized: "\(wordCount) words, \(charCount) characters", comment: "Word and character count in export separator"))
        }

        if isFirstPage && separatorStyle == .lineBreak && components.isEmpty {
            return ""
        }

        var separator = isFirstPage ? "" : "\n\n"

        switch separatorStyle {
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
