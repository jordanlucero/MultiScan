//
//  TextExporter.swift
//  MultiScan
//
//  Builds the combined NSAttributedString for export with configurable separators.
//
//  ## Performance Architecture
//  `snapshots(for:)` gathers Sendable per-page inputs in one of two ways:
//
//  1. **Cache-based (preferred)**: the pre-computed `TextExportCache` (RTF + statistics for every page) — a single external-storage read, used whenever it is still fresh against the pages.
//  2. **Direct page access (fallback)**: each page's raw `richTextData` — N external-storage reads. Only used when the cache is unavailable or stale.
//
//  In both modes the expensive work — decoding page RTF and appending into the combined string — happens off the main actor in `buildResult`. `NSMutableAttributedString.append` is O(n) per page.
//
//  `export(_:options:)` is nonisolated and runs on its caller: the export panel calls it on the main actor, `ProjectStore` on its model actor, so neither hands a `@Model` object across actors.
//

import SwiftUI
import SwiftData

/// The finished export: attributed text for preview plus pre-encoded share payloads.
///
/// `NSAttributedString` is not Sendable, but the instance here is built fresh inside the export task and never mutated afterward — immutable NSAttributedStrings are safe to read from any thread once ownership is transferred.
nonisolated struct TextExportResult: @unchecked Sendable {
    let attributedText: NSAttributedString
    let rtfData: Data?
    let plainText: String

    static let empty = TextExportResult(attributedText: NSAttributedString(), rtfData: nil, plainText: "")

    /// Sendable share wrapper for ShareLink.
    var richText: RichText {
        RichText(rtfData: rtfData, plainText: plainText)
    }
}

nonisolated enum TextExporter {

    /// Sendable snapshot of one page's export inputs, gathered on the actor that owns the page.
    struct PageSnapshot: Sendable {
        let pageNumber: Int
        let fileName: String?
        /// Raw persisted bytes — RTF (current) or legacy JSON; decoded off-main.
        let textData: Data?
        /// Pre-computed statistics when coming from the cache; computed after decode otherwise.
        let wordCount: Int?
        let charCount: Int?
    }

    // MARK: - Export

    /// Builds the combined export result for a project. Runs on the caller's actor up to the snapshot, then decodes and combines on the cooperative pool.
    static func export(_ document: Document, options: ExportOptions) async -> TextExportResult {
        let snapshots = snapshots(for: document)
        guard !snapshots.isEmpty else { return .empty }
        return await buildResult(from: snapshots, options: options)
    }

    /// Per-page inputs, from the export cache when it is fresh (one read) and from the pages otherwise (N reads).
    static func snapshots(for document: Document) -> [PageSnapshot] {
        if let data = document.textExportCache,
           let cache = TextExportCacheService.decodeCache(from: data),
           TextExportCacheService.isFresh(cache, against: TextExportCacheService.fingerprints(of: document)) {
            return cache.pages
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
        }
        // Fallback path: raw Data only — decode happens off-main.
        return document.unwrappedPages
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

    // MARK: - Combining (off the main actor)

    @concurrent
    static func buildResult(from snapshots: [PageSnapshot], options: ExportOptions) async -> TextExportResult {
        let combined = NSMutableAttributedString()
        let separatorAttributes: [NSAttributedString.Key: Any] = [.font: PageTextStyle.storageFont]
        let totalPages = snapshots.count

        for (index, snapshot) in snapshots.enumerated() {
            if index > 0 && index % 50 == 0 && Task.isCancelled {
                return .empty
            }

            let pageText = RichTextArchiver.attributedString(from: snapshot.textData)

            if index > 0 || options.createVisualSeparation {
                let separator = separatorString(
                    pageNumber: snapshot.pageNumber,
                    fileName: snapshot.fileName,
                    wordCount: snapshot.wordCount ?? TextStatistics.wordCount(of: pageText.string),
                    charCount: snapshot.charCount ?? pageText.string.count,
                    totalPages: totalPages,
                    isFirstPage: index == 0,
                    options: options
                )
                if !separator.isEmpty {
                    combined.append(NSAttributedString(string: separator, attributes: separatorAttributes))
                }
            }

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
