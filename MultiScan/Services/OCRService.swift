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
//  2. `VisionDocumentRecognizer` on the upright image → `VisionDocumentLayout` + transcript. **Always**, whatever the primary engine.
//  3. Smart Separate (if enabled): `PageSplitter` looks at the line geometry; a two-page spread is oriented, cropped into two HEIC images, and each half goes back through steps 2–4 as its own page (so each half gets its own Vision layout).
//  4. Primary text: Vision's transcript, or — with a transformer engine configured — the model's markdown via `MarkdownTranscriptConverter`. A transformer failure or timeout falls back to Vision's text and is recorded in `ocrEngine` as `vision(fallback: …)`.
//  5. Thumbnail (HEIC, 400 px).
//
//  Page numbers are assigned by `processImages` after each image returns, because a split image yields two pages.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os

/// Result type for processed images — one per *page* (a split spread yields two).
nonisolated struct ProcessedImage: Sendable {
    let pageNumber: Int
    /// Primary plain text (what `Page.plainText` mirrors; attachment placeholders already stripped).
    let text: String
    /// Pre-encoded RTF/RTFD when the primary engine produced formatting; `nil` means "encode `text` on the storage font".
    let richTextData: Data?
    let imageData: Data
    let thumbnailData: Data?
    let visionLayoutData: Data?
    let visionTranscript: String
    /// `OCREngineKind.provenanceIdentifier` of whatever produced `text`.
    let ocrEngine: String
    let originalFileName: String
    /// 0 = whole scan, 1/2 = first/second half of a split spread.
    let splitPosition: Int
}

/// OCR over a batch of images.
nonisolated enum OCRService {
    private static let logger = Logger(subsystem: "co.jservices.MultiScan", category: "OCRService")

    /// Process multiple images from Data
    /// - Parameters:
    ///   - images: Array of tuples containing image data and filename
    ///   - startingPageNumber: The page number to start from (default 1 for new documents)
    ///   - configuration: engine + Smart Separate settings, snapshotted by the caller at import start
    ///   - onProgress: Called on the caller's actor as each *input image* completes (0…1)
    /// - Returns: pages in order, numbered consecutively from `startingPageNumber`
    static func processImages(
        _ images: [(data: Data, fileName: String)],
        startingPageNumber: Int = 1,
        configuration: OCREngineConfiguration = .default,
        onProgress: (Double) -> Void
    ) async throws -> [ProcessedImage] {
        var results: [ProcessedImage] = []
        let imageCount = max(images.count, 1)
        let transcriber = ModelTranscriber.make(for: configuration)
        onProgress(0)

        for (index, image) in images.enumerated() {
            try Task.checkCancellation()

            let contents = try await processImageData(image.data, fileName: image.fileName, configuration: configuration, transcriber: transcriber)
            for content in contents {
                results.append(content.numbered(startingPageNumber + results.count))
            }

            onProgress(Double(index + 1) / Double(imageCount))
        }

        onProgress(1.0)
        return results
    }

    // MARK: - Per-image work

    /// A processed page before it knows its page number.
    private struct PageContent: Sendable {
        var text: String
        var richTextData: Data?
        var imageData: Data
        var thumbnailData: Data?
        var visionLayoutData: Data?
        var visionTranscript: String
        var ocrEngine: String
        var originalFileName: String
        var splitPosition: Int

        func numbered(_ pageNumber: Int) -> ProcessedImage {
            ProcessedImage(
                pageNumber: pageNumber,
                text: text,
                richTextData: richTextData,
                imageData: imageData,
                thumbnailData: thumbnailData,
                visionLayoutData: visionLayoutData,
                visionTranscript: visionTranscript,
                ocrEngine: ocrEngine,
                originalFileName: originalFileName,
                splitPosition: splitPosition
            )
        }
    }

    /// Process a single image from Data. `@concurrent` moves the decode, Vision, model, and thumbnail work onto the cooperative pool so the main actor stays free.
    @concurrent
    private static func processImageData(
        _ data: Data,
        fileName: String,
        configuration: OCREngineConfiguration,
        transcriber: (any PageTranscribing)?
    ) async throws -> [PageContent] {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            logger.error("Failed to load image: \(fileName, privacy: .public)")
            throw OCRError.imageLoadError
        }
        let orientation = VisionDocumentRecognizer.exifOrientation(of: imageSource)

        // 1. Vision, always.
        let layout = try await VisionDocumentRecognizer.recognize(cgImage, orientation: orientation)

        // 2. Smart Separate.
        if configuration.smartSeparateEnabled, case .split(let first, let second, _) = PageSplitter.decide(layout: layout) {
            if let halves = splitSpread(cgImage, orientation: orientation, first: first, second: second) {
                var pages: [PageContent] = []
                for (position, half) in halves.enumerated() {
                    // Each half gets its own Vision pass: the layout of a half is not a sub-rectangle of the spread's (paragraph grouping changes), and the export/cache expect per-page geometry.
                    let halfLayout = try await VisionDocumentRecognizer.recognize(half.image, orientation: .up)
                    let halfName = String(localized: "\(fileName) (\(position + 1) of 2)", comment: "File name shown for one half of a scan that Smart Separate split in two")
                    pages.append(try await content(
                        for: half.image,
                        orientation: .up,
                        imageData: half.data,
                        thumbnailSource: half.data,
                        fileName: halfName,
                        layout: halfLayout,
                        splitPosition: position + 1,
                        configuration: configuration,
                        transcriber: transcriber
                    ))
                }
                return pages
            }
            logger.warning("Smart Separate wanted to split \(fileName, privacy: .public) but cropping failed; keeping the whole scan")
        }

        // 3. Whole page.
        return [try await content(
            for: cgImage,
            orientation: orientation,
            imageData: data,
            thumbnailSource: data,
            fileName: fileName,
            layout: layout,
            splitPosition: 0,
            configuration: configuration,
            transcriber: transcriber
        )]
    }

    /// Builds one page's content from its (already recognized) layout, running the transformer when configured.
    private static func content(
        for cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        imageData: Data,
        thumbnailSource: Data,
        fileName: String,
        layout: VisionDocumentLayout,
        splitPosition: Int,
        configuration: OCREngineConfiguration,
        transcriber: (any PageTranscribing)?
    ) async throws -> PageContent {
        // Thumbnails are always HEIC at 400 px max dimension, 0.7 quality
        let thumbnailData = PlatformImage.thumbnailData(from: thumbnailSource, maxPixelSize: 400, as: .heic, quality: 0.7)
        let visionText = layout.transcript

        var text = visionText
        var richTextData: Data?
        var engine = OCREngineKind.vision.provenanceIdentifier(modelName: nil)

        if let transcriber, configuration.usesTransformer {
            do {
                let markdown = try await ModelTranscriber.withTimeout(configuration.transformerTimeout) {
                    try await transcriber.transcribe(cgImage, orientation: orientation, prompt: configuration.transcriptionPrompt)
                }
                let attributed = MarkdownTranscriptConverter.attributedString(fromMarkdown: markdown)
                if attributed.length > 0 {
                    richTextData = RichTextArchiver.richTextData(from: attributed)
                    text = InlineAttachments.searchablePlainText(of: attributed)
                    engine = configuration.kind.provenanceIdentifier(modelName: transcriber.modelName)
                } else {
                    // The model said the page is blank; trust Vision's read instead and note the disagreement.
                    engine = "vision(fallback: empty model output)"
                }
            } catch {
                logger.error("Transformer transcription failed for \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                engine = "vision(fallback: \(error.localizedDescription.prefix(80)))"
            }
        }

        return PageContent(
            text: text,
            richTextData: richTextData,
            imageData: imageData,
            thumbnailData: thumbnailData,
            visionLayoutData: layout.encoded(),
            visionTranscript: visionText,
            ocrEngine: engine,
            originalFileName: fileName,
            splitPosition: splitPosition
        )
    }

    // MARK: - Smart Separate cropping

    private struct Half: Sendable {
        let image: CGImage
        let data: Data
    }

    /// Orients the spread upright, crops both halves, and encodes them as HEIC (new images, like PDF renders).
    private static func splitSpread(_ cgImage: CGImage, orientation: CGImagePropertyOrientation, first: NormalizedBox, second: NormalizedBox) -> [Half]? {
        guard let upright = PlatformImage.oriented(cgImage, orientation) else { return nil }
        let size = CGSize(width: upright.width, height: upright.height)
        var halves: [Half] = []
        for box in [first, second] {
            let rect = box.pixelRect(in: size).integral.intersection(CGRect(origin: .zero, size: size))
            guard rect.width > 8, rect.height > 8,
                  let cropped = upright.cropping(to: rect),
                  let data = PlatformImage.encode(cropped, as: .heic, quality: 0.85) else { return nil }
            halves.append(Half(image: cropped, data: data))
        }
        return halves
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
