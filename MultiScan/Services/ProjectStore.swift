//
//  ProjectStore.swift
//  MultiScan
//
//  Read-side data access for App Intents, entity queries, Spotlight indexing, and app-wide search.
//
//  ## Isolation
//  `ProjectStore` is a `@ModelActor`: every fetch runs on its own context, off the main actor, and only `Sendable` snapshots (entities, search hits, fingerprints) cross the actor boundary — never `@Model` objects. All *writes* stay on the main context (`ProjectMaintenance`) so `@Query` views and the in-memory objects the UI holds stay coherent.
//

import AppIntents
import Foundation
import SwiftData
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import os

// MARK: - Sendable results

struct ProjectSearchHit: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let emoji: String?
    let pageCount: Int
}

struct PageSearchHit: Identifiable, Hashable, Sendable {
    let id: UUID
    let projectID: UUID
    let projectName: String
    let projectEmoji: String?
    let pageNumber: Int
    /// A short window of the page text around the first match.
    let snippet: String
}

struct SearchResults: Sendable {
    let term: String
    let projects: [ProjectSearchHit]
    let pages: [PageSearchHit]

    static let empty = SearchResults(term: "", projects: [], pages: [])
    var isEmpty: Bool { projects.isEmpty && pages.isEmpty }
}

/// Deterministic per-row fingerprints the Spotlight indexer diffs against its manifest.
struct IndexFingerprints: Sendable {
    var projects: [UUID: String] = [:]
    var pages: [UUID: String] = [:]
    /// Page → owning project, so changed pages can be re-fetched by project.
    var pageProject: [UUID: UUID] = [:]
}

/// Separator settings for text export, captured as a value so they can cross actors.
struct ExportOptions: Sendable {
    var createVisualSeparation: Bool
    var separatorStyle: SeparatorStyle
    var includePageNumber: Bool
    var includeFilename: Bool
    var includeStatistics: Bool

    /// The user's current in-app export preferences.
    @MainActor
    static func current() -> ExportOptions {
        let settings = ExportSettings()
        return ExportOptions(
            createVisualSeparation: settings.createVisualSeparation,
            separatorStyle: settings.separatorStyle,
            includePageNumber: settings.includePageNumber,
            includeFilename: settings.includeFilename,
            includeStatistics: settings.includeStatistics
        )
    }

    /// Plain "Page X of Y" separators (or none) — used by the Get Project Text intent.
    static func simple(separatePages: Bool) -> ExportOptions {
        ExportOptions(
            createVisualSeparation: separatePages,
            separatorStyle: .lineBreak,
            includePageNumber: true,
            includeFilename: false,
            includeStatistics: false
        )
    }
}

struct ProjectTextExport: Sendable {
    let rtfData: Data?
    let plainText: String
}

/// Conforms to `CustomLocalizedStringResourceConvertible` as well as `LocalizedError`: these errors escape into App Intents (`GetProjectTextIntent`, the entities' `Transferable` exports), and the framework routes thrown errors by type — a `LocalizedError` alone shows as a generic failure.
enum ProjectStoreError: LocalizedError, CustomLocalizedStringResourceConvertible {
    case projectNotFound
    case pageNotFound
    case noImage

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .projectNotFound: "That project no longer exists."
        case .pageNotFound: "That page no longer exists."
        case .noImage: "This page has no image."
        }
    }

    var errorDescription: String? {
        String(localized: localizedStringResource)
    }
}

// MARK: - Store

@ModelActor
actor ProjectStore {
    @MainActor static let shared = ProjectStore(modelContainer: AppModelContainer.shared)

    private static let logger = Logger(subsystem: "co.jservices.MultiScan", category: "ProjectStore")

    /// Characters of page text used for summaries / Spotlight descriptions.
    private static let summaryLength = 200

    // MARK: Lookup

    private func document(uuid: UUID) -> Document? {
        var descriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.uuid == uuid })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    private func page(uuid: UUID) -> Page? {
        var descriptor = FetchDescriptor<Page>(predicate: #Predicate { $0.uuid == uuid })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    private func allDocuments() -> [Document] {
        (try? modelContext.fetch(FetchDescriptor<Document>())) ?? []
    }

    // MARK: Project entities

    func projectEntity(uuid: UUID) -> ProjectEntity? {
        document(uuid: uuid).flatMap(makeProjectEntity)
    }

    /// Batch resolve for `EntityQuery.entities(for:)` — one fetch for all identifiers, not one each.
    /// Identifiers with no match are simply absent from the result (the framework expects that).
    func projectEntities(uuids: [UUID]) -> [ProjectEntity] {
        guard !uuids.isEmpty else { return [] }
        let wanted = Set(uuids.map { Optional($0) })
        let descriptor = FetchDescriptor<Document>(predicate: #Predicate { wanted.contains($0.uuid) })
        let entities = ((try? modelContext.fetch(descriptor)) ?? []).compactMap(makeProjectEntity)
        let byID = Dictionary(entities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return uuids.compactMap { byID[$0] }
    }

    /// Most recently modified projects first.
    func recentProjectEntities(limit: Int) -> [ProjectEntity] {
        allDocuments()
            .sorted { $0.lastModifiedDate > $1.lastModifiedDate }
            .prefix(limit)
            .compactMap(makeProjectEntity)
    }

    /// Projects whose name matches, plus projects containing pages whose text matches.
    func projectEntities(matching term: String, limit: Int = 20) -> [ProjectEntity] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return recentProjectEntities(limit: limit) }

        var seen = Set<UUID>()
        var results: [ProjectEntity] = []

        let byName = FetchDescriptor<Document>(predicate: #Predicate { $0.name.localizedStandardContains(trimmed) })
        for document in (try? modelContext.fetch(byName)) ?? [] {
            guard let entity = makeProjectEntity(document), seen.insert(entity.id).inserted else { continue }
            results.append(entity)
            if results.count >= limit { return results }
        }

        var byText = FetchDescriptor<Page>(predicate: #Predicate { $0.plainText.localizedStandardContains(trimmed) })
        byText.fetchLimit = 200
        for page in (try? modelContext.fetch(byText)) ?? [] {
            guard let document = page.document,
                  let entity = makeProjectEntity(document),
                  seen.insert(entity.id).inserted else { continue }
            results.append(entity)
            if results.count >= limit { break }
        }
        return results
    }

    /// Executes a parsed Shortcuts "Find Projects where…" filter. Projects are few (pages are the unbounded side), so filtering in memory is bounded — but entities are only built for the survivors, because `makeProjectEntity` re-encodes a cover thumbnail.
    func projectEntities(
        matching filters: [ProjectQueryFilter],
        matchAll: Bool,
        sortedBy: [QuerySortOrder<ProjectSortKey>],
        limit: Int?
    ) -> [ProjectEntity] {
        var documents = allDocuments()
        if !filters.isEmpty {
            documents = documents.filter { document in
                matchAll
                    ? filters.allSatisfy { $0.matches(document) }
                    : filters.contains { $0.matches(document) }
            }
        }
        documents.sort { a, b in
            for order in sortedBy {
                if let ascending = order.compare(a, b) { return ascending }
            }
            return a.lastModifiedDate > b.lastModifiedDate
        }
        if let limit { documents = Array(documents.prefix(limit)) }
        return documents.compactMap(makeProjectEntity)
    }

    // MARK: Page entities

    func pageEntity(uuid: UUID) -> PageEntity? {
        page(uuid: uuid).flatMap(makePageEntity)
    }

    /// Batch resolve for `EntityQuery.entities(for:)` — one fetch for all identifiers, not one each.
    func pageEntities(uuids: [UUID]) -> [PageEntity] {
        guard !uuids.isEmpty else { return [] }
        let wanted = Set(uuids.map { Optional($0) })
        let descriptor = FetchDescriptor<Page>(predicate: #Predicate { wanted.contains($0.uuid) })
        let entities = ((try? modelContext.fetch(descriptor)) ?? []).compactMap(makePageEntity)
        let byID = Dictionary(entities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return uuids.compactMap { byID[$0] }
    }

    /// Pages of the given projects, restricted to `ids`. Fetches each project once instead of N page lookups.
    func pageEntities(byProject groups: [UUID: [UUID]]) -> [PageEntity] {
        var entities: [PageEntity] = []
        for (projectID, pageIDs) in groups {
            guard let document = document(uuid: projectID) else { continue }
            let wanted = Set(pageIDs)
            for page in document.unwrappedPages where page.uuid.map(wanted.contains) == true {
                if let entity = makePageEntity(page) { entities.append(entity) }
            }
        }
        return entities
    }

    /// Pages of the most recently modified project (for Shortcuts suggestions).
    func suggestedPageEntities(limit: Int) -> [PageEntity] {
        guard let document = allDocuments().max(by: { $0.lastModifiedDate < $1.lastModifiedDate }) else { return [] }
        return document.unwrappedPages
            .sorted { $0.pageNumber < $1.pageNumber }
            .prefix(limit)
            .compactMap(makePageEntity)
    }

    func pageEntities(matching term: String, limit: Int = 50) -> [PageEntity] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return suggestedPageEntities(limit: limit) }
        var descriptor = FetchDescriptor<Page>(
            predicate: #Predicate { $0.plainText.localizedStandardContains(trimmed) },
            sortBy: [SortDescriptor(\.pageNumber)]
        )
        descriptor.fetchLimit = limit
        return ((try? modelContext.fetch(descriptor)) ?? []).compactMap(makePageEntity)
    }

    /// Executes a parsed Shortcuts "Find Pages where…" filter. The page store is unbounded, so a full-text term is pushed down into the fetch (the one filter that would otherwise scan every page's OCR text); the remaining comparators are cheap field checks evaluated in memory. An `.or` query has no single pushable predicate, so it scans — that's the trade the mode implies.
    func pageEntities(
        matching filters: [PageQueryFilter],
        matchAll: Bool,
        sortedBy: [QuerySortOrder<PageSortKey>],
        limit: Int?
    ) -> [PageEntity] {
        var descriptor = FetchDescriptor<Page>()
        if matchAll, let term = filters.compactMap(\.fullTextTerm).first, !term.isEmpty {
            descriptor.predicate = #Predicate { $0.plainText.localizedStandardContains(term) }
        }
        var pages = (try? modelContext.fetch(descriptor)) ?? []
        if !filters.isEmpty {
            pages = pages.filter { page in
                matchAll
                    ? filters.allSatisfy { $0.matches(page) }
                    : filters.contains { $0.matches(page) }
            }
        }
        pages.sort { a, b in
            for order in sortedBy {
                if let ascending = order.compare(a, b) { return ascending }
            }
            return a.pageNumber < b.pageNumber
        }
        if let limit { pages = Array(pages.prefix(limit)) }
        return pages.compactMap(makePageEntity)
    }

    // MARK: App-wide search

    func search(term: String, pageLimit: Int = 200) -> SearchResults {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        let projectDescriptor = FetchDescriptor<Document>(
            predicate: #Predicate { $0.name.localizedStandardContains(trimmed) },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let projects: [ProjectSearchHit] = ((try? modelContext.fetch(projectDescriptor)) ?? []).compactMap { document in
            guard let id = document.uuid else { return nil }
            return ProjectSearchHit(id: id, name: document.name, emoji: document.emoji, pageCount: document.totalPages)
        }

        var pageDescriptor = FetchDescriptor<Page>(
            predicate: #Predicate { $0.plainText.localizedStandardContains(trimmed) },
            sortBy: [SortDescriptor(\.pageNumber)]
        )
        pageDescriptor.fetchLimit = pageLimit
        let pages: [PageSearchHit] = ((try? modelContext.fetch(pageDescriptor)) ?? []).compactMap { page in
            guard let id = page.uuid, let document = page.document, let projectID = document.uuid else { return nil }
            return PageSearchHit(
                id: id,
                projectID: projectID,
                projectName: document.name,
                projectEmoji: document.emoji,
                pageNumber: page.pageNumber,
                snippet: Self.snippet(in: page.plainText, matching: trimmed)
            )
        }
        .sorted { lhs, rhs in
            if lhs.projectID != rhs.projectID {
                return lhs.projectName.localizedStandardCompare(rhs.projectName) == .orderedAscending
            }
            return lhs.pageNumber < rhs.pageNumber
        }

        return SearchResults(term: trimmed, projects: projects, pages: pages)
    }

    /// A single-line window of `text` around the first case/diacritic-insensitive match of `term`.
    nonisolated static func snippet(in text: String, matching term: String, radius: Int = 60) -> String {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        guard let range = text.range(of: term, options: options) else {
            return String(text.prefix(radius * 2)).collapsingWhitespace()
        }
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        var window = String(text[start..<end]).collapsingWhitespace()
        if start > text.startIndex { window = "…" + window }
        if end < text.endIndex { window += "…" }
        return window
    }

    // MARK: Text export

    /// Combined project text (RTF + plain) built from the export cache — one external read.
    func projectText(uuid: UUID, options: ExportOptions) throws -> ProjectTextExport {
        guard let document = document(uuid: uuid) else { throw ProjectStoreError.projectNotFound }

        let snapshots: [TextExporter.PageSnapshot]
        if let data = document.textExportCache,
           let cache = TextExportCacheService.decodeCache(from: data),
           TextExportCacheService.isFresh(cache, against: TextExportCacheService.fingerprints(of: document)) {
            snapshots = cache.pages
                .sorted { $0.pageNumber < $1.pageNumber }
                .map { TextExporter.PageSnapshot(pageNumber: $0.pageNumber, fileName: $0.fileName, textData: $0.rtfData, wordCount: $0.wordCount, charCount: $0.charCount) }
        } else {
            snapshots = document.unwrappedPages
                .sorted { $0.pageNumber < $1.pageNumber }
                .map { TextExporter.PageSnapshot(pageNumber: $0.pageNumber, fileName: $0.originalFileName, textData: $0.richTextData, wordCount: nil, charCount: nil) }
        }

        let result = TextExporter.buildResult(
            from: snapshots,
            createVisualSeparation: options.createVisualSeparation,
            separatorStyle: options.separatorStyle,
            includePageNumber: options.includePageNumber,
            includeFilename: options.includeFilename,
            includeStatistics: options.includeStatistics
        )
        return ProjectTextExport(rtfData: result.rtfData, plainText: result.plainText)
    }

    /// One page's stored RTF bytes (already RTF for 2.x data; legacy JSON is re-encoded).
    func pageRTF(uuid: UUID) throws -> Data {
        guard let page = page(uuid: uuid) else { throw ProjectStoreError.pageNotFound }
        if let data = page.richTextData, RichTextArchiver.isRTF(data) { return data }
        return RichTextArchiver.rtfData(from: page.attributedText) ?? Data()
    }

    /// The page image with rotation and display adjustments applied, encoded as JPEG.
    func pageJPEG(uuid: UUID) throws -> Data {
        guard let page = page(uuid: uuid) else { throw ProjectStoreError.pageNotFound }
        guard let data = page.imageData,
              let cgImage = PlatformImage.processedCGImage(
                from: data,
                userRotation: page.rotation,
                increaseContrast: page.increaseContrast,
                increaseBlackPoint: page.increaseBlackPoint
              ),
              let jpeg = Self.encodeJPEG(cgImage, quality: 0.85) else {
            throw ProjectStoreError.noImage
        }
        return jpeg
    }

    // MARK: Fingerprints (Spotlight reconcile)

    func fingerprints() -> IndexFingerprints {
        var result = IndexFingerprints()
        for document in allDocuments() {
            guard let documentID = document.uuid else { continue }
            let pages = document.unwrappedPages
            let cover = document.lastModifiedPage?.uuid?.uuidString ?? ""
            result.projects[documentID] = [
                document.name,
                document.emoji ?? "",
                String(document.totalPages),
                String(document.lastModifiedDate.timeIntervalSinceReferenceDate),
                cover
            ].joined(separator: "|")

            for page in pages {
                guard let pageID = page.uuid else { continue }
                result.pages[pageID] = [
                    documentID.uuidString,
                    document.name,
                    String(page.pageNumber),
                    page.isDone ? "1" : "0",
                    String(page.lastModified.timeIntervalSinceReferenceDate),
                    page.originalFileName ?? ""
                ].joined(separator: "|")
                result.pageProject[pageID] = documentID
            }
        }
        return result
    }

    // MARK: Entity building

    private func makeProjectEntity(_ document: Document) -> ProjectEntity? {
        guard let uuid = document.uuid else { return nil }
        let pages = document.unwrappedPages.sorted { $0.pageNumber < $1.pageNumber }
        let cover = document.lastModifiedPage?.thumbnailData ?? pages.first?.thumbnailData
        return ProjectEntity(
            id: uuid,
            name: document.name,
            emoji: document.emoji,
            pageCount: document.totalPages,
            reviewedPageCount: pages.filter(\.isDone).count,
            createdAt: document.createdAt,
            lastModified: document.lastModifiedDate,
            summary: Self.summary(of: pages.first?.plainText ?? ""),
            coverThumbnail: Self.downscaledJPEG(cover, maxPixelSize: 200)
        )
    }

    private func makePageEntity(_ page: Page) -> PageEntity? {
        guard let uuid = page.uuid, let document = page.document, let projectID = document.uuid else { return nil }
        return PageEntity(
            id: uuid,
            projectID: projectID,
            pageNumber: page.pageNumber,
            projectName: document.name,
            isReviewed: page.isDone,
            fileName: page.originalFileName,
            text: page.plainText,
            lastModified: page.lastModified,
            thumbnail: Self.downscaledJPEG(page.thumbnailData, maxPixelSize: 128)
        )
    }

    nonisolated static func summary(of text: String) -> String {
        String(text.prefix(summaryLength)).collapsingWhitespace()
    }

    // MARK: Image helpers

    /// Re-encodes a stored (HEIC) thumbnail as a small JPEG for the Spotlight index.
    nonisolated static func downscaledJPEG(_ data: Data?, maxPixelSize: Int, quality: CGFloat = 0.6) -> Data? {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return encodeJPEG(thumbnail, quality: quality)
    }

    nonisolated static func encodeJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

// MARK: - Main-context maintenance & commands

/// Writes that App Intents and the launch sequence perform. Everything here runs on the main
/// context so the UI's in-memory objects and `@Query` results update immediately.
@MainActor
enum ProjectMaintenance {
    private static let logger = Logger(subsystem: "co.jservices.MultiScan", category: "ProjectMaintenance")

    /// Assigns missing `uuid`s and (re)derives stale `plainText` mirrors. Idempotent; runs after schema self-healing on every launch and is a no-op once all rows are current.
    /// - Returns: number of pages updated.
    @discardableResult
    static func backfillIdentityAndPlainText(context: ModelContext) async -> Int {
        let documents = (try? context.fetch(FetchDescriptor<Document>())) ?? []
        var updatedPages = 0
        var touched = false

        for document in documents {
            if document.uuid == nil {
                document.uuid = UUID()
                touched = true
            }

            let stalePages = document.unwrappedPages.filter { page in
                page.uuid == nil
                    || page.plainTextUpdatedAt == nil
                    || (page.plainTextUpdatedAt ?? .distantPast) < page.lastModified
            }
            guard !stalePages.isEmpty else { continue }

            // One cache decode per document supplies plain text for every page without external reads.
            var cachedText: [Int: String] = [:]
            if let data = document.textExportCache {
                let fingerprints = TextExportCacheService.fingerprints(of: document)
                let cache = await Task.detached(priority: .utility) { TextExportCacheService.decodeCache(from: data) }.value
                if let cache, TextExportCacheService.isFresh(cache, against: fingerprints) {
                    for entry in cache.pages { cachedText[entry.pageNumber] = entry.plainText }
                }
            }

            for page in stalePages {
                if page.uuid == nil { page.uuid = UUID() }
                page.plainText = cachedText[page.pageNumber] ?? RichTextArchiver.plainText(from: page.richTextData)
                page.plainTextUpdatedAt = page.lastModified
                updatedPages += 1
            }
            touched = true

            do {
                try context.save()
            } catch {
                logger.error("Backfill save failed for \(document.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            await Task.yield()
        }

        if touched {
            try? context.save()
            logger.info("Backfill complete: \(updatedPages) pages updated across \(documents.count) projects")
        }
        return updatedPages
    }

    /// Deletes projects by identity. Cascades to pages; Spotlight cleanup follows from the save notification.
    static func deleteProjects(uuids: [UUID], context: ModelContext) throws -> Int {
        var deleted: [UUID] = []
        for uuid in uuids {
            var descriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.uuid == uuid })
            descriptor.fetchLimit = 1
            if let document = try context.fetch(descriptor).first {
                context.delete(document)
                deleted.append(uuid)
            }
        }
        try context.save()
        deleteDonations(forProjects: deleted)
        return deleted.count
    }

    /// Drops donations that point at projects which no longer exist. Stale donations degrade
    /// prediction quality, and the system never prunes them on its own.
    nonisolated static func deleteDonations(forProjects uuids: [UUID]) {
        guard !uuids.isEmpty else { return }
        Task.detached(priority: .utility) {
            for uuid in uuids {
                let identifier = EntityIdentifier(for: ProjectEntity.self, identifier: uuid)
                _ = try? await IntentDonationManager.shared.deleteDonations(
                    matching: .entityIdentifier(identifier)
                )
            }
        }
    }

    /// Resolves a project for the UI (deep links / search results).
    static func document(uuid: UUID, context: ModelContext) -> Document? {
        var descriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.uuid == uuid })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}

// MARK: - String helpers

private extension String {
    /// Collapses runs of whitespace/newlines into single spaces (for one-line snippets).
    func collapsingWhitespace() -> String {
        split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}
