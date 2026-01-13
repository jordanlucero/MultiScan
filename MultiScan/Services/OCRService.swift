// OCRService may be useful for exaptation from MultiScan.
// Based on the version from MultiScan v1.x releases

import Foundation
import Vision
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SwiftUI

/// Result type for processed images
struct ProcessedImage {
    let pageNumber: Int
    let text: String
    let imageData: Data
    let thumbnailData: Data?
    let boundingBoxesData: Data?
    let originalFileName: String
}

final class OCRService: ObservableObject, @unchecked Sendable {
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
        await MainActor.run {
            isProcessing = true
            progress = 0
            currentFile = ""
        }
        defer {
            Task { @MainActor in
                self.isProcessing = false
                self.currentFile = ""
            }
        }

        var results: [ProcessedImage] = []
        let imageCount = max(images.count, 1)

        for (index, image) in images.enumerated() {
            try Task.checkCancellation()

            await MainActor.run {
                self.currentFile = image.fileName
                self.progress = Double(index) / Double(imageCount)
            }

            let processed = try await processImageData(image.data, fileName: image.fileName, pageNumber: startingPageNumber + index)
            results.append(processed)

            await MainActor.run {
                self.progress = Double(index + 1) / Double(imageCount)
            }
        }

        await MainActor.run {
            self.progress = 1.0
            self.currentFile = ""
        }

        return results
    }

    /// Process a single image from Data
    private func processImageData(_ data: Data, fileName: String, pageNumber: Int) async throws -> ProcessedImage {
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

    private func generateThumbnail(from imageSource: CGImageSource) -> Data? {
        let maxDimension: CGFloat = 200
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

    private func recognizeText(from cgImage: CGImage) async throws -> (text: String, boundingBoxes: [CGRect]) {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
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
