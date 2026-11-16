//
//  TestSupport.swift
//  MultiScanTests
//
//  In-memory SwiftData fixtures. Every test builds its own container, so suites run in parallel without sharing state. The app itself opens an in-memory store under test (`AppModelContainer.isRunningTests`), so the user's real projects are never touched.
//

import Foundation
import SwiftData
import Testing
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import MultiScan

enum Fixtures {
    /// A fresh in-memory container (CloudKit off).
    static func container() -> ModelContainer {
        previewContainer()
    }

    /// A project with one page per entry of `texts`, inserted, cached, and saved.
    @discardableResult
    static func makeProject(named name: String = "Test Project", texts: [String], in context: ModelContext) -> Document {
        let document = Document(name: name, totalPages: texts.count)
        context.insert(document)
        for (index, text) in texts.enumerated() {
            let page = Page(pageNumber: index + 1, text: text, imageData: nil, originalFileName: "page-\(index + 1).jpg")
            page.document = document
            document.pages?.append(page)
        }
        TextExportCacheService.buildInitialCache(for: document, from: document.unwrappedPages)
        try? context.save()
        return document
    }

    /// Pages sorted by page number.
    static func sortedPages(of document: Document) -> [Page] {
        document.unwrappedPages.sorted { $0.pageNumber < $1.pageNumber }
    }

    // MARK: Synthetic scans

    /// A white image with black text set in `columns` (each given as a normalized x-origin and width) — a stand-in for a scanned page, or for an open book when there are two columns with a gutter between them. Each column carries a distinctive heading so tests can tell which text ended up on which page.
    static func scanImage(width: Int, height: Int, columns: [(x: CGFloat, width: CGFloat, heading: String)]) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let words = "the quick brown fox jumps over the lazy dog while the patient reader turns another page of this rather ordinary printed book".split(separator: " ").map(String.init)
        for (index, column) in columns.enumerated() {
            var text = column.heading + "\n\n"
            for word in 0..<180 { text += words[(word * 7 + index * 3) % words.count] + " " }
            let font = CTFontCreateWithName("Times New Roman" as CFString, CGFloat(height) / 48, nil)
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ])
            let rect = CGRect(x: column.x * CGFloat(width), y: CGFloat(height) * 0.08, width: column.width * CGFloat(width), height: CGFloat(height) * 0.84)
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed), CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
            CTFrameDraw(frame, context)
        }
        return context.makeImage()!
    }

    /// JPEG bytes of `image`, optionally tagged with an EXIF orientation (1 = upright, 6 = stored turned, shown rotated 90° clockwise).
    static func jpegData(_ image: CGImage, exifOrientation: Int = 1) -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: exifOrientation,
            kCGImageDestinationLossyCompressionQuality: 0.9
        ] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    /// An open book: two pages of text side by side, headed "LEFTSIDE" and "RIGHTSIDE".
    static func spreadImage() -> CGImage {
        scanImage(width: 2400, height: 1650, columns: [(0.06, 0.38, "LEFTSIDE HEADING"), (0.56, 0.38, "RIGHTSIDE HEADING")])
    }

    /// A project with one page whose image is `imageData` (no OCR has run; the text is `text`).
    @discardableResult
    static func makeScannedProject(imageData: Data, text: String = "placeholder", extraPages: [String] = [], in context: ModelContext) -> Document {
        let document = Document(name: "Scans", totalPages: 1 + extraPages.count)
        context.insert(document)
        let page = Page(pageNumber: 1, text: text, imageData: imageData, originalFileName: "scan.jpg")
        page.document = document
        document.pages?.append(page)
        for (index, extra) in extraPages.enumerated() {
            let other = Page(pageNumber: index + 2, text: extra, imageData: nil, originalFileName: "page-\(index + 2).jpg")
            other.document = document
            document.pages?.append(other)
        }
        TextExportCacheService.buildInitialCache(for: document, from: document.unwrappedPages)
        try? context.save()
        return document
    }

    /// A throwaway UserDefaults suite, cleared before use.
    static func defaults(_ name: String) -> UserDefaults {
        let suite = "co.jservices.MultiScanTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
