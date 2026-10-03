//
//  ProjectImportPipeline.swift
//  MultiScan
//
//  The one import path: files/folders/Photos → page images → OCR → project. Used by the Home screen, the review views (append/insert pages), the share extension hand-off, and the "Start New Project" App Intent, so every entry point shows the same progress card.
//
//  Main-actor isolated (the project default): it owns observable in-flight state and writes SwiftData models. The heavy stages are `@concurrent` (`scan`, `PDFImportService.renderPDF`, `OCRService` per-image work) and report back here.
//

import Foundation
import Observation
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

@Observable
final class ProjectImportPipeline {
    static let shared = ProjectImportPipeline()

    /// Images ready for OCR plus naming hints gathered while scanning the input.
    nonisolated struct PreparedImport: Sendable {
        let images: [(data: Data, fileName: String)]
        let suggestedName: String?
    }

    nonisolated enum ImportError: LocalizedError {
        case noImages

        var errorDescription: String? {
            switch self {
            case .noImages:
                return String(localized: "No images or pages were found.")
            }
        }
    }

    /// Projects whose OCR is still running (Home shows a progress card for these).
    private(set) var processingDocumentIDs: Set<PersistentIdentifier> = []

    /// OCR progress of the current import, 0…1.
    private(set) var progress: Double = 0

    /// Per-page progress callback for the active `createProject` call (App Intents `Progress`).
    private var pageProgressHandler: ((Double) -> Void)?

    private init() {}

    // MARK: Input preparation

    /// Scans files/folders, renders PDFs to page images, and returns everything ready for OCR.
    /// - Parameter onEstimate: Called with the expected page count *before* PDF rendering, so callers can announce/size progress immediately.
    func prepare(
        urls: [URL],
        optimizeImages: Bool,
        onEstimate: ((Int) -> Void)? = nil
    ) async throws -> PreparedImport {
        // Hold security-scoped access to the picked items for the whole scan + render, so PDFs inside a picked folder stay readable.
        let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { for url in accessed { url.stopAccessingSecurityScopedResource() } }

        let scanned = await Self.scan(urls, optimizeImages: optimizeImages)
        onEstimate?(scanned.images.count + scanned.pdfPageCount)

        var images = scanned.images
        for pdfURL in scanned.pdfURLs {
            images.append(contentsOf: try await PDFImportService.renderPDF(at: pdfURL))
        }

        return PreparedImport(images: images, suggestedName: scanned.suggestedName)
    }

    /// Loads Photos picker selections into image data (with the original filename when Photos provides one).
    func loadPhotos(_ items: [PhotosPickerItem], optimizeImages: Bool) async -> [(data: Data, fileName: String)] {
        var images: [(data: Data, fileName: String)] = []
        for (index, item) in items.enumerated() {
            guard let loaded = await Self.loadPhoto(item, index: index) else { continue }
            var data = loaded.data
            if optimizeImages, let compressed = await PlatformImage.heicReencodingInBackground(data) {
                data = compressed
            }
            images.append((data: data, fileName: loaded.fileName))
        }
        return images
    }

    /// Default project name when the input suggests none.
    static func defaultProjectName() -> String {
        String(localized: "Import \(Date().formatted(date: .abbreviated, time: .shortened))", comment: "Default project name; placeholder is the current date")
    }

    // MARK: Project creation

    /// Creates a project, runs OCR over `images`, and fills in the pages.
    /// The document is inserted immediately (so Home can show its progress card) and deleted again if OCR fails.
    /// - Returns: the new project's stable identity.
    @discardableResult
    func createProject(
        named name: String,
        images: [(data: Data, fileName: String)],
        onPageProgress: ((Double) -> Void)? = nil
    ) async throws -> UUID {
        guard !images.isEmpty else { throw ImportError.noImages }
        let context = AppModelContainer.shared.mainContext

        let document = Document(name: name, totalPages: 0)
        context.insert(document)
        try context.save()

        let documentID = document.persistentModelID
        processingDocumentIDs.insert(documentID)
        pageProgressHandler = onPageProgress
        progress = 0
        defer {
            processingDocumentIDs.remove(documentID)
            pageProgressHandler = nil
        }

        do {
            let results = try await runOCR(images, startingPageNumber: 1)
            document.totalPages = results.count
            insertPages(for: results, into: document)
            document.lastModified = Date()
            document.recalculateStorageSize()
            // Build the text export cache while page text is still in memory.
            TextExportCacheService.buildInitialCache(for: document, from: document.unwrappedPages)
            try context.save()
            MultiScanShortcuts.updateAppShortcutParameters()
            return document.uuid ?? UUID()
        } catch {
            context.delete(document)
            try? context.save()
            throw error
        }
    }

    // MARK: Adding pages to an existing project

    /// Outcome of an `addPages` call, so the caller can decide where to navigate.
    nonisolated struct AddPagesResult: Sendable {
        /// Page number of the first page added, or `nil` if OCR produced nothing.
        let firstNewPageNumber: Int?
        /// Whether the pages went on the end rather than being inserted mid-project.
        let isAppend: Bool
    }

    /// Runs OCR over `images` and adds the resulting pages to an existing project, shifting the page numbers after the insertion point and keeping the export cache in sync.
    /// - Parameter insertAfter: Page number to insert after — `nil` appends to the end, `0` inserts at the beginning. Inserting at a position is an iOS-only entry point.
    @discardableResult
    func addPages(
        to document: Document,
        images: [(data: Data, fileName: String)],
        insertAfter: Int? = nil,
        in context: ModelContext
    ) async throws -> AddPagesResult {
        let insertAfterNum = insertAfter ?? document.totalPages
        let insertStart = insertAfterNum + 1
        let isAppend = insertAfterNum >= document.totalPages

        let results = try await runOCR(images, startingPageNumber: insertStart)
        let newCount = results.count

        // Shift existing pages that come after the insertion point (no-op when appending)
        for page in document.unwrappedPages where page.pageNumber >= insertStart {
            page.pageNumber += newCount
        }

        let newPages = insertPages(for: results, into: document)
        document.totalPages += newCount
        document.recalculateStorageSize()

        // Update the export cache while the new page text is still in memory
        if isAppend {
            TextExportCacheService.addEntries(for: newPages, to: document)
        } else {
            // Page numbers shifted — update cache entries in memory (no external storage loads)
            TextExportCacheService.insertEntries(for: newPages, in: document, shiftingFrom: insertStart, by: newCount)
        }

        try context.save()

        return AddPagesResult(firstNewPageNumber: newPages.first?.pageNumber, isAppend: isAppend)
    }

    // MARK: Internals

    /// OCR with progress mirrored into `progress` (and the intent's per-page handler).
    private func runOCR(_ images: [(data: Data, fileName: String)], startingPageNumber: Int) async throws -> [ProcessedImage] {
        // Reset so a progress UI doesn't briefly show the previous import's final value
        progress = 0
        return try await OCRService.processImages(images, startingPageNumber: startingPageNumber) { fraction in
            progress = fraction
            pageProgressHandler?(fraction)
        }
    }

    /// Creates `Page` models for OCR results and attaches them to the document.
    @discardableResult
    private func insertPages(for results: [ProcessedImage], into document: Document) -> [Page] {
        results.map { result in
            let page = Page(
                pageNumber: result.pageNumber,
                text: result.text,
                imageData: result.imageData,
                originalFileName: result.originalFileName,
                boundingBoxesData: result.boundingBoxesData
            )
            page.thumbnailData = result.thumbnailData
            page.document = document
            document.pages?.append(page)
            return page
        }
    }

    // MARK: File scanning (off the main actor)

    /// What a scan of the picked URLs found: image bytes (already optimized if requested), PDFs to render, and a name hint.
    private nonisolated struct ScannedInput: Sendable {
        var images: [(data: Data, fileName: String)] = []
        var pdfURLs: [URL] = []
        var pdfPageCount = 0
        var suggestedName: String?
    }

    /// Walks files and folders, reading images and noting PDFs. Everything is sorted by filename; a single picked folder names the project.
    @concurrent
    private nonisolated static func scan(_ urls: [URL], optimizeImages: Bool) async -> ScannedInput {
        var result = ScannedInput()
        let fileManager = FileManager.default

        for url in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                guard let enumerator = fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.contentTypeKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                while let fileURL = enumerator.nextObject() as? URL {
                    collect(fileURL, optimizeImages: optimizeImages, into: &result)
                }
            } else {
                collect(url, optimizeImages: optimizeImages, into: &result)
            }
        }

        result.images.sort { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        result.pdfURLs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        if urls.count == 1, let only = urls.first {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: only.path, isDirectory: &isDirectory), isDirectory.boolValue {
                result.suggestedName = only.lastPathComponent
            }
        }
        return result
    }

    private nonisolated static func collect(_ url: URL, optimizeImages: Bool, into result: inout ScannedInput) {
        guard let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return }

        if contentType.conforms(to: .pdf) {
            result.pdfURLs.append(url)
            result.pdfPageCount += PDFImportService.pageCount(for: url)
            return
        }

        guard contentType.conforms(to: .image), let data = try? Data(contentsOf: url) else { return }
        let finalData = optimizeImages ? (PlatformImage.heicReencoding(data) ?? data) : data
        result.images.append((data: finalData, fileName: url.lastPathComponent))
    }

    // MARK: Photos

    /// Loads one picked photo, preferring the file representation (which carries the original filename).
    private static func loadPhoto(_ item: PhotosPickerItem, index: Int) async -> (data: Data, fileName: String)? {
        do {
            if let file = try await item.loadTransferable(type: PhotoFileTransferable.self) {
                return (data: file.data, fileName: file.fileName)
            }
        } catch {
            print("Failed to load file representation: \(error)")
        }

        // Fallback: raw data without a filename
        if let data = try? await item.loadTransferable(type: Data.self) {
            return (data: data, fileName: String(localized: "Photo \(index + 1)", comment: "Fallback filename for imported photo"))
        }
        return nil
    }
}

/// Loads a photo with its original filename.
private nonisolated struct PhotoFileTransferable: Transferable {
    let data: Data
    let fileName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let fileName = received.file.lastPathComponent
            let data = try Data(contentsOf: received.file)
            return PhotoFileTransferable(data: data, fileName: fileName)
        }
    }
}
