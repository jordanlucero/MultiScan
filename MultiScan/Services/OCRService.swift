import Foundation
import Vision
import AppKit
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

        guard let image = NSImage(contentsOf: imageURL) else {
            print("Failed to load image: \(imageURL.lastPathComponent)")
            throw OCRError.imageLoadError
        }

        let thumbnailData = generateThumbnail(from: image)

        let (text, boundingBoxes) = try await recognizeText(from: image, imageURL: imageURL)

        let boundingBoxesData = try? JSONEncoder().encode(boundingBoxes)

        return (text, thumbnailData, boundingBoxesData)
    }
    
    private func generateThumbnail(from image: NSImage) -> Data? {
        let maxSize = NSSize(width: 150, height: 200)
        let imageSize = image.size
        
        let widthRatio = maxSize.width / imageSize.width
        let heightRatio = maxSize.height / imageSize.height
        let ratio = min(widthRatio, heightRatio)
        
        let newSize = NSSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
        
        let thumbnailImage = NSImage(size: newSize)
        thumbnailImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                  from: NSRect(origin: .zero, size: imageSize),
                  operation: .copy,
                  fraction: 1.0)
        thumbnailImage.unlockFocus()
        
        guard let tiffData = thumbnailImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
    
    private func recognizeText(from image: NSImage, imageURL: URL) async throws -> (text: String, boundingBoxes: [CGRect]) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("Failed to convert image to CGImage: \(imageURL.lastPathComponent)")
            throw OCRError.imageConversionError
        }

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
