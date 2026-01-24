//
//  TextExporter.swift
//  MultiScan
//
//  Handles building combined AttributedString for export with configurable separators.
//
//  ## Performance Architecture
//  This exporter supports two modes:
//
//  1. **Cache-based (preferred)**: Uses `TextExportCacheService` to load pre-computed
//     page data from a single cached file.
//
//  2. **Direct page access (fallback)**: Loads each page's richText from SwiftData
//     external storage. This triggers N disk reads. Only used when cache is unavailable or invalid.
//
//  ## Usage
//  Prefer initializing with a Document to enable cache-based export:
//  ```swift
//  let exporter = TextExporter(document: document, settings: settings)
//  let result = await exporter.buildCombinedTextAsync()
//  ```
//

import SwiftUI
import SwiftData

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

    // MARK: - Async Export (for large documents)

    /// Chunk size for cooperative multitasking — yields to UI after this many pages
    private static let chunkSize = 50

    /// Builds combined AttributedString from all pages.
    ///
    /// Uses cache when available (fast single-file load), falls back to direct
    /// page access if cache is unavailable (slow N-file load).
    @MainActor
    func buildCombinedTextAsync() async -> AttributedString {
        // Try cache-based export first (preferred - single file load)
        if let document = document,
           let cache = TextExportCacheService.loadCache(from: document),
           cache.pages.count == document.unwrappedPages.count {
            return await buildFromCacheAsync(cache: cache)
        }

        // Fall back to direct page access (triggers N external storage loads)
        return await buildFromPagesAsync()
    }

    /// Builds combined text from cached page data (fast path).
    ///
    /// This avoids loading individual page external storage files by using
    /// pre-computed cache data. All work after cache load happens on background thread.
    @MainActor
    private func buildFromCacheAsync(cache: TextExportCache) async -> AttributedString {
        let sortedEntries = cache.pages.sorted { $0.pageNumber < $1.pageNumber }
        let totalPages = sortedEntries.count
        guard totalPages > 0 else { return AttributedString() }

        // Capture settings on main actor for background use
        let createVisualSeparation = settings.createVisualSeparation
        let separatorStyle = settings.separatorStyle
        let includePageNumber = settings.includePageNumber
        let includeFilename = settings.includeFilename
        let includeStatistics = settings.includeStatistics

        // Build combined string on background thread
        let result = await Task.detached(priority: .userInitiated) {
            var combined = AttributedString()

            for (index, entry) in sortedEntries.enumerated() {
                // Check for cancellation periodically
                if index > 0 && index % 50 == 0 && Task.isCancelled {
                    return AttributedString()
                }

                // Add separator
                if index > 0 || createVisualSeparation {
                    let separator = Self.buildSeparatorFromCacheEntry(
                        entry: entry,
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
                combined.append(entry.richText)
            }

            return combined
        }.value

        return result
    }

    /// Builds separator from a cache entry (uses pre-computed word/char counts).
    private static func buildSeparatorFromCacheEntry(
        entry: PageCacheEntry,
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
            components.append(String(localized: "Page \(entry.pageNumber) of \(totalPages)", comment: "Page number indicator in export separator"))
        }

        if includeFilename, let filename = entry.fileName {
            components.append(filename)
        }

        if includeStatistics {
            // Use pre-computed counts from cache entry
            components.append(String(localized: "\(entry.wordCount) words, \(entry.charCount) characters", comment: "Word and character count in export separator"))
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

        separator += "\n"
        return AttributedString(separator)
    }

    /// Builds combined text by loading each page's richText (slow fallback).
    ///
    /// **Warning**: This triggers N external storage file loads on the main thread,
    /// which can freeze the UI for large documents. Cache-based export is preferred.
    @MainActor
    private func buildFromPagesAsync() async -> AttributedString {
        let sortedPages = pages.sorted { $0.pageNumber < $1.pageNumber }
        let totalPages = sortedPages.count
        guard totalPages > 0 else { return AttributedString() }

        // Step 1: Extract all data on main actor (SwiftData requirement)
        // WARNING: This triggers N external storage loads - can be slow for large documents
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

        var separator = isFirstPage ? "" : "\n"

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
        return AttributedString(separator)
    }
}
