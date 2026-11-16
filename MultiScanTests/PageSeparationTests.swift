//
//  PageSeparationTests.swift
//  MultiScanTests
//
//  Smart Separate's storage model and its after-import paths: normalized geometry, the crop-aware image pipeline, separating a two-page scan into two pages that share it, rejoining them, and reading a page again.
//
//  The separation tests run the real pipeline (Vision included) on a synthetic open-book image, so they exercise what the app does rather than a mock of it.
//

import Foundation
import SwiftData
import Testing
import CoreGraphics
import ImageIO
@testable import MultiScan

@Suite("Page separation")
struct PageSeparationTests {
    let container = Fixtures.container()

    private func close(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 0.0001) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }

    // MARK: Geometry

    @Test func rotationMapsRectanglesTheWayTheImageTurns() {
        // A box in the top-left corner of the upright image…
        let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1)
        // …is in the top-right after a clockwise quarter turn.
        #expect(close(NormalizedGeometry.rotated(box, clockwise: 90), CGRect(x: 0.7, y: 0.1, width: 0.1, height: 0.3)))
        #expect(close(NormalizedGeometry.rotated(box, clockwise: 180), CGRect(x: 0.6, y: 0.7, width: 0.3, height: 0.1)))
        #expect(close(NormalizedGeometry.rotated(box, clockwise: 270), CGRect(x: 0.2, y: 0.6, width: 0.1, height: 0.3)))
        #expect(close(NormalizedGeometry.rotated(box, clockwise: 0), box))
        for degrees in [0, 90, 180, 270] {
            #expect(close(NormalizedGeometry.unrotated(NormalizedGeometry.rotated(box, clockwise: degrees), clockwise: degrees), box))
        }
    }

    @Test func relativeAndAbsoluteAreInverses() {
        let half = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let capture = CGRect(x: 0.6, y: 0.4, width: 0.2, height: 0.2)
        let inHalf = NormalizedGeometry.relative(capture, to: half)
        #expect(close(inHalf, CGRect(x: 0.2, y: 0.4, width: 0.4, height: 0.2)))
        #expect(close(NormalizedGeometry.absolute(inHalf, in: half), capture))
        #expect(PageSeparationService.nearestRegion(to: CGPoint(x: 0.7, y: 0.5), among: [CGRect(x: 0, y: 0, width: 0.5, height: 1), half]) == 1)
        #expect(PageSeparationService.nearestRegion(to: CGPoint(x: 0.2, y: 0.5), among: [CGRect(x: 0, y: 0, width: 0.45, height: 1), CGRect(x: 0.55, y: 0, width: 0.45, height: 1)]) == 0)
    }

    // MARK: Image pipeline

    @Test func cropIsAppliedToTheUprightImageBeforeTheUsersRotation() throws {
        let image = Fixtures.scanImage(width: 800, height: 400, columns: [(0.1, 0.8, "WIDE")])
        let data = Fixtures.jpegData(image)
        let rightHalf = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)

        let cropped = try #require(PlatformImage.processedCGImage(from: data, crop: rightHalf))
        #expect(cropped.width == 400 && cropped.height == 400)

        // A region that isn't square, so the rotation's effect on the size is visible.
        let strip = CGRect(x: 0, y: 0, width: 0.25, height: 1)
        let turned = try #require(PlatformImage.processedCGImage(from: data, crop: strip, userRotation: 90))
        #expect(turned.width == 400 && turned.height == 200)

        // No crop, no rotation: the fast path still returns the whole image.
        let whole = try #require(PlatformImage.processedCGImage(from: data))
        #expect(whole.width == 800 && whole.height == 400)
    }

    @Test func cropRespectsExifOrientation() throws {
        // Stored 800×400 with orientation 6: displayed as 400 wide × 800 tall.
        let image = Fixtures.scanImage(width: 800, height: 400, columns: [(0.1, 0.8, "TURNED")])
        let data = Fixtures.jpegData(image, exifOrientation: 6)
        let topHalf = CGRect(x: 0, y: 0, width: 1, height: 0.5)
        let cropped = try #require(PlatformImage.processedCGImage(from: data, crop: topHalf))
        #expect(cropped.width == 400 && cropped.height == 400)

        let recognition = try #require(PlatformImage.recognitionImage(from: PageImageSource(data: data, crop: nil), userRotation: 0))
        #expect(recognition.width == 400 && recognition.height == 800)
    }

    @Test func optimizingAnImageKeepsItsOrientation() throws {
        let image = Fixtures.scanImage(width: 800, height: 400, columns: [(0.1, 0.8, "PHOTO")])
        let data = Fixtures.jpegData(image, exifOrientation: 6)
        let optimized = try #require(PlatformImage.heicReencoding(data))
        let decoded = try #require(PlatformImage.decodedImage(from: optimized))
        // The pixels are stored as before and the tag still says how to turn them; dropping it showed optimized phone photos sideways.
        #expect(decoded.orientation == .right)
        #expect(decoded.image.width == 800 && decoded.image.height == 400)
    }

    @Test func markingRegionsDimsEverythingButTheHighlightedPage() throws {
        // A plain white "scan".
        let context = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        let scan = context.makeImage()!

        // Regions with an upper-left origin: the left page is the top-left quarter here, the right page the top-right.
        let left = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let right = CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        let marked = try #require(PlatformImage.markingRegions([left, right], highlighted: right, accent: CGColor(red: 1, green: 0, blue: 0, alpha: 1), on: scan))
        #expect(marked.width == 400 && marked.height == 200)

        // Read pixels back (row 0 is the top row of the image).
        let bytesPerRow = marked.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * marked.height)
        let reader = CGContext(data: &pixels, width: marked.width, height: marked.height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        reader.draw(marked, in: CGRect(x: 0, y: 0, width: marked.width, height: marked.height))
        func red(x: Int, y: Int) -> Int { Int(pixels[y * bytesPerRow + x * 4]) }

        #expect(red(x: 300, y: 50) > 240)   // inside the highlighted (right, top) page: untouched
        #expect(red(x: 100, y: 50) < 180)   // the other page: dimmed
        #expect(red(x: 300, y: 150) < 180)  // below both pages: dimmed — so the region really is the *top* half
    }

    // MARK: Model

    @Test func pageImageSourceFallsBackToTheSharedScan() {
        let context = container.mainContext
        let bytes = Data([1, 2, 3])
        let document = Fixtures.makeScannedProject(imageData: bytes, in: context)
        let page = Fixtures.sortedPages(of: document)[0]
        #expect(page.imageSource?.data == bytes)
        #expect(page.imageSource?.crop == nil)
        #expect(page.imageCrop == nil)
        #expect(!page.isSeparated)

        let scan = SharedScan(imageData: bytes, originalFileName: "scan.jpg", document: document)
        context.insert(scan)
        document.sharedScans?.append(scan)
        page.imageData = nil
        page.sharedScan = scan
        page.imageCrop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        #expect(page.isSeparated)
        #expect(page.imageSource?.data == bytes)
        #expect(page.imageSource?.crop == CGRect(x: 0, y: 0, width: 0.5, height: 1))

        page.imageCrop = nil
        #expect(page.cropWidth == 1 && page.cropX == 0)

        // Stored once, counted once.
        document.recalculateStorageSize()
        #expect(document.cachedStorageBytes >= Int64(bytes.count))
    }

    // MARK: Separate → rejoin (real pipeline)

    @Test(.timeLimit(.minutes(3)))
    func separatingASpreadMakesTwoPagesThatShareTheScan() async throws {
        let context = container.mainContext
        let data = Fixtures.jpegData(Fixtures.spreadImage())
        let document = Fixtures.makeScannedProject(imageData: data, text: "old text", extraPages: ["after"], in: context)
        let page = Fixtures.sortedPages(of: document)[0]
        page.sectionTitle = "Opening"
        document.printedNumbering = ResolvedPrintedNumbering.simple(startPage: 1, startValue: 41, frontMatter: .none)
            .anchored(to: Fixtures.sortedPages(of: document))

        // An illustration on the right-hand page of the spread.
        let capture = PageCapture(page: page, imageData: nil, thumbnailData: nil, normalizedRect: CGRect(x: 0.7, y: 0.4, width: 0.2, height: 0.2), pixelSize: CGSize(width: 10, height: 10))
        context.insert(capture)
        page.captures?.append(capture)

        let candidate = try #require(await PageSeparationService.candidate(for: page))
        #expect(candidate.first.maxX <= candidate.second.minX + 0.0001)

        let second = try await PageSeparationService.separate(candidate, in: document, context: context)

        // Two pages where there was one; the page after them moved down.
        let pages = Fixtures.sortedPages(of: document)
        #expect(pages.count == 3 && document.totalPages == 3)
        #expect(pages[0] === page && pages[1] === second)
        #expect(pages[2].plainText == "after")
        #expect(page.splitPosition == 1 && second.splitPosition == 2)

        // One stored copy of the scan, shown by region.
        #expect(page.imageData == nil && second.imageData == nil)
        #expect(page.sharedScan === second.sharedScan)
        #expect(document.unwrappedSharedScans.count == 1)
        #expect(page.sourceImageData == data)
        let firstCrop = try #require(page.imageCrop)
        let secondCrop = try #require(second.imageCrop)
        #expect(firstCrop.maxX <= secondCrop.minX + 0.0001)
        #expect(page.thumbnailData != nil && second.thumbnailData != nil)
        #expect(page.originalFileName == "scan.jpg (1 of 2)")

        // Each page got its own half's text, not the old text and not the other half's.
        #expect(page.plainText.contains("LEFTSIDE") && !page.plainText.contains("RIGHTSIDE"))
        #expect(second.plainText.contains("RIGHTSIDE") && !second.plainText.contains("LEFTSIDE"))
        #expect(page.visionLayout != nil && second.visionLayout != nil)

        // What belonged to the page stays with the first page; the capture went with its half and is still referenced from the text.
        #expect(page.sectionTitle == "Opening" && second.sectionTitle == nil)
        #expect(page.printedPageLabel == "41" && second.printedPageLabel == "42")
        #expect(capture.page === second)
        #expect(second.unwrappedCaptures.count == 1 && page.unwrappedCaptures.isEmpty)
        #expect(InlineAttachments.captureIDs(in: second.attributedText) == [capture.uuid].compactMap { $0 })
        #expect(capture.normalizedRect.minX >= 0 && capture.normalizedRect.maxX <= 1)

        // The export cache has an entry per page, in order, matching the pages.
        let cache = try #require(TextExportCacheService.loadFreshCache(from: document))
        #expect(cache.pages.map(\.pageNumber) == [1, 2, 3])
        #expect(cache.pages[1].plainText.contains("RIGHTSIDE"))
        #expect(cache.pages[0].fileName == "scan.jpg (1 of 2)")

        // A separated page can't be separated again.
        #expect(await PageSeparationService.candidate(for: page) == nil)

        // — Rejoin —
        let state = NavigationState(settings: NavigationSettings(defaults: Fixtures.defaults("separation-\(UUID().uuidString)")))
        state.setupNavigation(for: document)
        state.goToPage(pageNumber: 2)
        second.attributedText = NSAttributedString(string: second.plainText + "\nEDITED BY HAND")
        TextExportCacheService.replaceEntry(for: second, in: document)

        let survivor = try await PageSeparationService.rejoin(second, navigationState: state, context: context)
        #expect(survivor === page)
        let rejoined = Fixtures.sortedPages(of: document)
        #expect(rejoined.count == 2 && document.totalPages == 2)
        #expect(rejoined[1].plainText == "after" && rejoined[1].pageNumber == 2)
        #expect(page.imageData == data && page.sharedScan == nil && page.imageCrop == nil && page.splitPosition == 0)
        #expect(document.unwrappedSharedScans.isEmpty)
        #expect(page.originalFileName == "scan.jpg")
        // Both texts, in order — including the edit — and the illustration is back on the one page.
        #expect(page.plainText.contains("LEFTSIDE") && page.plainText.contains("RIGHTSIDE") && page.plainText.contains("EDITED BY HAND"))
        #expect(page.plainText.range(of: "LEFTSIDE")!.lowerBound < page.plainText.range(of: "RIGHTSIDE")!.lowerBound)
        #expect(page.unwrappedCaptures.count == 1)
        #expect(abs(capture.normalizedRect.midX - 0.8) < 0.05)
        #expect(state.currentPage === page)
        #expect(page.printedPageLabel == "41" && rejoined[1].printedPageLabel == "42")
        let cacheAfter = try #require(TextExportCacheService.loadFreshCache(from: document))
        #expect(cacheAfter.pages.map(\.pageNumber) == [1, 2])
    }

    @Test(.timeLimit(.minutes(3)))
    func aSinglePageIsNotACandidateButCanBeSplitByHandAndReadAgain() async throws {
        let context = container.mainContext
        let image = Fixtures.scanImage(width: 1300, height: 1650, columns: [(0.1, 0.8, "ONLYPAGE HEADING")])
        let document = Fixtures.makeScannedProject(imageData: Fixtures.jpegData(image), text: "stale", in: context)
        let page = Fixtures.sortedPages(of: document)[0]

        #expect(await PageSeparationService.candidate(for: page) == nil)
        let manual = try #require(PageSeparationService.middleSplit(for: page))
        #expect(manual.first.maxX == 0.5 && manual.second.minX == 0.5)

        // Reading the page again replaces stale text and refreshes the stored layout and provenance.
        try await PageRecognitionService.recognizeAgain(page)
        #expect(page.plainText.contains("ONLYPAGE"))
        #expect(page.visionTranscript?.contains("ONLYPAGE") == true)
        #expect(page.ocrEngine == "vision")
        #expect(!PageRecognitionService.textCameFromModel(page))
        #expect(TextExportCacheService.loadFreshCache(from: document)?.pages.first?.plainText.contains("ONLYPAGE") == true)

        // "Restore Apple Vision Text" puts the stored transcript back over whatever is there.
        page.attributedText = NSAttributedString(string: "model output")
        page.ocrEngine = "server:some-model"
        #expect(PageRecognitionService.textCameFromModel(page))
        try await PageRecognitionService.restoreVisionText(page)
        #expect(page.plainText.contains("ONLYPAGE") && page.ocrEngine == "vision")
    }

    @Test func deletingTheLastReaderDeletesTheScan() throws {
        let context = container.mainContext
        let document = Fixtures.makeProject(texts: ["left", "right", "other"], in: context)
        let pages = Fixtures.sortedPages(of: document)
        let scan = SharedScan(imageData: Data([9]), originalFileName: "s.jpg", document: document)
        context.insert(scan)
        document.sharedScans?.append(scan)
        for (index, page) in pages.prefix(2).enumerated() {
            page.sharedScan = scan
            page.splitPosition = index + 1
        }
        try context.save()
        let state = NavigationState(settings: NavigationSettings(defaults: Fixtures.defaults("scan-delete-\(UUID().uuidString)")))
        state.setupNavigation(for: document)

        state.deletePage(pages[0], modelContext: context)
        #expect(document.unwrappedSharedScans.count == 1) // the facing page still shows it
        state.deletePage(pages[1], modelContext: context)
        #expect(document.unwrappedSharedScans.isEmpty)
        #expect(Fixtures.sortedPages(of: document).map(\.plainText) == ["other"])
    }
}
