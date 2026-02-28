// OCRService may be useful for exaptation from MultiScan.
// Based on the version from MultiScan v1.x releases

import Foundation
import Vision
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
import os

/// Result type for processed images
struct ProcessedImage {
    let pageNumber: Int
    let text: String
    let imageData: Data
    let thumbnailData: Data?
    let boundingBoxesData: Data?
    let originalFileName: String
}

/// OCR service for processing images and extracting text.
/// MainActor-isolated because it manages @Published UI state (progress, status) observed by SwiftUI.
/// Heavy work (thumbnail generation, Vision OCR) is nonisolated to avoid blocking the main thread.
@MainActor
final class OCRService: ObservableObject {
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var currentFile: String = ""
    @Published var error: Error?

    /// Process multiple images from Data
    /// - Parameters:
    ///   - images: Array of tuples containing image data and filename
    ///   - startingPageNumber: The page number to start from (default 1 for new documents)
    /// - Returns: Array of ProcessedImage results
    func processImages(_ images: [(data: Data, fileName: String)], startingPageNumber: Int = 1) async throws -> [ProcessedImage] {
        isProcessing = true
        progress = 0
        currentFile = ""

        defer {
            isProcessing = false
            currentFile = ""
        }

        var results: [ProcessedImage] = []
        let imageCount = max(images.count, 1)

        for (index, image) in images.enumerated() {
            try Task.checkCancellation()

            currentFile = image.fileName
            progress = Double(index) / Double(imageCount)

            let processed = try await Task.detached(priority: .utility) {
                try await self.processImageData(image.data, fileName: image.fileName, pageNumber: startingPageNumber + index)
            }.value
            results.append(processed)

            progress = Double(index + 1) / Double(imageCount)
        }

        progress = 1.0
        currentFile = ""

        return results
    }

    /// Process a single image from Data (runs off MainActor to avoid blocking UI)
    private nonisolated func processImageData(_ data: Data, fileName: String, pageNumber: Int) async throws -> ProcessedImage {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            print("Failed to load image: \(fileName)")
            throw OCRError.imageLoadError
        }

        let thumbnailData = generateThumbnail(from: imageSource)
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

    private nonisolated func generateThumbnail(from imageSource: CGImageSource) -> Data? {
        let maxDimension: CGFloat = 400
        let options: [NSString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]

        guard let thumbnailImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else {
            return nil
        }

        let compressionOptions: [NSString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.7
        ]
        CGImageDestinationAddImage(destination, thumbnailImage, compressionOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return data as Data
    }

    private nonisolated func recognizeText(from cgImage: CGImage) async throws -> (text: String, boundingBoxes: [CGRect]) {
        return try await withCheckedThrowingContinuation { continuation in
            // Track whether continuation has been resumed to prevent double-resume crashes.
            // Vision can both throw from perform() AND call the completion handler with an error
            // for the same failure (e.g., CoreML neural network errors), which would crash.
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

enum OCRError: LocalizedError {
    case folderAccessError
    case imageLoadError
    case imageConversionError

    var errorDescription: String? {
        switch self {
        case .folderAccessError:
            return "Could not access the selected folder"
        case .imageLoadError:
            return "Could not load image file"
        case .imageConversionError:
            return "Could not convert image for processing"
        }
    }
}

// MARK: - Image Compression Utilities

extension OCRService {
    /// Compress image data to HEIC with specified quality
    /// - Parameters:
    ///   - data: Original image data
    ///   - quality: HEIC compression quality (0.0 to 1.0)
    /// - Returns: Compressed HEIC data, or nil if compression failed
    static func compressImageData(_ data: Data, quality: CGFloat = 0.8) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]

        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return mutableData as Data
    }
}
