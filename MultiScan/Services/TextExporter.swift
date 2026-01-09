//
//  TextExporter.swift
//  MultiScan
//
//  Handles building combined AttributedString for export with configurable separators.
//

import SwiftUI

/// Settings snapshot for thread-safe processing
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

    /// Chunk size for cooperative multitasking — yields to UI after this many pages
    private static let chunkSize = 50

    /// Builds combined AttributedString from all pages
    /// Extracts data on main actor, builds on background thread to keep UI responsive
    @MainActor
    func buildCombinedTextAsync() async -> AttributedString {
        let sortedPages = pages.sorted { $0.pageNumber < $1.pageNumber }
        let totalPages = sortedPages.count
        guard totalPages > 0 else { return AttributedString() }

        // Step 1: Extract all data on main actor (SwiftData requirement)
        // This is fast — just copying AttributedStrings out of SwiftData
        let pageData: [(text: AttributedString, number: Int, fileName: String?, plainText: String)] =
            sortedPages.map { ($0.richText, $0.pageNumber, $0.originalFileName, $0.plainText) }

        // Capture settings for background use
        let createVisualSeparation = settings.createVisualSeparation
        let separatorStyle = settings.separatorStyle
        let includePageNumber = settings.includePageNumber
        let includeFilename = settings.includeFilename
        let includeStatistics = settings.includeStatistics

        // Step 2: Build combined string on background thread (expensive O(n²) work)
        let result = await Task.detached(priority: .userInitiated) {
            var combined = AttributedString()

            for (index, data) in pageData.enumerated() {
                // Check for cancellation periodically
                if index > 0 && index % 50 == 0 && Task.isCancelled {
                    return AttributedString()
                }

                // Add separator
                if index > 0 || createVisualSeparation {
                    let separator = Self.buildSeparatorStatic(
                        pageNumber: data.number,
                        fileName: data.fileName,
                        plainText: data.plainText,
                        totalPages: totalPages,
                        isFirstPage: index == 0,
                        createVisualSeparation: createVisualSeparation,
                        separatorStyle: separatorStyle,
                        includePageNumber: includePageNumber,
                        includeFilename: includeFilename,
                        includeStatistics: includeStatistics
                    )
                    combined.append(separator)
                }

                // Add page content
                combined.append(data.text)
            }

            return combined
        }.value

        return result
    }

    /// Static separator builder for background thread use
    private static func buildSeparatorStatic(
        pageNumber: Int,
        fileName: String?,
        plainText: String,
        totalPages: Int,
        isFirstPage: Bool,
        createVisualSeparation: Bool,
        separatorStyle: SeparatorStyle,
        includePageNumber: Bool,
        includeFilename: Bool,
        includeStatistics: Bool
    ) -> AttributedString {
        guard createVisualSeparation else {
            return AttributedString(" ")
        }

        var components: [String] = []

        if includePageNumber {
            components.append(String(localized: "Page \(pageNumber) of \(totalPages)", comment: "Page number indicator in export separator"))
        }

        if includeFilename, let filename = fileName {
            components.append(filename)
        }

        if includeStatistics {
            let words = plainText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            let chars = plainText.count
            components.append(String(localized: "\(words) words, \(chars) characters", comment: "Word and character count in export separator"))
        }

        if isFirstPage && separatorStyle == .lineBreak && components.isEmpty {
            return AttributedString()
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

        separator += "\n\n"
        return AttributedString(separator)
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
