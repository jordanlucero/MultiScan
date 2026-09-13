//
//  TextExportCacheService.swift
//  MultiScan
//
//  Manages a pre-computed cache of page text data for efficient document export and Smart Cleanup analysis.
//
//  ## Purpose
//  SwiftData's `@Attribute(.externalStorage)` stores each page's rich text in a separate external file. When exporting, loading N pages means N sequential disk reads on the main thread, which freezes the UI for large documents (500+ pages can take minutes).
//
//  This service maintains a single cached file containing all pages' text data. Export loads one file instead of N, dramatically improving performance.
//
//  ## Cache Format (version 2)
//  Each entry stores the page's text twice, for different consumers:
//  - `rtfData`: the RTF bytes (same format as `Page.richTextData`) — used by export, which needs formatting.
//  - `plainText`: pre-extracted plain text — used by Smart Cleanup analysis, which never needs to decode an attributed string at all.
//  Word/char counts are pre-computed for separator metadata.
//
//  The container is encoded as a binary property list (compact for Data blobs).
//  Version 1 caches (JSON-encoded AttributedString entries) fail to decode and are rebuilt from source pages once.
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
//  All operations are `@MainActor` since they interact with SwiftData models. `decodeCache(from:)` is nonisolated so raw cache Data can be decoded on background threads (Smart Cleanup analysis, export building).
//

import Foundation
import SwiftData

// MARK: - Cache Data Structures

/// Container for all cached page text data.
/// Serialized to `Document.textExportCache` as binary-plist-encoded `Data`.
struct TextExportCache: Codable, Sendable {
    /// Version number for cache format migrations.
    /// Increment this when changing the structure to trigger automatic rebuild.
    /// - v1: JSON container, entries held Codable AttributedString (pre-TextKit 2)
    /// - v2: binary plist container, entries hold RTF data + plain text
    static let currentVersion = 2

    var version: Int = currentVersion
    var pages: [PageCacheEntry]

    init(pages: [PageCacheEntry] = []) {
        self.pages = pages
    }
}

/// Cached data for a single page, containing everything needed for export and analysis.
struct PageCacheEntry: Codable, Sendable {
    let pageNumber: Int
    let fileName: String?

    /// The page's rich text content as RTF bytes (decode with `RichTextArchiver.decodeRTF`).
    let rtfData: Data

    /// Pre-extracted plain text for Smart Cleanup analysis and search.
    let plainText: String

    /// Pre-computed word count for separator metadata.
    let wordCount: Int

    /// Pre-computed character count for separator metadata.
    let charCount: Int

    /// The source page's `lastModified` at the moment this entry was written — the freshness
    /// fingerprint checked by `TextExportCacheService.isFresh(_:against:)`.
    ///
    /// Optional because caches written before fingerprinting exist on disk (and sync). A `nil` fingerprint means "unverifiable", not "stale": rejecting those would force a full N-external-read rebuild of every document on upgrade. Entries gain fingerprints as pages are written, so the unverifiable window closes on its own.
    let pageLastModified: Date?

    /// Creates an entry from a Page's current data.
    /// Call this when the page's text is already loaded in memory.
    @MainActor
    init(from page: Page) {
        self.init(
            pageNumber: page.pageNumber,
            fileName: page.originalFileName,
            attributedText: page.attributedText,
            pageLastModified: page.lastModified
        )
    }

    /// Creates an entry from an attributed string that's already in memory.
    ///
    /// - Parameter pageLastModified: the source page's `lastModified` *after* the write that
    ///   produced `attributedText`. Pass `nil` only when no page backs this entry.
    init(pageNumber: Int, fileName: String?, attributedText: NSAttributedString, pageLastModified: Date?) {
        self.pageNumber = pageNumber
        self.fileName = fileName
        self.rtfData = RichTextArchiver.rtfData(from: attributedText) ?? Data()
        let plain = attributedText.string
        self.plainText = plain
        self.wordCount = TextStatistics.wordCount(of: plain)
        self.charCount = plain.count
        self.pageLastModified = pageLastModified
    }

    /// Creates an entry with raw fields (renumbering operations — no decode/encode).
    init(pageNumber: Int, fileName: String?, rtfData: Data, plainText: String, wordCount: Int, charCount: Int, pageLastModified: Date?) {
        self.pageNumber = pageNumber
        self.fileName = fileName
        self.rtfData = rtfData
        self.plainText = plainText
        self.wordCount = wordCount
        self.charCount = charCount
        self.pageLastModified = pageLastModified
    }

    /// Returns a copy of this entry with a different page number (no decode/encode).
    /// Reordering doesn't touch page text, so the fingerprint carries over unchanged.
    func renumbered(to newPageNumber: Int) -> PageCacheEntry {
        PageCacheEntry(
            pageNumber: newPageNumber,
            fileName: fileName,
            rtfData: rtfData,
            plainText: plainText,
            wordCount: wordCount,
            charCount: charCount,
            pageLastModified: pageLastModified
        )
    }

    /// Decodes the entry's rich text for editing/removal operations.
    func decodedText() -> NSAttributedString? {
        RichTextArchiver.decodeRTF(rtfData)
    }
}

// MARK: - Cache Service

/// Service for managing the text export cache on a Document.
///
/// ## Usage
/// ```swift
/// // After OCR completes and pages are added: TextExportCacheService.buildInitialCache(for: document, from: pages)
///
/// // After page text is saved: TextExportCacheService.updateEntry(pageNumber: 3, attributedText: text, in: document)
///
/// // After page is deleted: TextExportCacheService.removeEntry(pageNumber: 5, from: document)
///
/// // For export: if let cache = TextExportCacheService.loadCache(from: document) {
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
    ///   - pages: Array of pages with their text already loaded
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
    /// Only use as a fallback for cache recovery or migration (e.g., a v1 cache).
    ///
    /// - Parameter document: The document to rebuild the cache for
    static func rebuildCache(for document: Document) {
        // This intentionally loads all pages - it's a recovery operation
        buildInitialCache(for: document, from: document.unwrappedPages)
    }

    // MARK: - Single Page Updates

    /// Updates a page's entry using an attributed string that's already in memory (so the page's external storage is never faulted in).
    ///
    /// - Parameters:
    ///   - pageNumber: The page number to update
    ///   - attributedText: The new rich text content
    ///   - pageLastModified: the page's `lastModified` *after* the write that produced
    ///     `attributedText` — the freshness fingerprint. Read it from the page (a plain stored
    ///     column; this doesn't fault in external storage).
    ///   - document: The document containing the cache
    static func updateEntry(pageNumber: Int, attributedText: NSAttributedString, pageLastModified: Date?, in document: Document) {
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
                attributedText: attributedText,
                pageLastModified: pageLastModified
            )
            saveCache(cache, to: document)
        }
        // If entry doesn't exist, we can't create it without more info - skip update
    }

    // MARK: - Page Add/Remove

    /// Adds new page entries to the cache.
    ///
    /// Call this after new pages are added to an existing document.
    /// The pages' text should be in memory from the import/OCR process.
    ///
    /// - Parameters:
    ///   - pages: The newly added pages (with text already loaded)
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

    /// Inserts new page entries mid-document, shifting existing entries' page numbers.
    ///
    /// Call this after inserting pages at a specific position. Existing entries at or after `insertStart` are renumbered by `count` to match the already-renumbered Page models.
    /// Avoids `rebuildCache(for:)`, which would load every page from external storage.
    ///
    /// - Parameters:
    ///   - pages: The newly inserted pages (with text already loaded)
    ///   - document: The document containing the cache
    ///   - insertStart: The first page number of the inserted range
    ///   - count: How many pages were inserted
    static func insertEntries(for pages: [Page], in document: Document, shiftingFrom insertStart: Int, by count: Int) {
        guard var cache = loadCache(from: document) else {
            rebuildCache(for: document)
            return
        }

        for index in cache.pages.indices where cache.pages[index].pageNumber >= insertStart {
            cache.pages[index] = cache.pages[index].renumbered(to: cache.pages[index].pageNumber + count)
        }

        cache.pages.append(contentsOf: pages.map { PageCacheEntry(from: $0) })
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
            entry.pageNumber > pageNumber ? entry.renumbered(to: entry.pageNumber - 1) : entry
        }

        saveCache(cache, to: document)
    }

    // MARK: - Page Reordering

    /// Renumbers entries after a reorder using an old → new page number mapping.
    ///
    /// Call this after reassigning `pageNumber` on the Page models. Entries are renumbered with raw-field copies (no decode/encode) in a single cache write.
    ///
    /// - Parameters:
    ///   - newNumbers: Mapping of old page number to new page number
    ///   - document: The document containing the cache
    static func renumberEntries(_ newNumbers: [Int: Int], in document: Document) {
        guard var cache = loadCache(from: document) else { return }

        cache.pages = cache.pages.map { entry in
            guard let newNumber = newNumbers[entry.pageNumber], newNumber != entry.pageNumber else { return entry }
            return entry.renumbered(to: newNumber)
        }
        cache.pages.sort { $0.pageNumber < $1.pageNumber }

        saveCache(cache, to: document)
    }

    // MARK: - Cache Access

    /// Loads the cache from the document.
    ///
    /// Returns nil if no cache exists or if decoding fails.
    /// For export, prefer using this over accessing page text directly.
    ///
    /// - Parameter document: The document to load the cache from
    /// - Returns: The decoded cache, or nil if unavailable
    static func loadCache(from document: Document) -> TextExportCache? {
        guard let data = document.textExportCache else { return nil }
        return Self.decodeCache(from: data)
    }

    /// Decodes a cache from raw data without requiring MainActor isolation.
    /// Use this to pass cache data to background threads for analysis.
    nonisolated static func decodeCache(from data: Data) -> TextExportCache? {
        do {
            let cache = try PropertyListDecoder().decode(TextExportCache.self, from: data)

            // Check version - rebuild if outdated (v1 caches also fail plist decoding)
            if cache.version != TextExportCache.currentVersion {
                return nil
            }

            return cache
        } catch {
            return nil
        }
    }

    /// Loads the cache only if it still matches the document's pages.
    ///
    /// **Every consumer that reads page *content* out of the cache must use this**, not `loadCache(from:)`. The mutation helpers above are the exception: they run while the pages and the cache are deliberately out of step (pages renumbered, cache not yet), so a freshness check there would reject a cache that's about to be corrected and force a needless rebuild.
    ///
    /// - Parameter rebuildIfStale: rebuild from the source pages (N external-storage reads) when the cache is missing or diverged, rather than returning nil. Pass `true` only where there is no cheaper fallback.
    static func loadFreshCache(from document: Document, rebuildIfStale: Bool = false) -> TextExportCache? {
        if let cache = loadCache(from: document), isFresh(cache, against: fingerprints(of: document)) {
            return cache
        }
        guard rebuildIfStale else { return nil }
        rebuildCache(for: document)
        return loadCache(from: document)
    }

    /// Fingerprints for a document's pages, keyed by page number.
    /// Build this on the actor that owns the models, then hand it to `isFresh(_:against:)`. `nonisolated` so `ProjectStore`'s `@ModelActor` can build them for its own documents.
    nonisolated static func fingerprints(of document: Document) -> [Int: Date] {
        Dictionary(
            document.unwrappedPages.map { ($0.pageNumber, $0.lastModified) },
            uniquingKeysWith: { older, newer in max(older, newer) }
        )
    }

    /// Whether every cache entry still corresponds to its page.
    ///
    /// The cache is a single blob on `Document`, while the text it mirrors lives on the `Page` records. Under CloudKit those are separate record types with independent last-writer-wins resolution: if two devices edit different pages of the same project, both page edits merge correctly but only one device's cache blob survives — leaving a cache that is internally well-formed, the right length, and wrong. Comparing each entry's fingerprint against its page's `lastModified` is what catches that.
    nonisolated static func isFresh(_ cache: TextExportCache, against fingerprints: [Int: Date]) -> Bool {
        guard cache.pages.count == fingerprints.count else { return false }
        for entry in cache.pages {
            guard let pageDate = fingerprints[entry.pageNumber] else { return false }
            // nil fingerprint = written before fingerprinting existed; unverifiable, so accept.
            guard let entryDate = entry.pageLastModified else { continue }
            // Dates round-trip through a binary plist at sub-millisecond precision.
            guard abs(entryDate.timeIntervalSince(pageDate)) < 0.001 else { return false }
        }
        return true
    }

    // MARK: - Saving

    /// Encodes and saves the cache to the document.
    /// Internal access for batch operations (e.g., Smart Cleanup) that modify multiple entries.
    static func saveCache(_ cache: TextExportCache, to document: Document) {
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(cache)
            document.textExportCache = data
        } catch {
            print("TextExportCacheService: Failed to encode cache: \(error)")
        }
    }
}
