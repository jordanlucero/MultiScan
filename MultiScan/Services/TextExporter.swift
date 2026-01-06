//
//  TextExporter.swift
//  MultiScan
//
//  Handles building combined AttributedString for export with configurable separators.
//

import SwiftUI

/// Metadata extracted from pages on main thread for async processing
private struct PageExportData: Sendable {
    let pageNumber: Int
    let richTextData: Data
    let originalFileName: String?
}

/// Settings snapshot for off-main-thread processing
private struct ExportSettingsSnapshot: Sendable {
    let createVisualSeparation: Bool
    let separatorStyle: SeparatorStyle
    let includePageNumber: Bool
    let includeFilename: Bool
    let includeStatistics: Bool
}

struct TextExporter {
    let pages: [Page]
    let settings: ExportSettings

    // MARK: - Async Export (for large documents)

    /// Async version that processes pages off the main thread
    /// Uses parallel JSON decoding and O(n) string building
    @MainActor
    func buildCombinedTextAsync() async -> AttributedString {
        // Step 1: Extract raw data on main actor (fast, just pointer copies)
        let sortedPages = pages.sorted { $0.pageNumber < $1.pageNumber }
        let pageData = sortedPages.map { PageExportData(
            pageNumber: $0.pageNumber,
            richTextData: $0.rawRichTextData,
            originalFileName: $0.originalFileName
        )}

        // Capture settings snapshot before leaving main actor
        let settingsSnapshot = ExportSettingsSnapshot(
            createVisualSeparation: settings.createVisualSeparation,
            separatorStyle: settings.separatorStyle,
            includePageNumber: settings.includePageNumber,
            includeFilename: settings.includeFilename,
            includeStatistics: settings.includeStatistics
        )

        let totalPages = pageData.count
        guard totalPages > 0 else { return AttributedString() }

        // Step 2: Decode JSON in parallel (expensive, off main thread)
        let decoded: [(Int, AttributedString, String)] = await withTaskGroup(
            of: (Int, AttributedString, String).self
        ) { group in
            for data in pageData {
                group.addTask {
                    let richText = (try? AttributedString.decodeFromJSON(data.richTextData))
                        ?? AttributedString("")
                    let plainText = String(richText.characters)
                    return (data.pageNumber, richText, plainText)
                }
            }

            var results: [(Int, AttributedString, String)] = []
            results.reserveCapacity(totalPages)
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.0 < $1.0 }
        }

        // Step 3: Build combined string with O(n) appends using NSMutableAttributedString
        let pageDataByNumber = Dictionary(uniqueKeysWithValues: pageData.map { ($0.pageNumber, $0) })

        return buildCombinedFromDecoded(
            decoded: decoded,
            pageData: pageDataByNumber,
            totalPages: totalPages,
            settings: settingsSnapshot
        )
    }

    /// Build combined text from pre-decoded data (O(n) using NSMutableAttributedString)
    private func buildCombinedFromDecoded(
        decoded: [(Int, AttributedString, String)],
        pageData: [Int: PageExportData],
        totalPages: Int,
        settings: ExportSettingsSnapshot
    ) -> AttributedString {
        let mutable = NSMutableAttributedString()

        for (index, (pageNumber, richText, plainText)) in decoded.enumerated() {
            let data = pageData[pageNumber]

            // Add separator between pages (not before first page for inline)
            if index > 0 || settings.createVisualSeparation {
                let separator = buildSeparatorFromData(
                    pageNumber: pageNumber,
                    fileName: data?.originalFileName,
                    plainText: plainText,
                    pageIndex: index,
                    totalPages: totalPages,
                    isFirstPage: index == 0,
                    settings: settings
                )
                mutable.append(NSAttributedString(separator))
            }

            // Add page content
            mutable.append(NSAttributedString(richText))
        }

        return AttributedString(mutable)
    }

    /// Build separator from pre-extracted data (no Page access needed)
    private func buildSeparatorFromData(
        pageNumber: Int,
        fileName: String?,
        plainText: String,
        pageIndex: Int,
        totalPages: Int,
        isFirstPage: Bool,
        settings: ExportSettingsSnapshot
    ) -> AttributedString {
        // If visual separation is disabled, just use a space between pages
        guard settings.createVisualSeparation else {
            return AttributedString(" ")
        }

        // Build visual separator based on style
        return buildVisualSeparatorFromData(
            pageNumber: pageNumber,
            fileName: fileName,
            plainText: plainText,
            totalPages: totalPages,
            isFirstPage: isFirstPage,
            settings: settings
        )
    }

    /// Build visual separator from pre-extracted data
    private func buildVisualSeparatorFromData(
        pageNumber: Int,
        fileName: String?,
        plainText: String,
        totalPages: Int,
        isFirstPage: Bool,
        settings: ExportSettingsSnapshot
    ) -> AttributedString {
        // Collect metadata components (separator mods)
        var components: [String] = []

        if settings.includePageNumber {
            components.append(String(localized: "Page \(pageNumber) of \(totalPages)", comment: "Page number indicator in export separator"))
        }

        if settings.includeFilename, let filename = fileName {
            components.append(filename)
        }

        if settings.includeStatistics {
            let words = plainText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            let chars = plainText.count
            components.append(String(localized: "\(words) words, \(chars) characters", comment: "Word and character count in export separator"))
        }

        // For line break style with no mods on first page, return empty (no separator needed)
        if isFirstPage && settings.separatorStyle == .lineBreak && components.isEmpty {
            return AttributedString()
        }

        var separator = isFirstPage ? AttributedString() : AttributedString("\n\n")

        // Build separator based on style
        switch settings.separatorStyle {
        case .lineBreak:
            // Just line breaks with optional metadata on a single line
            if !components.isEmpty {
                separator.append(AttributedString("[\(components.joined(separator: " | "))]"))
            }

        case .hyphenatedDivider:
            // Hyphen line with metadata below
            separator.append(AttributedString(String(repeating: "-", count: 40)))
            if !components.isEmpty {
                separator.append(AttributedString("\n"))
                separator.append(AttributedString(components.joined(separator: " | ")))
            }
        }

        separator.append(AttributedString("\n\n"))
        return separator
    }

    // MARK: - Sync Export (original, for small documents)

    /// Build combined AttributedString based on current settings (synchronous)
    @MainActor
    func buildCombinedText() -> AttributedString {
        let sortedPages = pages.sorted { $0.pageNumber < $1.pageNumber }
        var combined = AttributedString()

        for (index, page) in sortedPages.enumerated() {
            // Add separator between pages
            if index > 0 || settings.createVisualSeparation {
                combined.append(buildSeparator(
                    beforePage: page,
                    pageIndex: index,
                    totalPages: sortedPages.count,
                    isFirstPage: index == 0
                ))
            }

            combined.append(page.richText)
        }

        return combined
    }

    /// Build the appropriate separator based on settings
    @MainActor
    private func buildSeparator(beforePage page: Page, pageIndex: Int, totalPages: Int, isFirstPage: Bool) -> AttributedString {
        // If visual separation is disabled, just use a space between pages
        guard settings.createVisualSeparation else {
            return AttributedString(" ")
        }

        return buildVisualSeparator(beforePage: page, pageIndex: pageIndex, totalPages: totalPages, isFirstPage: isFirstPage)
    }

    /// Build a visual separator with metadata
    @MainActor
    private func buildVisualSeparator(beforePage page: Page, pageIndex: Int, totalPages: Int, isFirstPage: Bool) -> AttributedString {
        // Collect metadata components (separator mods)
        var components: [String] = []

        if settings.includePageNumber {
            components.append(String(localized: "Page \(page.pageNumber) of \(totalPages)", comment: "Page number indicator in export separator"))
        }

        if settings.includeFilename, let filename = page.originalFileName {
            components.append(filename)
        }

        if settings.includeStatistics {
            let text = page.plainText
            let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            let chars = text.count
            components.append(String(localized: "\(words) words, \(chars) characters", comment: "Word and character count in export separator"))
        }

        // For line break style with no mods on first page, return empty (no separator needed)
        if isFirstPage && settings.separatorStyle == .lineBreak && components.isEmpty {
            return AttributedString()
        }

        var separator = isFirstPage ? AttributedString() : AttributedString("\n\n")

        // Build separator based on style
        switch settings.separatorStyle {
        case .lineBreak:
            if !components.isEmpty {
                separator.append(AttributedString("[\(components.joined(separator: " | "))]"))
            }

        case .hyphenatedDivider:
            separator.append(AttributedString(String(repeating: "-", count: 40)))
            if !components.isEmpty {
                separator.append(AttributedString("\n"))
                separator.append(AttributedString(components.joined(separator: " | ")))
            }
        }

        separator.append(AttributedString("\n\n"))
        return separator
    }
}
