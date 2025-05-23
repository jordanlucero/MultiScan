import Foundation
import Vision
import AppKit
import SwiftUI

@MainActor
class OCRService: ObservableObject {
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var currentFile: String = ""
    @Published var error: Error?
    
    func processImagesInFolder(at url: URL, bookmarkData: Data?) async throws -> [(pageNumber: Int, text: String, fileName: String)] {
        isProcessing = true
        progress = 0
        defer { isProcessing = false }
        
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
        
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(resourceKeys)),
                  let isRegularFile = resourceValues.isRegularFile,
                  isRegularFile else { continue }
            
            let pathExtension = fileURL.pathExtension.lowercased()
            if ["jpg", "jpeg", "png", "tiff", "tif", "bmp", "heic"].contains(pathExtension) {
                imageURLs.append(fileURL)
            }
        }
        
        print("Found \(imageURLs.count) images in folder: \(url.path)")
        
        imageURLs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        
        var results: [(pageNumber: Int, text: String, fileName: String)] = []
        
        for (index, imageURL) in imageURLs.enumerated() {
            currentFile = imageURL.lastPathComponent
            progress = Double(index) / Double(imageURLs.count)
            
            let text = try await recognizeText(in: imageURL)
            results.append((pageNumber: index + 1, text: text, fileName: imageURL.lastPathComponent))
        }
        
        progress = 1.0
        return results
    }
    
    private func recognizeText(in imageURL: URL) async throws -> String {
        // Check if file exists before trying to load
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            print("File does not exist: \(imageURL.path)")
            throw OCRError.imageLoadError
        }
        
        guard let image = NSImage(contentsOf: imageURL) else {
            print("Failed to load image: \(imageURL.lastPathComponent)")
            throw OCRError.imageLoadError
        }
        
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
                    continuation.resume(returning: "")
                    return
                }
                
                let recognizedText = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                
                continuation.resume(returning: recognizedText)
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