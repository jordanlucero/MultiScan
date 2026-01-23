//
//  TextExportCacheService.swift
//  MultiScan
//
//  Manages a pre-computed cache of page text data for efficient document export.
//
//  ## Purpose
//  SwiftData's `@Attribute(.externalStorage)` stores each page's `richText` in a separate
//  external file. When exporting, loading N pages means N sequential disk reads on the
//  main thread, which freezes the UI for large documents (500+ pages can take minutes).
//
//  This service maintains a single cached file containing all pages' text data. Export
//  loads one file instead of N, dramatically improving performance.
//
//  ## Architecture
//  - Cache is stored as `Data` on `Document.textExportCache` with external storage
//  - `TextExportCache` contains an array of `PageCacheEntry` structs
//  - Each entry stores: pageNumber, fileName, richText, wordCount, charCount
//  - Word/char counts are pre-computed for separator metadata without recalculation
//
//  ## Sync Strategy
//  The cache must stay in sync with page data. Updates happen at these points:
//  - **Document creation (after OCR)**: Build initial cache from pages in memory
//  - **Page text save**: Update that page's entry in the cache
//  - **Page add**: Add new entry/entries to the cache
//  - **Page delete**: Remove entry and renumber subsequent pages
//  - **Page reorder**: Swap pageNumbers in affected entries
//
//  ## Thread Safety
//  All operations are `@MainActor` since they interact with SwiftData models.
//  Cache updates happen synchronously during save operations - the overhead is
//  minimal (decode → update → encode a text-only structure).
//
//  ## Future Resilience
//  If the cache becomes corrupted or out of sync, `rebuildCache(for:)` can be called
//  to regenerate it from the source page data. This is a fallback that requires loading
//  all pages, but ensures data integrity.
//

import Foundation
import SwiftUI
import SwiftData

// MARK: - Cache Data Structures

/// Container for all cached page text data.
/// Serialized to `Document.textExportCache` as JSON-encoded `Data`.
struct TextExportCache: Codable, Sendable {
    /// Version number for future cache format migrations.
    /// Increment this when changing the structure to trigger automatic rebuild.
    static let currentVersion = 1

    var version: Int = currentVersion
    var pages: [PageCacheEntry]

    init(pages: [PageCacheEntry] = []) {
        self.pages = pages
    }
}

/// Cached data for a single page, containing everything needed for export.
/// Pre-computes word/char counts to avoid recalculation during export.
struct PageCacheEntry: Codable, Sendable {
    let pageNumber: Int
    let fileName: String?

    /// The page's rich text content, encoded via Codable.
    /// AttributedString conforms to Codable in modern Swift.
    let richText: AttributedString

    /// Pre-computed word count for separator metadata.
    let wordCount: Int

    /// Pre-computed character count for separator metadata.
    let charCount: Int

    /// Creates an entry from a Page's current data.
    /// Call this when the page's richText is already loaded in memory.
    init(from page: Page) {
        self.pageNumber = page.pageNumber
        self.fileName = page.originalFileName
        self.richText = page.richText

        // Pre-compute statistics from plain text
        let plainText = String(page.richText.characters)
        self.wordCount = plainText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        self.charCount = plainText.count
    }

    /// Creates an entry with explicit values (for updates where richText is already available).
    init(pageNumber: Int, fileName: String?, richText: AttributedString) {
        self.pageNumber = pageNumber
        self.fileName = fileName
        self.richText = richText

        let plainText = String(richText.characters)
        self.wordCount = plainText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        self.charCount = plainText.count
    }
}

// MARK: - Cache Service

/// Service for managing the text export cache on a Document.
///
/// ## Usage
/// ```swift
/// // After OCR completes and pages are added:
/// TextExportCacheService.buildInitialCache(for: document, from: pages)
///
/// // After page text is saved:
/// TextExportCacheService.updateEntry(for: page, in: document)
///
/// // After page is deleted:
/// TextExportCacheService.removeEntry(pageNumber: 5, from: document)
///
/// // For export:
/// if let cache = TextExportCacheService.loadCache(from: document) {
///     // Use cache.pages for export
/// }
/// ```
@MainActor
enum TextExportCacheService {

    // MARK: - Cache Building

    /// Builds the initial cache from pages that are already in memory.
    ///
    /// Call this immediately after OCR completes, while page data is still loaded.
    /// This avoids triggering external storage loads since the data is already available.
    ///
    /// - Parameters:
    ///   - document: The document to store the cache on
    ///   - pages: Array of pages with their richText already loaded
    static func buildInitialCache(for document: Document, from pages: [Page]) {
        let entries = pages
            .sorted { $0.pageNumber < $1.pageNumber }
            .map { PageCacheEntry(from: $0) }

        let cache = TextExportCache(pages: entries)
        saveCache(cache, to: document)
    }

    /// Rebuilds the cache from scratch by loading all page data.
    ///
    /// **Warning**: This triggers external storage loads for all pages.
    /// Only use as a fallback for cache recovery or migration.
    ///
    /// - Parameter document: The document to rebuild the cache for
    static func rebuildCache(for document: Document) {
        // This intentionally loads all pages - it's a recovery operation
        buildInitialCache(for: document, from: document.unwrappedPages)
    }

    // MARK: - Single Page Updates

    /// Updates a single page's entry in the cache.
    ///
    /// Call this after `page.richText` has been modified and saved.
    /// The page's richText should already be in memory from the edit session.
    ///
    /// - Parameters:
    ///   - page: The page that was updated (with richText already loaded)
    ///   - document: The document containing the cache
    static func updateEntry(for page: Page, in document: Document) {
        guard var cache = loadCache(from: document) else {
            // No cache exists - build one (fallback)
            rebuildCache(for: document)
            return
        }

        let newEntry = PageCacheEntry(from: page)

        if let index = cache.pages.firstIndex(where: { $0.pageNumber == page.pageNumber }) {
            // Update existing entry
            cache.pages[index] = newEntry
        } else {
            // Entry doesn't exist - add it and sort
            cache.pages.append(newEntry)
            cache.pages.sort { $0.pageNumber < $1.pageNumber }
        }

        saveCache(cache, to: document)
    }

    /// Updates a page's entry using an AttributedString that's already in memory.
    ///
    /// Use this variant when you have the richText available but don't want to
    /// access page.richText (which might trigger an external storage load).
    ///
    /// - Parameters:
    ///   - pageNumber: The page number to update
    ///   - richText: The new rich text content
    ///   - document: The document containing the cache
    static func updateEntry(pageNumber: Int, richText: AttributedString, in document: Document) {
        guard var cache = loadCache(from: document) else {
            rebuildCache(for: document)
            return
        }

        if let index = cache.pages.firstIndex(where: { $0.pageNumber == pageNumber }) {
            // Preserve fileName from existing entry
            let existingFileName = cache.pages[index].fileName
            cache.pages[index] = PageCacheEntry(
                pageNumber: pageNumber,
                fileName: existingFileName,
                richText: richText
            )
            saveCache(cache, to: document)
        }
        // If entry doesn't exist, we can't create it without more info - skip update
    }

    // MARK: - Page Add/Remove

    /// Adds new page entries to the cache.
    ///
    /// Call this after new pages are added to an existing document.
    /// The pages' richText should be in memory from the import/OCR process.
    ///
    /// - Parameters:
    ///   - pages: The newly added pages (with richText already loaded)
    ///   - document: The document containing the cache
    static func addEntries(for pages: [Page], to document: Document) {
        guard var cache = loadCache(from: document) else {
            // No cache exists - build one including all pages
            rebuildCache(for: document)
            return
        }

        let newEntries = pages.map { PageCacheEntry(from: $0) }
        cache.pages.append(contentsOf: newEntries)
        cache.pages.sort { $0.pageNumber < $1.pageNumber }

        saveCache(cache, to: document)
    }

    /// Removes a page entry and renumbers subsequent pages.
    ///
    /// Call this after a page is deleted from the document.
    /// Automatically decrements pageNumber for all entries after the deleted page.
    ///
    /// - Parameters:
    ///   - pageNumber: The page number that was deleted
    ///   - document: The document containing the cache
    static func removeEntry(pageNumber: Int, from document: Document) {
        guard var cache = loadCache(from: document) else { return }

        // Remove the entry
        cache.pages.removeAll { $0.pageNumber == pageNumber }

        // Renumber subsequent pages (decrement pageNumber for pages after deleted)
        cache.pages = cache.pages.map { entry in
            if entry.pageNumber > pageNumber {
                return PageCacheEntry(
                    pageNumber: entry.pageNumber - 1,
                    fileName: entry.fileName,
                    richText: entry.richText
                )
            }
            return entry
        }

        saveCache(cache, to: document)
    }

    // MARK: - Page Reordering

    /// Swaps page numbers for two entries (used when moving pages up/down).
    ///
    /// Call this after swapping pageNumber values on two Page models.
    ///
    /// - Parameters:
    ///   - pageNumber1: First page number involved in the swap
    ///   - pageNumber2: Second page number involved in the swap
    ///   - document: The document containing the cache
    static func swapPageNumbers(_ pageNumber1: Int, _ pageNumber2: Int, in document: Document) {
        guard var cache = loadCache(from: document) else { return }

        guard let index1 = cache.pages.firstIndex(where: { $0.pageNumber == pageNumber1 }),
              let index2 = cache.pages.firstIndex(where: { $0.pageNumber == pageNumber2 }) else {
            return
        }

        // Swap page numbers in the entries
        let entry1 = cache.pages[index1]
        let entry2 = cache.pages[index2]

        cache.pages[index1] = PageCacheEntry(
            pageNumber: pageNumber2,
            fileName: entry1.fileName,
            richText: entry1.richText
        )
        cache.pages[index2] = PageCacheEntry(
            pageNumber: pageNumber1,
            fileName: entry2.fileName,
            richText: entry2.richText
        )

        // Re-sort by page number
        cache.pages.sort { $0.pageNumber < $1.pageNumber }

        saveCache(cache, to: document)
    }

    // MARK: - Cache Access

    /// Loads the cache from the document.
    ///
    /// Returns nil if no cache exists or if decoding fails.
    /// For export, prefer using this over accessing page.richText directly.
    ///
    /// - Parameter document: The document to load the cache from
    /// - Returns: The decoded cache, or nil if unavailable
    static func loadCache(from document: Document) -> TextExportCache? {
        guard let data = document.textExportCache else { return nil }

        do {
            let cache = try JSONDecoder().decode(TextExportCache.self, from: data)

            // Check version - rebuild if outdated
            if cache.version != TextExportCache.currentVersion {
                // Future: handle migrations here
                return nil
            }

            return cache
        } catch {
            return nil
        }
    }

    /// Checks if a valid cache exists for the document.
    ///
    /// Use this to decide whether to use cached export or fall back to direct loading.
    ///
    /// - Parameter document: The document to check
    /// - Returns: True if a valid, current-version cache exists
    static func hasValidCache(for document: Document) -> Bool {
        guard let cache = loadCache(from: document) else { return false }
        return cache.pages.count == document.unwrappedPages.count
    }

    // MARK: - Private Helpers

    /// Encodes and saves the cache to the document.
    private static func saveCache(_ cache: TextExportCache, to document: Document) {
        do {
            let data = try JSONEncoder().encode(cache)
            document.textExportCache = data
        } catch {
            print("TextExportCacheService: Failed to encode cache: \(error)")
        }
    }
}
