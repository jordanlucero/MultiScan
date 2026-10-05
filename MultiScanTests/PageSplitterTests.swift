//
//  PageSplitterTests.swift
//  MultiScanTests
//
//  Smart Separate's gutter detection on synthetic layouts.
//

import Foundation
import Testing
@testable import MultiScan

@Suite("Smart Separate")
struct PageSplitterTests {
    /// `count` lines filling the horizontal band `x…x+width`, stacked from `y` downward.
    private func column(x: Double, width: Double, count: Int, y: Double = 0.1, lineHeight: Double = 0.03) -> [NormalizedBox] {
        (0..<count).map { index in
            NormalizedBox(x: x, y: y + Double(index) * lineHeight * 1.4, width: width, height: lineHeight)
        }
    }

    @Test func landscapeSpreadWithClearGutterSplits() throws {
        let lines = column(x: 0.06, width: 0.38, count: 20) + column(x: 0.56, width: 0.38, count: 20)
        let decision = PageSplitter.decide(lines: lines, imageAspect: 1.4)
        guard case .split(let first, let second, let gutter) = decision else {
            Issue.record("Expected a split, got \(decision)")
            return
        }
        #expect(gutter > 0.45 && gutter < 0.55)
        #expect(first.maxX <= gutter + 0.0001)
        #expect(second.minX >= gutter - 0.0001)
        // Buffered crops stay inside the image and include a margin around the text.
        #expect(first.minX >= 0 && first.minX < 0.06)
        #expect(second.maxX <= 1 && second.maxX > 0.94)
        #expect(first.minY < 0.1 && first.minY >= 0)
    }

    @Test func singlePageWithFullWidthLinesKeeps() {
        let lines = column(x: 0.1, width: 0.8, count: 20)
        #expect(PageSplitter.decide(lines: lines, imageAspect: 1.4) == .keep)
    }

    @Test func portraitTwoColumnPageWithNarrowGapKeeps() {
        // Two columns 2.5 % apart on a portrait page: a normal two-column layout, not a spread.
        let lines = column(x: 0.08, width: 0.40, count: 20) + column(x: 0.505, width: 0.40, count: 20)
        #expect(PageSplitter.decide(lines: lines, imageAspect: 0.75) == .keep)
    }

    @Test func portraitImageSplitsOnlyWithAWideGutter() throws {
        let lines = column(x: 0.04, width: 0.40, count: 20) + column(x: 0.56, width: 0.40, count: 20)
        // 12 % gutter overrides the aspect requirement.
        guard case .split = PageSplitter.decide(lines: lines, imageAspect: 0.9) else {
            Issue.record("Expected the wide gutter to force a split")
            return
        }
    }

    @Test func tooFewLinesKeeps() {
        let lines = column(x: 0.05, width: 0.4, count: 2) + column(x: 0.55, width: 0.4, count: 2)
        #expect(PageSplitter.decide(lines: lines, imageAspect: 1.5) == .keep)
    }

    @Test func lopsidedSidesKeep() {
        // A caption on the right of an otherwise single page should not trigger a split.
        let lines = column(x: 0.05, width: 0.4, count: 30) + column(x: 0.6, width: 0.3, count: 2, y: 0.8)
        #expect(PageSplitter.decide(lines: lines, imageAspect: 1.5) == .keep)
    }

    @Test func layoutDrivenDecisionUsesImageAspect() throws {
        let paragraphs = [
            VisionDocumentLayout.Paragraph(text: "L", box: NormalizedBox(x: 0.05, y: 0.1, width: 0.4, height: 0.8), lines: column(x: 0.05, width: 0.4, count: 15).map { VisionDocumentLayout.Line(text: "l", box: $0) }),
            VisionDocumentLayout.Paragraph(text: "R", box: NormalizedBox(x: 0.55, y: 0.1, width: 0.4, height: 0.8), lines: column(x: 0.55, width: 0.4, count: 15).map { VisionDocumentLayout.Line(text: "r", box: $0) })
        ]
        let layout = VisionDocumentLayout(imageWidth: 4000, imageHeight: 2800, transcript: "", title: nil, paragraphs: paragraphs, tables: [], lists: [], languages: [])
        guard case .split = PageSplitter.decide(layout: layout) else {
            Issue.record("Expected a split for a landscape spread layout")
            return
        }
        // Encoding round-trips.
        let data = try #require(layout.encoded())
        #expect(VisionDocumentLayout.decode(data) == layout)
    }

    @Test func normalizedBoxFlipsVisionOrigin() {
        // Vision: lower-left origin. A box at the top of the image (y near 1) becomes y near 0.
        let box = NormalizedBox(flippingVision: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.1))
        #expect(abs(box.y - 0.1) < 0.0001)
        #expect(abs(box.maxY - 0.2) < 0.0001)
        let pixels = box.pixelRect(in: CGSize(width: 1000, height: 500))
        #expect(abs(pixels.minX - 100) < 0.01 && abs(pixels.minY - 50) < 0.01)
        #expect(abs(pixels.width - 200) < 0.01 && abs(pixels.height - 50) < 0.01)
    }
}
