//
//  OCRService.swift
//  MultiScan
//
//  OCR over a batch of images: decode → Vision (always) → optional Smart Separate → optional transformer transcription → thumbnails.
//
//  `processImages` runs on its caller (the import pipeline, on the main actor) so progress can update observable state directly; each image's work is `@concurrent`, off the main actor.
//
//  ## Pipeline per image
//  1. Decode the bitmap and read its EXIF orientation.
//  2. `VisionDocumentRecognizer` on the upright image → `VisionDocumentLayout` + transcript. **Always**, whatever the primary engine, and always on the pixels as imported — "Optimize images on import" re-encodes the copy that is *stored*, after recognition, so OCR never reads a recompressed image.
//  3. Smart Separate (if enabled): `PageSplitter` looks at the line geometry. A two-page scan becomes two pages that each show a **region** of the one stored scan (`ProcessedImage.crop` + `scanID` → `SharedScan` + `Page.imageCrop`); nothing is cropped on disk. Each region goes back through Vision as its own page, because a half's paragraph grouping is not a sub-rectangle of the spread's.
//  4. Primary text: Vision's transcript, or — with a transformer engine configured — the model's markdown via `MarkdownTranscriptConverter`. A transformer failure or timeout falls back to Vision's text and is recorded in `ocrEngine` as `vision(fallback: …)`.
//  5. Thumbnail (HEIC, 400 px) — of the region, for a separated page.
//
//  Page numbers are assigned by `processImages` after each image returns, because a separated scan yields two pages.
//
//  `recognize(_:configuration:transcriber:)` (steps 2 + 4 for one bitmap) is also what the after-import paths use: `PageSeparationService` for each new half, `PageRecognitionService` to read a page again.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os

/// What recognition produced for one page-sized bitmap.
nonisolated struct RecognizedPage: Sendable {
    /// Primary plain text (what `Page.plainText` mirrors; attachment placeholders already stripped).
    var text: String
    /// Pre-encoded RTF/RTFD when the primary engine produced formatting; `nil` means "encode `text` on the storage font".
    var richTextData: Data?
    var visionLayoutData: Data?
    var visionTranscript: String
    /// `OCREngineKind.provenanceIdentifier` of whatever produced `text`.
    var ocrEngine: String
}

/// Result type for processed images — one per *page* (a separated scan yields two).
nonisolated struct ProcessedImage: Sendable {
    let pageNumber: Int
    let recognized: RecognizedPage
    /// The scan's bytes as they should be stored. Both pages of a separated scan carry the same bytes and the same `scanID`; the pipeline stores them once.
    let imageData: Data
    let thumbnailData: Data?
    let originalFileName: String
    /// 0 = whole scan, 1/2 = first/second page of a separated scan.
    let splitPosition: Int
    /// The region of the scan this page shows (normalized, upper-left origin, EXIF-upright image). `nil` = the whole image.
    let crop: NormalizedBox?
    /// Identifies the scan when several pages share it; `nil` for a whole-scan page, which keeps the bytes itself.
    let scanID: UUID?
    /// The scan's own file name (the pages show it with a "(1 of 2)" suffix).
    let scanFileName: String

    var text: String { recognized.text }
}

/// OCR over a batch of images.
nonisolated enum OCRService {
    private static let logger = Logger(subsystem: "co.jservices.MultiScan", category: "OCRService")

    /// Process multiple images from Data
    /// - Parameters:
    ///   - images: Array of tuples containing image data and filename
    ///   - startingPageNumber: The page number to start from (default 1 for new documents)
    ///   - configuration: engine + Smart Separate settings, snapshotted by the caller at import start
    ///   - optimizeStoredImages: re-encode each scan as HEIC for storage ("Optimize images on import") — after recognition, and only when that is actually smaller
    ///   - onProgress: Called on the caller's actor as each *input image* completes (0…1)
    /// - Returns: pages in order, numbered consecutively from `startingPageNumber`
    static func processImages(
        _ images: [(data: Data, fileName: String)],
        startingPageNumber: Int = 1,
        configuration: OCREngineConfiguration = .default,
        optimizeStoredImages: Bool = false,
        onProgress: (Double) -> Void
    ) async throws -> [ProcessedImage] {
        var results: [ProcessedImage] = []
        let imageCount = max(images.count, 1)
        let transcriber = ModelTranscriber.make(for: configuration)
        onProgress(0)

        for (index, image) in images.enumerated() {
            try Task.checkCancellation()

            let contents = try await processImageData(
                image.data,
                fileName: image.fileName,
                configuration: configuration,
                optimizeStoredImage: optimizeStoredImages,
                transcriber: transcriber
            )
            for content in contents {
                results.append(content.numbered(startingPageNumber + results.count))
            }

            onProgress(Double(index + 1) / Double(imageCount))
        }

        onProgress(1.0)
        return results
    }

    // MARK: - Recognition (one bitmap)

    /// Reads one upright, page-sized bitmap: Vision for layout and transcript, then the transformer engine when one is configured. Never throws for the transformer — a failure falls back to Vision's text and says so in `ocrEngine`; only Vision failing fails the page.
    /// - Parameters:
    ///   - layout: pass a layout Vision already produced for exactly this bitmap to skip the Vision pass.
    ///   - rotation: the page's user rotation the bitmap already has applied (0 at import). Recorded in the layout so later readers know which way up its geometry is.
    static func recognize(
        _ image: CGImage,
        layout existingLayout: VisionDocumentLayout? = nil,
        rotation: Int = 0,
        fileName: String,
        configuration: OCREngineConfiguration,
        transcriber: (any PageTranscribing)?
    ) async throws -> RecognizedPage {
        var layout: VisionDocumentLayout
        if let existingLayout {
            layout = existingLayout
        } else {
            layout = try await VisionDocumentRecognizer.recognize(image, orientation: .up)
        }
        layout.recognizedAtRotation = rotation == 0 ? nil : rotation
        let visionText = layout.transcript

        var text = visionText
        var richTextData: Data?
        var engine = OCREngineKind.vision.provenanceIdentifier(modelName: nil)

        if let transcriber, configuration.usesTransformer {
            do {
                let markdown = try await ModelTranscriber.withTimeout(configuration.transformerTimeout) {
                    try await transcriber.transcribe(image, orientation: .up, prompt: configuration.transcriptionPrompt)
                }
                let attributed = MarkdownTranscriptConverter.attributedString(fromMarkdown: ModelTranscriber.cleanedTranscript(markdown))
                if attributed.length > 0 {
                    richTextData = RichTextArchiver.richTextData(from: attributed)
                    text = InlineAttachments.searchablePlainText(of: attributed)
                    engine = configuration.kind.provenanceIdentifier(modelName: transcriber.modelName)
                } else {
                    // The model said the page is blank; trust Vision's read instead and note the disagreement.
                    engine = "vision(fallback: empty model output)"
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.error("Transformer transcription failed for \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                engine = "vision(fallback: \(error.localizedDescription.prefix(80)))"
            }
        }

        return RecognizedPage(
            text: text,
            richTextData: richTextData,
            visionLayoutData: layout.encoded(),
            visionTranscript: visionText,
            ocrEngine: engine
        )
    }

    // MARK: - Per-image work

    /// A processed page before it knows its page number.
    private struct PageContent: Sendable {
        var recognized: RecognizedPage
        var imageData: Data
        var thumbnailData: Data?
        var originalFileName: String
        var splitPosition: Int
        var crop: NormalizedBox?
        var scanID: UUID?
        var scanFileName: String

        func numbered(_ pageNumber: Int) -> ProcessedImage {
            ProcessedImage(
                pageNumber: pageNumber,
                recognized: recognized,
                imageData: imageData,
                thumbnailData: thumbnailData,
                originalFileName: originalFileName,
                splitPosition: splitPosition,
                crop: crop,
                scanID: scanID,
                scanFileName: scanFileName
            )
        }
    }

    /// Process a single image from Data. `@concurrent` moves the decode, Vision, model, and thumbnail work onto the cooperative pool so the main actor stays free.
    @concurrent
    private static func processImageData(
        _ data: Data,
        fileName: String,
        configuration: OCREngineConfiguration,
        optimizeStoredImage: Bool,
        transcriber: (any PageTranscribing)?
    ) async throws -> [PageContent] {
        guard let decoded = PlatformImage.decodedImage(from: data),
              let upright = PlatformImage.oriented(decoded.image, decoded.orientation) else {
            logger.error("Failed to load image: \(fileName, privacy: .public)")
            throw OCRError.imageLoadError
        }

        // 1. Vision, always — on the pixels as imported.
        let layout = try await VisionDocumentRecognizer.recognize(upright, orientation: .up)

        // The copy that gets stored. Re-encoding keeps the EXIF orientation, so regions defined on the upright image stay valid.
        var storedData = data
        if optimizeStoredImage, let optimized = PlatformImage.heicReencoding(data), optimized.count < data.count {
            storedData = optimized
        }

        // 2. Smart Separate: two pages showing two regions of the one stored scan.
        if configuration.smartSeparateEnabled, case .split(let first, let second, _) = PageSplitter.decide(layout: layout) {
            let scanID = UUID()
            var pages: [PageContent] = []
            for (position, region) in [first, second].enumerated() {
                guard let half = PlatformImage.cropped(upright, to: region.cgRect) else {
                    pages.removeAll()
                    break
                }
                pages.append(PageContent(
                    recognized: try await recognize(half, fileName: fileName, configuration: configuration, transcriber: transcriber),
                    imageData: storedData,
                    thumbnailData: PlatformImage.thumbnailData(of: half, maxPixelSize: thumbnailMaxPixelSize, as: .heic, quality: 0.7),
                    originalFileName: separatedFileName(fileName, position: position + 1),
                    splitPosition: position + 1,
                    crop: region,
                    scanID: scanID,
                    scanFileName: fileName
                ))
            }
            if pages.count == 2 { return pages }
            logger.warning("Smart Separate wanted to split \(fileName, privacy: .public) but a region was too small to use; keeping the whole scan")
        }

        // 3. Whole page.
        return [PageContent(
            recognized: try await recognize(upright, layout: layout, fileName: fileName, configuration: configuration, transcriber: transcriber),
            // Thumbnails are always HEIC at 400 px max dimension, 0.7 quality
            imageData: storedData,
            thumbnailData: PlatformImage.thumbnailData(from: storedData, maxPixelSize: thumbnailMaxPixelSize, as: .heic, quality: 0.7),
            originalFileName: fileName,
            splitPosition: 0,
            crop: nil,
            scanID: nil,
            scanFileName: fileName
        )]
    }

    static let thumbnailMaxPixelSize = 400

    /// "scan.jpg (1 of 2)" — the file name shown for one page of a separated scan.
    static func separatedFileName(_ fileName: String, position: Int) -> String {
        String(localized: "\(fileName) (\(position) of 2)", comment: "File name shown for one half of a scan that Smart Separate split in two")
    }
}

nonisolated enum OCRError: LocalizedError {
    case imageLoadError

    var errorDescription: String? {
        switch self {
        case .imageLoadError:
            return String(localized: "Could not load image file")
        }
    }
}
