import Foundation
import Vision
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SwiftUI

final class OCRService: ObservableObject, @unchecked Sendable {
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var currentFile: String = ""
    @Published var error: Error?
    
    func processImagesInFolder(at url: URL, bookmarkData: Data?) async throws -> [(pageNumber: Int, text: String, fileName: String, thumbnailData: Data?, boundingBoxesData: Data?)] {
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
        
        // Only start accessing if we're using a bookmark
        var accessed = false
        if bookmarkData != nil {
            accessed = url.startAccessingSecurityScopedResource()
        }
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .nameKey]
        
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: resourceKeys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw OCRError.folderAccessError
        }
        
        var imageURLs: [URL] = []
        
        while let fileURL = enumerator.nextObject() as? URL {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(resourceKeys)),
                  let isRegularFile = resourceValues.isRegularFile,
                  isRegularFile else { continue }
            
            let pathExtension = fileURL.pathExtension.lowercased()
            if ["jpg", "jpeg", "png", "tiff", "tif", "bmp", "heic"].contains(pathExtension) {
                imageURLs.append(fileURL)
            }
        }
        
        print("Found \(imageURLs.count) images in folder: \(url.path)")
        
        imageURLs.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        var results: [(pageNumber: Int, text: String, fileName: String, thumbnailData: Data?, boundingBoxesData: Data?)] = []
        let imageCount = max(imageURLs.count, 1)

        for (index, imageURL) in imageURLs.enumerated() {
            try Task.checkCancellation()
            
            let relativePath = imageURL.path.replacingOccurrences(of: url.path + "/", with: "")
            
            await MainActor.run {
                self.currentFile = relativePath
                self.progress = Double(index) / Double(imageCount)
            }
            
            let (text, thumbnailData, boundingBoxesData) = try await processImage(at: imageURL)
            
            results.append((pageNumber: index + 1, text: text, fileName: relativePath, thumbnailData: thumbnailData, boundingBoxesData: boundingBoxesData))
            
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
    
    private func processImage(at imageURL: URL) async throws -> (text: String, thumbnailData: Data?, boundingBoxesData: Data?) {
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            print("File does not exist: \(imageURL.path)")
            throw OCRError.imageLoadError
        }

        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            print("Failed to load image: \(imageURL.lastPathComponent)")
            throw OCRError.imageLoadError
        }

        let thumbnailData = generateThumbnail(from: imageSource)

        let (text, boundingBoxes) = try await recognizeText(from: cgImage, imageURL: imageURL)

        let boundingBoxesData = try? JSONEncoder().encode(boundingBoxes)

        return (text, thumbnailData, boundingBoxesData)
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
        let typeIdentifier = UTType.jpeg.identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, typeIdentifier, 1, nil) else {
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
    
    private func recognizeText(from cgImage: CGImage, imageURL: URL) async throws -> (text: String, boundingBoxes: [CGRect]) {
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
