//
//  PageSeparationService.swift
//  MultiScan
//
//  Smart Separate *after* import, its inverse, and reading a page's text again.
//
//  ## Separating
//  `candidate(for:)` decides whether a page shows two facing pages, using the Vision layout stored at import when it still describes what the user sees, and reading the image again otherwise (pages imported before layouts were stored, or turned by the user since). `separate(_:in:context:)` then makes it two pages:
//  - the scan's bytes move from `Page.imageData` to a new `SharedScan`, once;
//  - the existing page becomes the first page (it keeps its identity — uuid, chapter mark, numbering anchor, Spotlight entry) and a new page is inserted right after it; each records the region it shows (`Page.imageCrop`);
//  - **each half is recognized again and its text replaced** — a spread's text interleaves two pages, there is no way to divide an edited transcript — which is why callers confirm first when a page was edited or reviewed;
//  - artwork captures stay with the half they were cut from, their rectangles re-expressed in that half, and their inline references are appended to the new text so nothing is orphaned.
//
//  ## Rejoining
//  `rejoin(_:navigationState:context:)` puts the scan back on one page. Nothing is recognized again: the pages' texts are joined in order, so every edit survives. The stored Vision layout is dropped (it described a half) and is regenerated the next time something needs it.
//
//  ## Coordinates
//  The cut is found on the image *as displayed* (EXIF + the user's rotation), because a spread the user turned upright by hand has to be read upright. It is stored on the upright image (before rotation), where `Page.imageCrop` lives. `NormalizedGeometry` converts.
//
//  Main-actor isolated (the project default): it writes models. Decoding, Vision, and the transformer run in `@concurrent` helpers on `Sendable` snapshots.
//

import Foundation
import SwiftData
import CoreGraphics

/// A page that Smart Separate would split, and where.
nonisolated struct SeparationCandidate: Sendable, Identifiable {
    let pageID: PersistentIdentifier
    let pageNumber: Int
    /// The two regions, first (left) page first — normalized, upper-left origin, in the image **as displayed** (after the page's rotation).
    let first: NormalizedBox
    let second: NormalizedBox
    /// The page's text was edited, or the page was marked reviewed: separating replaces that work.
    let wasEditedOrReviewed: Bool

    var id: PersistentIdentifier { pageID }
}

nonisolated enum PageSeparationError: LocalizedError {
    case pageUnavailable
    case imageUnavailable
    case regionTooSmall

    var errorDescription: String? {
        switch self {
        case .pageUnavailable: String(localized: "The page is no longer part of this project.")
        case .imageUnavailable: String(localized: "The page's image isn't available on this device yet.")
        case .regionTooSmall: String(localized: "One of the two pages would be too small to use.")
        }
    }
}

enum PageSeparationService {

    // MARK: - Finding two-page scans

    /// Whether Smart Separate can consider this page at all: a whole scan, not already one half of one.
    static func canSeparate(_ page: Page) -> Bool {
        page.splitPosition == 0 && !page.isSeparated
    }

    /// The split Smart Separate would make of `page`, or `nil` when the page doesn't show two facing pages (or can't be read).
    static func candidate(for page: Page) async -> SeparationCandidate? {
        guard canSeparate(page) else { return nil }
        let rotation = page.rotation

        let decision: PageSplitter.Decision
        if let layout = page.visionLayout, (layout.recognizedAtRotation ?? 0) == rotation {
            // The stored layout describes the image the way it is displayed: no need to read it again.
            decision = PageSplitter.decide(layout: layout)
        } else {
            guard let source = page.imageSource else { return nil }
            decision = await decide(source: source, rotation: rotation)
        }

        guard case .split(let first, let second, _) = decision else { return nil }
        return SeparationCandidate(
            pageID: page.persistentModelID,
            pageNumber: page.pageNumber,
            first: first,
            second: second,
            wasEditedOrReviewed: page.hasBeenEditedOrReviewed
        )
    }

    /// A plain left/right split down the middle, for when the user knows a scan is a spread but the text geometry doesn't show a gutter (a page of illustrations, text running into the fold).
    static func middleSplit(for page: Page) -> SeparationCandidate? {
        guard canSeparate(page) else { return nil }
        return SeparationCandidate(
            pageID: page.persistentModelID,
            pageNumber: page.pageNumber,
            first: NormalizedBox(x: 0, y: 0, width: 0.5, height: 1),
            second: NormalizedBox(x: 0.5, y: 0, width: 0.5, height: 1),
            wasEditedOrReviewed: page.hasBeenEditedOrReviewed
        )
    }

    @concurrent
    private nonisolated static func decide(source: PageImageSource, rotation: Int) async -> PageSplitter.Decision {
        guard let image = PlatformImage.recognitionImage(from: source, userRotation: rotation),
              let layout = try? await VisionDocumentRecognizer.recognize(image, orientation: .up) else { return .keep }
        return PageSplitter.decide(layout: layout)
    }

    // MARK: - Separating

    /// One recognized half, ready to become a page.
    private nonisolated struct Half: Sendable {
        /// Region of the upright scan (what `Page.imageCrop` stores).
        let uprightRegion: CGRect
        /// The same region on the image as displayed (what captures are expressed in).
        let displayRegion: CGRect
        let recognized: RecognizedPage
        let thumbnailData: Data?
    }

    /// Splits the candidate's page in two. Returns the new second page.
    /// - Important: replaces the page's text with a fresh reading of each half. Confirm with the user first when `candidate.wasEditedOrReviewed`.
    @discardableResult
    static func separate(_ candidate: SeparationCandidate, in document: Document, context: ModelContext) async throws -> Page {
        guard let page = document.unwrappedPages.first(where: { $0.persistentModelID == candidate.pageID }), canSeparate(page) else {
            throw PageSeparationError.pageUnavailable
        }
        guard let source = page.imageSource else { throw PageSeparationError.imageUnavailable }

        let rotation = page.rotation
        let baseFileName = page.originalFileName ?? page.title
        let halves = try await recognizeHalves(
            source: source,
            rotation: rotation,
            displayRegions: [candidate.first.cgRect, candidate.second.cgRect],
            fileName: baseFileName,
            configuration: OCREngineSettings.shared.configuration
        )

        // The page may have gone away while its halves were being read.
        guard page.modelContext != nil, canSeparate(page), halves.count == 2 else { throw PageSeparationError.pageUnavailable }

        // The scan's bytes move to a record both pages share.
        let scan = SharedScan(imageData: page.sourceImageData, originalFileName: page.originalFileName, document: document)
        context.insert(scan)
        document.sharedScans?.append(scan)
        page.imageData = nil

        // Make room right after the page, then create its facing page.
        let firstNumber = page.pageNumber
        for other in document.unwrappedPages where other.pageNumber > firstNumber {
            other.pageNumber += 1
        }
        let second = Page(pageNumber: firstNumber + 1, text: "", imageData: nil)
        second.rotation = rotation
        second.increaseContrast = page.increaseContrast
        second.increaseBlackPoint = page.increaseBlackPoint
        second.document = document
        document.pages?.append(second)
        document.totalPages += 1

        // Captures follow the half they were cut from.
        var captures: [[PageCapture]] = [[], []]
        for capture in page.unwrappedCaptures {
            let rect = capture.normalizedRect
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let index = nearestRegion(to: center, among: halves.map(\.displayRegion))
            capture.normalizedRect = NormalizedGeometry.clampedToUnit(NormalizedGeometry.relative(rect, to: halves[index].displayRegion))
            captures[index].append(capture)
        }
        for capture in captures[1] {
            page.captures?.removeAll { $0.persistentModelID == capture.persistentModelID }
            capture.page = second
            second.captures?.append(capture)
        }

        for (index, target) in [page, second].enumerated() {
            let half = halves[index]
            target.sharedScan = scan
            target.imageCrop = half.uprightRegion
            target.splitPosition = index + 1
            target.thumbnailData = half.thumbnailData
            target.originalFileName = OCRService.separatedFileName(baseFileName, position: index + 1)
            target.isDone = false
            PageRecognitionService.apply(half.recognized, to: target, keeping: captures[index])
        }

        // Export cache: the first page's entry is replaced, later entries shift, the second page's entry is added.
        TextExportCacheService.replaceEntry(for: page, in: document)
        TextExportCacheService.insertEntries(for: [second], in: document, shiftingFrom: second.pageNumber, by: 1)

        document.lastModified = Date()
        document.recalculateStorageSize()
        try context.save()
        return second
    }

    /// Index of the region containing `point`, or failing that the one whose center is closest (a capture in the gutter margin still has to go somewhere).
    nonisolated static func nearestRegion(to point: CGPoint, among regions: [CGRect]) -> Int {
        if let containing = regions.firstIndex(where: { $0.contains(point) }) { return containing }
        func distance(_ region: CGRect) -> CGFloat { hypot(region.midX - point.x, region.midY - point.y) }
        return regions.indices.min { distance(regions[$0]) < distance(regions[$1]) } ?? 0
    }

    @concurrent
    private nonisolated static func recognizeHalves(
        source: PageImageSource,
        rotation: Int,
        displayRegions: [CGRect],
        fileName: String,
        configuration: OCREngineConfiguration
    ) async throws -> [Half] {
        // The upright scan (plus the page's own crop, if it ever has one); halves are cut from it so their thumbnails match what the viewer will show.
        guard let upright = PlatformImage.recognitionImage(from: source, userRotation: 0) else {
            throw PageSeparationError.imageUnavailable
        }
        let transcriber = ModelTranscriber.make(for: configuration)
        var halves: [Half] = []
        for displayRegion in displayRegions {
            try Task.checkCancellation()
            let uprightRegion = NormalizedGeometry.clampedToUnit(NormalizedGeometry.unrotated(displayRegion, clockwise: rotation))
            guard let cut = PlatformImage.cropped(upright, to: uprightRegion),
                  let displayed = PlatformImage.rotated(cut, clockwise: rotation) else {
                throw PageSeparationError.regionTooSmall
            }
            let recognized = try await OCRService.recognize(displayed, rotation: rotation, fileName: fileName, configuration: configuration, transcriber: transcriber)
            halves.append(Half(
                uprightRegion: uprightRegion,
                displayRegion: displayRegion,
                recognized: recognized,
                thumbnailData: PlatformImage.thumbnailData(of: cut, maxPixelSize: OCRService.thumbnailMaxPixelSize, as: .heic, quality: 0.7)
            ))
        }
        return halves
    }

    // MARK: - Rejoining

    /// Puts a separated scan back on one page: the first page of the pair survives (at its place in the project) with the whole image and the pages' texts joined in order; the other page is removed. Returns the surviving page.
    @discardableResult
    static func rejoin(_ page: Page, navigationState: NavigationState, context: ModelContext) async throws -> Page {
        guard let scan = page.sharedScan, let document = page.document else { throw PageSeparationError.pageUnavailable }
        guard let imageData = scan.imageData else { throw PageSeparationError.imageUnavailable }

        let halves = scan.unwrappedPages.sorted {
            $0.splitPosition != $1.splitPosition ? $0.splitPosition < $1.splitPosition : $0.pageNumber < $1.pageNumber
        }
        guard let survivor = halves.first else { throw PageSeparationError.pageUnavailable }
        let others = Array(halves.dropFirst())
        let thumbnailData = await thumbnail(of: imageData)

        // Text: every half's text, in order. Inline capture references travel inside it.
        let font = PageTextStyle.storageFont
        let combined = NSMutableAttributedString()
        for half in halves {
            let text = half.attributedText
            guard text.length > 0 else { continue }
            if combined.length > 0, !combined.string.hasSuffix("\n") {
                combined.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
            combined.append(text)
        }
        let transcripts = halves.compactMap(\.visionTranscript).filter { !$0.isEmpty }

        // Captures: back into the whole scan's coordinates, as displayed with the surviving page's rotation.
        for half in halves {
            let region = half.imageCrop ?? NormalizedGeometry.unit
            for capture in half.unwrappedCaptures {
                let uprightInHalf = NormalizedGeometry.unrotated(capture.normalizedRect, clockwise: half.rotation)
                let uprightInScan = NormalizedGeometry.absolute(uprightInHalf, in: region)
                capture.normalizedRect = NormalizedGeometry.clampedToUnit(NormalizedGeometry.rotated(uprightInScan, clockwise: survivor.rotation))
                if half !== survivor {
                    half.captures?.removeAll { $0.persistentModelID == capture.persistentModelID }
                    capture.page = survivor
                    survivor.captures?.append(capture)
                }
            }
        }

        // What the removed pages carried moves to the survivor where it has room: a chapter mark, a printed-numbering anchor.
        for other in others {
            if survivor.sectionTitle == nil, let title = other.sectionTitle {
                survivor.sectionTitle = title
                survivor.sectionTitleIsAutomatic = other.sectionTitleIsAutomatic
            }
            if let removed = other.uuid, let plan = document.printedNumbering {
                let updated = plan.reanchoring(deleted: removed, to: survivor.uuid)
                document.printedNumbering = updated.ranges.isEmpty ? nil : updated
            }
        }
        let allReviewed = halves.allSatisfy(\.isDone)

        // The survivor takes the scan back before the other pages go, so the scan is never without a reader's copy.
        survivor.imageData = imageData
        survivor.sharedScan = nil
        scan.pages?.removeAll { $0.persistentModelID == survivor.persistentModelID }
        survivor.imageCrop = nil
        survivor.splitPosition = 0
        survivor.originalFileName = scan.originalFileName ?? survivor.originalFileName
        survivor.thumbnailData = thumbnailData ?? survivor.thumbnailData
        survivor.visionLayoutData = nil
        survivor.visionTranscript = transcripts.isEmpty ? nil : transcripts.joined(separator: "\n")
        survivor.isDone = allReviewed
        survivor.attributedText = NSAttributedString(attributedString: combined)

        let survivorID = survivor.persistentModelID
        let currentID = navigationState.currentPage?.persistentModelID
        for other in others {
            // `deletePage` renumbers, syncs the cache, and deletes the scan once its last reader is gone.
            navigationState.deletePage(other, modelContext: context)
        }
        if scan.modelContext != nil, !scan.isDeleted {
            document.sharedScans?.removeAll { $0.persistentModelID == scan.persistentModelID }
            context.delete(scan)
        }

        TextExportCacheService.replaceEntry(for: survivor, in: document)
        document.lastModified = Date()
        document.recalculateStorageSize()
        try context.save()

        navigationState.refreshPageOrder()
        // If the viewer was on a page that just went away, show the rejoined page.
        let stillThere = document.unwrappedPages.contains { $0.persistentModelID == currentID }
        navigationState.reselectPage(withID: stillThere ? currentID : survivorID)
        return survivor
    }

    @concurrent
    private nonisolated static func thumbnail(of imageData: Data) async -> Data? {
        PlatformImage.thumbnailData(from: imageData, maxPixelSize: OCRService.thumbnailMaxPixelSize, as: .heic, quality: 0.7)
    }
}

// MARK: - Reading a page again

/// Replaces a page's text with a new reading of its image — after the user turned a sideways scan, to try the configured model on one page, or to go back to Apple Vision's text.
enum PageRecognitionService {

    /// Reads `page` again with the configured engine (Vision always runs too, refreshing the stored layout) and replaces its text. The page is read the way it is displayed: its region of the scan, turned by its rotation.
    static func recognizeAgain(_ page: Page, configuration: OCREngineConfiguration = OCREngineSettings.shared.configuration) async throws {
        guard let source = page.imageSource else { throw PageSeparationError.imageUnavailable }
        let recognized = try await read(source: source, rotation: page.rotation, fileName: page.originalFileName ?? page.title, configuration: configuration)
        guard page.modelContext != nil else { throw PageSeparationError.pageUnavailable }
        commit(recognized, to: page)
    }

    /// Puts Apple Vision's transcript back as the page's text. Uses the transcript stored at import when there is one (instant); otherwise reads the image with Vision.
    static func restoreVisionText(_ page: Page) async throws {
        if let transcript = page.visionTranscript {
            commit(RecognizedPage(
                text: transcript,
                richTextData: nil,
                visionLayoutData: page.visionLayoutData,
                visionTranscript: transcript,
                ocrEngine: OCREngineKind.vision.provenanceIdentifier(modelName: nil)
            ), to: page)
        } else {
            var visionOnly = OCREngineConfiguration.default
            visionOnly.kind = .vision
            try await recognizeAgain(page, configuration: visionOnly)
        }
    }

    /// Whether the page's text came from something other than Apple Vision (so "Restore Apple Vision Text" has something to restore).
    static func textCameFromModel(_ page: Page) -> Bool {
        guard let engine = page.ocrEngine else { return false }
        return !engine.hasPrefix("vision")
    }

    @concurrent
    private nonisolated static func read(source: PageImageSource, rotation: Int, fileName: String, configuration: OCREngineConfiguration) async throws -> RecognizedPage {
        guard let image = PlatformImage.recognitionImage(from: source, userRotation: rotation) else {
            throw PageSeparationError.imageUnavailable
        }
        return try await OCRService.recognize(image, rotation: rotation, fileName: fileName, configuration: configuration, transcriber: ModelTranscriber.make(for: configuration))
    }

    private static func commit(_ recognized: RecognizedPage, to page: Page) {
        apply(recognized, to: page, keeping: page.unwrappedCaptures)
        page.isDone = false
        if let document = page.document {
            TextExportCacheService.replaceEntry(for: page, in: document)
            document.lastModified = Date()
        }
        try? page.modelContext?.save()
    }

    /// Writes a reading into `page`: text (with the inline references of `captures` appended, so the page's illustrations aren't orphaned by the rewrite), Vision layout and transcript, and engine provenance. Does not touch the export cache.
    static func apply(_ recognized: RecognizedPage, to page: Page, keeping captures: [PageCapture]) {
        let font = PageTextStyle.storageFont
        let text = NSMutableAttributedString(attributedString: recognized.richTextData.map { RichTextArchiver.attributedString(from: $0) }
            ?? NSAttributedString(string: recognized.text, attributes: [.font: font]))
        for capture in captures.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard let id = capture.uuid else { continue }
            if text.length > 0, !text.string.hasSuffix("\n") {
                text.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
            text.append(InlineAttachments.attributedString(for: InlineAttachments.makeCaptureAttachment(captureID: id), font: font))
        }
        page.attributedText = NSAttributedString(attributedString: text)
        page.visionLayoutData = recognized.visionLayoutData
        page.visionTranscript = recognized.visionTranscript
        page.ocrEngine = recognized.ocrEngine
    }
}
