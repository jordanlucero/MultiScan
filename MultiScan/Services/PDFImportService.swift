//
//  PDFImportService.swift
//  MultiScan
//
//  Service for importing PDF documents by rendering pages to images
//

import Foundation
import PDFKit
import CoreGraphics
import UniformTypeIdentifiers
import ImageIO

/// Errors that can occur during PDF import
enum PDFImportError: LocalizedError {
    case cannotLoad
    case passwordProtected
    case noPages
    case renderingFailed(page: Int)

    var errorDescription: String? {
        switch self {
        case .cannotLoad:
            return String(localized: "The PDF file could not be opened.")
        case .passwordProtected:
            return String(localized: "Password-protected PDFs are not supported. Please unlock the document and save it without a password in Preview.")
        case .noPages:
            return String(localized: "This PDF is empty.")
        case .renderingFailed(let page):
            return String(localized: "Failed to render page \(page).")
        }
    }
}

/// Wrapper to make PDFDocument usable across concurrent contexts
/// PDFKit is documented as thread-safe for read operations like page access and rendering
private final class SendablePDFDocument: @unchecked Sendable {
    let document: PDFDocument

    init(_ document: PDFDocument) {
        self.document = document
    }
}

/// Service for importing PDF documents by rendering pages to images
final class PDFImportService: @unchecked Sendable {

    /// Check if a URL points to a PDF file
    /// - Parameter url: File URL to check
    /// - Returns: true if the file is a PDF
    static func isPDF(url: URL) -> Bool {
        guard let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return false
        }
        return contentType.conforms(to: .pdf)
    }

    /// Quickly get the page count from a PDF without rendering
    /// - Parameter url: PDF file URL
    /// - Returns: Number of pages, or 0 if the PDF couldn't be loaded
    static func pageCount(for url: URL) -> Int {
        guard let document = PDFDocument(url: url) else {
            return 0
        }
        return document.pageCount
    }

    /// Render all pages of a PDF to HEIC image data using parallel processing
    /// - Parameters:
    ///   - url: PDF file URL
    ///   - dpi: Rendering resolution (default 300 for good OCR quality)
    /// - Returns: Array of (imageData, fileName) tuples ready for OCR pipeline
    /// - Note: Always outputs HEIC for optimal size since we're creating new images, not preserving originals
    func renderPDF(
        at url: URL,
        dpi: CGFloat = 300
    ) async throws -> [(data: Data, fileName: String)] {
        guard let document = PDFDocument(url: url) else {
            throw PDFImportError.cannotLoad
        }

        if document.isLocked {
            throw PDFImportError.passwordProtected
        }

        let pageCount = document.pageCount
        guard pageCount > 0 else {
            throw PDFImportError.noPages
        }

        // Wrap document for safe concurrent access
        let sendableDoc = SendablePDFDocument(document)
        let maxConcurrency = min(ProcessInfo.processInfo.activeProcessorCount, 6)

        // Render pages in parallel using TaskGroup
        let results = try await withThrowingTaskGroup(of: (Int, Data, String)?.self) { group in
            var collected: [(Int, Data, String)] = []
            collected.reserveCapacity(pageCount)
            var inFlight = 0

            for pageIndex in 0..<pageCount {
                // Limit concurrency
                if inFlight >= maxConcurrency {
                    if let result = try await group.next(), let r = result {
                        collected.append(r)
                    }
                    inFlight -= 1
                }

                group.addTask {
                    try Task.checkCancellation()

                    guard let pdfPage = sendableDoc.document.page(at: pageIndex) else {
                        return nil
                    }

                    let pageNumber = pageIndex + 1
                    let fileName = String(localized: "Page \(pageNumber)")

                    return autoreleasepool {
                        guard let cgImage = self.renderPage(pdfPage, dpi: dpi),
                              let imageData = self.convertToHEIC(cgImage) else {
                            return nil
                        }
                        return (pageIndex, imageData, fileName)
                    }
                }
                inFlight += 1
            }

            // Collect remaining
            for try await result in group {
                if let r = result {
                    collected.append(r)
                }
            }

            return collected
        }

        guard !results.isEmpty else {
            throw PDFImportError.renderingFailed(page: 1)
        }

        // Sort by page index to maintain correct order
        let sortedResults = results.sorted { $0.0 < $1.0 }
        return sortedResults.map { (data: $0.1, fileName: $0.2) }
    }

    /// Render a single PDF page to a CGImage
    /// - Parameters:
    ///   - page: PDF page to render
    ///   - dpi: Target resolution in dots per inch
    /// - Returns: Rendered CGImage, or nil if rendering failed
    private func renderPage(_ page: PDFPage, dpi: CGFloat) -> CGImage? {
        let pageRect = page.bounds(for: .mediaBox)
        let scale = dpi / 72.0 // PDF points are 72 per inch

        let width = Int(pageRect.width * scale)
        let height = Int(pageRect.height * scale)

        guard width > 0, height > 0 else {
            return nil
        }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // Fill with white background (PDFs may have transparency)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Scale context to match DPI
        context.scaleBy(x: scale, y: scale)

        // Draw PDF page
        page.draw(with: .mediaBox, to: context)

        return context.makeImage()
    }

    /// Convert CGImage to HEIC data with good compression
    /// - Parameter cgImage: Source image
    /// - Returns: HEIC image data, or nil if conversion failed
    private func convertToHEIC(_ cgImage: CGImage) -> Data? {
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
            kCGImageDestinationLossyCompressionQuality: 0.8
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return mutableData as Data
    }
}
