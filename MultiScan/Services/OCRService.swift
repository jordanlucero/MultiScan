// OCRService may be useful for exaptation from MultiScan.
// Based on the version from MultiScan v2.x releases

import Foundation
import Vision
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os

/// Result type for processed images
nonisolated struct ProcessedImage: Sendable {
    let pageNumber: Int
    let text: String
    let imageData: Data
    let thumbnailData: Data?
    let boundingBoxesData: Data?
    let originalFileName: String
}

/// OCR over a batch of images. `processImages` runs on its caller (the import pipeline, on the main actor) so progress can update observable state directly; each image's decode, thumbnail, and Vision work is `@concurrent`, off the main actor.
nonisolated enum OCRService {
    /// Process multiple images from Data
    /// - Parameters:
    ///   - images: Array of tuples containing image data and filename
    ///   - startingPageNumber: The page number to start from (default 1 for new documents)
    ///   - onProgress: Called on the caller's actor as each page completes (0…1)
    /// - Returns: Array of ProcessedImage results
    static func processImages(
        _ images: [(data: Data, fileName: String)],
        startingPageNumber: Int = 1,
        onProgress: (Double) -> Void
    ) async throws -> [ProcessedImage] {
        var results: [ProcessedImage] = []
        let imageCount = max(images.count, 1)
        onProgress(0)

        for (index, image) in images.enumerated() {
            try Task.checkCancellation()

            let processed = try await processImageData(image.data, fileName: image.fileName, pageNumber: startingPageNumber + index)
            results.append(processed)

            onProgress(Double(index + 1) / Double(imageCount))
        }

        onProgress(1.0)
        return results
    }

    /// Process a single image from Data. `@concurrent` moves the decode, thumbnail, and Vision work onto the cooperative pool so the main actor stays free.
    @concurrent
    private static func processImageData(_ data: Data, fileName: String, pageNumber: Int) async throws -> ProcessedImage {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            print("Failed to load image: \(fileName)")
            throw OCRError.imageLoadError
        }

        // Thumbnails are always HEIC at 400 px max dimension, 0.7 quality
        let thumbnailData = PlatformImage.thumbnail(from: imageSource, maxPixelSize: 400)
            .flatMap { PlatformImage.encode($0, as: .heic, quality: 0.7) }
        let (text, boundingBoxes) = try await recognizeText(from: cgImage)
        let boundingBoxesData = try? JSONEncoder().encode(boundingBoxes)

        return ProcessedImage(
            pageNumber: pageNumber,
            text: text,
            imageData: data,
            thumbnailData: thumbnailData,
            boundingBoxesData: boundingBoxesData,
            originalFileName: fileName
        )
    }

    private static func recognizeText(from cgImage: CGImage) async throws -> (text: String, boundingBoxes: [CGRect]) {
        return try await withCheckedThrowingContinuation { continuation in
            // Track whether continuation has been resumed to prevent double-resume crashes.
            // Vision can both throw from perform() AND call the completion handler with an error for the same failure (e.g., CoreML neural network errors), which would crash.
            let resumed = OSAllocatedUnfairLock(initialState: false)

            let request = VNRecognizeTextRequest { request, error in
                guard resumed.withLock({ guard !$0 else { return false }; $0 = true; return true }) else { return }

                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: ("", []))
                    return
                }

                let recognizedText = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")

                let boundingBoxes = observations.map { $0.boundingBox }

                continuation.resume(returning: (recognizedText, boundingBoxes))
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

            do {
                try handler.perform([request])
            } catch {
                guard resumed.withLock({ guard !$0 else { return false }; $0 = true; return true }) else { return }
                continuation.resume(throwing: error)
            }
        }
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
