//
//  ProjectImportPipeline.swift
//  MultiScan
//
//  Shared import → OCR → project creation pipeline used by the Home screen and the "Start New Project" App Intent. Owns the in-flight state (which projects are still processing, overall progress) so an intent-driven import shows the same progress card as a manual one.
//

import Foundation
import Observation
import PhotosUI
import SwiftData
import SwiftUI

@MainActor
@Observable
final class ProjectImportPipeline {
    static let shared = ProjectImportPipeline()

    /// Images ready for OCR plus naming hints gathered while scanning the input.
    struct PreparedImport: Sendable {
        let images: [(data: Data, fileName: String)]
        let suggestedName: String?
        let estimatedPageCount: Int
    }

    enum ImportError: LocalizedError {
        case noImages

        var errorDescription: String? {
            switch self {
            case .noImages:
                return String(localized: "No images or PDF pages were found.")
            }
        }
    }

    private let ocrService = OCRService()
    private let importService = ImageImportService()

    /// Projects whose OCR is still running (Home shows a progress card for these).
    private(set) var processingDocumentIDs: Set<PersistentIdentifier> = []

    /// OCR progress of the current import, 0…1.
    private(set) var progress: Double = 0

    /// File currently being recognized.
    private(set) var currentFile: String = ""

    /// Per-page progress callback for the active `createProject` call (App Intents `Progress`).
    private var pageProgressHandler: (@MainActor (Double) -> Void)?

    private init() {
        ocrService.progressHandler = { [weak self] progress, file in
            self?.progress = progress
            self?.currentFile = file
            self?.pageProgressHandler?(progress)
        }
    }

    // MARK: Input preparation

    /// Scans files/folders, renders PDFs to page images, and returns everything ready for OCR.
    /// - Parameter onEstimate: Called with the expected page count *before* PDF rendering, so callers can announce/size progress immediately.
    func prepare(
        urls: [URL],
        optimizeImages: Bool,
        onEstimate: (@MainActor (Int) -> Void)? = nil
    ) async throws -> PreparedImport {
        let result = await importService.processFileURLs(urls, optimizeImages: optimizeImages)

        var estimatedPageCount = result.images.count
        for pdfURL in result.pdfURLs {
            let accessed = pdfURL.startAccessingSecurityScopedResource()
            estimatedPageCount += PDFImportService.pageCount(for: pdfURL)
            if accessed { pdfURL.stopAccessingSecurityScopedResource() }
        }
        onEstimate?(estimatedPageCount)

        var allImages = result.images
        if !result.pdfURLs.isEmpty {
            let pdfService = PDFImportService()
            for pdfURL in result.pdfURLs {
                let accessed = pdfURL.startAccessingSecurityScopedResource()
                defer { if accessed { pdfURL.stopAccessingSecurityScopedResource() } }
                allImages.append(contentsOf: try await pdfService.renderPDF(at: pdfURL))
            }
        }

        return PreparedImport(images: allImages, suggestedName: result.suggestedName, estimatedPageCount: estimatedPageCount)
    }

    /// Loads Photos picker selections into image data.
    func loadPhotos(_ items: [PhotosPickerItem], optimizeImages: Bool) async -> [(data: Data, fileName: String)] {
        await importService.processSelectedPhotos(items, optimizeImages: optimizeImages)
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
        onPageProgress: (@MainActor (Double) -> Void)? = nil
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
            let results = try await ocrService.processImages(images)
            populate(document, with: results)
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
    struct AddPagesResult: Sendable {
        /// Page number of the first page added, or `nil` if OCR produced nothing.
        let firstNewPageNumber: Int?
        /// Whether the pages went on the end rather than being inserted mid-project.
        let isAppend: Bool
        let addedCount: Int
    }

    /// Runs OCR over `images` and adds the resulting pages to an existing project, shifting the page numbers after the insertion point and keeping the export cache in sync.
    ///
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

        // Reset so a progress UI doesn't briefly show the previous import's final value
        progress = 0
        let results = try await ocrService.processImages(images, startingPageNumber: insertStart)
        let newCount = results.count

        // Shift existing pages that come after the insertion point (no-op when appending)
        for page in document.unwrappedPages where page.pageNumber >= insertStart {
            page.pageNumber += newCount
        }

        var newPages: [Page] = []
        for result in results {
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
            newPages.append(page)
        }

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

        return AddPagesResult(
            firstNewPageNumber: newPages.first?.pageNumber,
            isAppend: isAppend,
            addedCount: newCount
        )
    }

    private func populate(_ document: Document, with results: [ProcessedImage]) {
        document.totalPages = results.count
        for result in results {
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
        }
        document.lastModified = Date()
        document.recalculateStorageSize()
        // Build the text export cache while page text is still in memory.
        TextExportCacheService.buildInitialCache(for: document, from: document.unwrappedPages)
    }
}
