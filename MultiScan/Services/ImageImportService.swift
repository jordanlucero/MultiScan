// ImageImportService may be useful for exaptation from MultiScan.
// Based on the version from MultiScan v1.x releases

import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Service for importing images from files and Photos library
@MainActor
final class ImageImportService {

    /// Result of processing file URLs
    struct ImportResult {
        let images: [(data: Data, fileName: String)]
        let pdfURLs: [URL]
        let suggestedName: String?
    }

    /// Internal type to distinguish between images and PDFs during processing
    private enum ImportItem {
        case image(data: Data, fileName: String)
        case pdf(url: URL)
    }

    // MARK: - File URL Processing

    /// Process file URLs (files or folders) into image data and PDF URLs
    /// - Parameters:
    ///   - urls: File URLs to process
    ///   - optimizeImages: Whether to compress images during import
    /// - Returns: Array of image data with filenames, PDF URLs, and suggested document name
    func processFileURLs(
        _ urls: [URL],
        optimizeImages: Bool
    ) async -> ImportResult {
        var images: [(data: Data, fileName: String)] = []
        var pdfURLs: [URL] = []

        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }

            if isDirectory.boolValue {
                let items = processDirectory(url, optimizeImages: optimizeImages)
                for item in items {
                    switch item {
                    case .image(let data, let fileName):
                        images.append((data: data, fileName: fileName))
                    case .pdf(let pdfURL):
                        pdfURLs.append(pdfURL)
                    }
                }
            } else {
                if let item = processSingleFile(url, optimizeImages: optimizeImages) {
                    switch item {
                    case .image(let data, let fileName):
                        images.append((data: data, fileName: fileName))
                    case .pdf(let pdfURL):
                        pdfURLs.append(pdfURL)
                    }
                }
            }
        }

        // Sort images by filename
        images.sort { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }

        // Sort PDFs by filename
        pdfURLs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        // Generate suggested document name
        let suggestedName = generateDocumentName(from: urls)

        return ImportResult(images: images, pdfURLs: pdfURLs, suggestedName: suggestedName)
    }

    private func processDirectory(_ url: URL, optimizeImages: Bool) -> [ImportItem] {
        var items: [ImportItem] = []

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.contentTypeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return items
        }

        while let fileURL = enumerator.nextObject() as? URL {
            if let item = processSingleFile(fileURL, optimizeImages: optimizeImages) {
                items.append(item)
            }
        }

        return items
    }

    private func processSingleFile(_ url: URL, optimizeImages: Bool) -> ImportItem? {
        guard let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return nil
        }

        // Check for PDF first
        if contentType.conforms(to: .pdf) {
            return .pdf(url: url)
        }

        // Handle images
        guard contentType.conforms(to: .image),
              let data = try? Data(contentsOf: url) else {
            return nil
        }

        let finalData = optimizeImages ? (OCRService.compressImageData(data) ?? data) : data
        return .image(data: finalData, fileName: url.lastPathComponent)
    }

    private func generateDocumentName(from urls: [URL]) -> String? {
        guard urls.count == 1, let firstURL = urls.first else {
            return nil // Will use date-based name
        }

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: firstURL.path, isDirectory: &isDir)

        return isDir.boolValue ? firstURL.lastPathComponent : nil
    }

    // MARK: - Photos Processing

    /// Process photos from PhotosPicker
    /// - Parameters:
    ///   - items: PhotosPickerItem array
    ///   - optimizeImages: Whether to compress images during import
    /// - Returns: Array of image data with filenames
    func processSelectedPhotos(
        _ items: [PhotosPickerItem],
        optimizeImages: Bool
    ) async -> [(data: Data, fileName: String)] {
        var images: [(data: Data, fileName: String)] = []

        for (index, item) in items.enumerated() {
            if let result = await loadPhotoWithFilename(item: item, index: index) {
                let finalData = optimizeImages ? (OCRService.compressImageData(result.data) ?? result.data) : result.data
                images.append((data: finalData, fileName: result.fileName))
            }
        }

        return images
    }

    private func loadPhotoWithFilename(item: PhotosPickerItem, index: Int) async -> (data: Data, fileName: String)? {
        // Try to load as file representation to get the original filename
        do {
            let result = try await item.loadTransferable(type: PhotoFileTransferable.self)
            if let result = result {
                return (data: result.data, fileName: result.fileName)
            }
        } catch {
            print("Failed to load file representation: \(error)")
        }

        // Fallback: load as raw data without filename
        if let data = try? await item.loadTransferable(type: Data.self) {
            return (data: data, fileName: String(localized: "Photo \(index + 1)", comment: "Fallback filename for imported photo"))
        }

        return nil
    }
}

// MARK: - Photo File Transferable

/// Custom Transferable type to load photos with their original filenames
struct PhotoFileTransferable: Transferable {
    let data: Data
    let fileName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let fileName = received.file.lastPathComponent
            let data = try Data(contentsOf: received.file)
            return PhotoFileTransferable(data: data, fileName: fileName)
        }
    }
}
