//
//  PageSplitter.swift
//  MultiScan
//
//  Smart Separate: decides whether one scanned image shows **two physical pages** (an open book photographed as a spread) and, if so, where to cut it — using nothing but the text geometry Vision already produced.
//
//  ## Heuristic
//  A spread has a *gutter*: a vertical band near the middle of the image that no line of text crosses, with a substantial block of text on either side. A single page with two columns also has a gap, but it is narrow and the page is usually portrait; a spread is wide and its gap is wide. So:
//  1. Project every recognized line's horizontal extent onto a 1-D histogram (200 bins across the image width).
//  2. Find the widest run of empty bins whose center falls in the middle band (30 %–70 % of the width).
//  3. Accept it as a gutter only if it is wide enough (≥ 4 % of the width; ≥ 8 % overrides the aspect-ratio check), the image is landscape-ish (w/h ≥ 1.05), and *both* sides carry real text (≥ 3 lines each, ≥ 25 % of the lines each, spanning ≥ 30 % of the image height).
//  4. The two crops are the union of each side's line boxes, grown by a buffer (5 % of each dimension) so margins, drop caps, and marginalia survive — but never across the gutter center, so no text leaks to the wrong page.
//
//  Pure, `nonisolated`, and unit-tested (`PageSplitterTests`). Tuning constants are the `static let`s below.
//

import Foundation
import CoreGraphics

nonisolated enum PageSplitter {

    /// What to do with one image.
    enum Decision: Equatable, Sendable {
        /// Keep the scan as one page.
        case keep
        /// Split into two pages; the boxes are normalized (0…1, upper-left origin) crop rectangles, left/first page first.
        case split(first: NormalizedBox, second: NormalizedBox, gutterCenterX: Double)
    }

    // Tuning
    static let histogramBins = 200
    static let minimumLineCount = 6
    static let minimumLinesPerSide = 3
    static let minimumSideShare = 0.25
    static let minimumSideHeightSpan = 0.30
    static let gutterSearchBand = 0.30...0.70
    static let minimumGutterWidth = 0.04
    static let aspectOverrideGutterWidth = 0.08
    static let minimumLandscapeAspect = 1.05
    static let cropBuffer = 0.05

    /// Decides for `layout` (whose boxes are normalized to an image of aspect `imageAspect` = width ÷ height).
    static func decide(layout: VisionDocumentLayout) -> Decision {
        let size = layout.imageSize
        let aspect = size.height > 0 ? Double(size.width / size.height) : 1
        return decide(lines: layout.allLines.map(\.box), imageAspect: aspect)
    }

    /// Model-free core, for tests.
    static func decide(lines: [NormalizedBox], imageAspect: Double) -> Decision {
        guard lines.count >= minimumLineCount else { return .keep }

        // 1. Horizontal coverage histogram.
        var covered = [Bool](repeating: false, count: histogramBins)
        for box in lines {
            let start = max(0, Int(box.minX * Double(histogramBins)))
            let end = min(histogramBins - 1, Int(box.maxX * Double(histogramBins)))
            guard start <= end else { continue }
            for bin in start...end { covered[bin] = true }
        }

        // 2. Widest empty run centered in the search band.
        var bestRun: (start: Int, end: Int)?
        var runStart: Int?
        for bin in 0...histogramBins {
            let isEmpty = bin < histogramBins && !covered[bin]
            if isEmpty {
                if runStart == nil { runStart = bin }
            } else if let start = runStart {
                let end = bin - 1
                let center = (Double(start) + Double(end) + 1) / 2 / Double(histogramBins)
                if gutterSearchBand.contains(center) {
                    if let best = bestRun {
                        if end - start > best.end - best.start { bestRun = (start, end) }
                    } else {
                        bestRun = (start, end)
                    }
                }
                runStart = nil
            }
        }
        guard let gutter = bestRun else { return .keep }

        let gutterWidth = Double(gutter.end - gutter.start + 1) / Double(histogramBins)
        guard gutterWidth >= minimumGutterWidth else { return .keep }
        if imageAspect < minimumLandscapeAspect && gutterWidth < aspectOverrideGutterWidth { return .keep }
        let gutterCenter = (Double(gutter.start) + Double(gutter.end) + 1) / 2 / Double(histogramBins)

        // 3. Both sides must carry real text.
        let leftLines = lines.filter { $0.maxX <= gutterCenter }
        let rightLines = lines.filter { $0.minX >= gutterCenter }
        guard leftLines.count >= minimumLinesPerSide, rightLines.count >= minimumLinesPerSide else { return .keep }
        let total = Double(lines.count)
        guard Double(leftLines.count) / total >= minimumSideShare, Double(rightLines.count) / total >= minimumSideShare else { return .keep }
        guard let leftUnion = NormalizedBox.union(of: leftLines), let rightUnion = NormalizedBox.union(of: rightLines) else { return .keep }
        guard leftUnion.height >= minimumSideHeightSpan, rightUnion.height >= minimumSideHeightSpan else { return .keep }

        // 4. Buffered crops, clamped to the image and to the gutter center.
        let first = buffered(leftUnion, clampX: 0...gutterCenter)
        let second = buffered(rightUnion, clampX: gutterCenter...1)
        return .split(first: first, second: second, gutterCenterX: gutterCenter)
    }

    private static func buffered(_ box: NormalizedBox, clampX: ClosedRange<Double>) -> NormalizedBox {
        let minX = max(clampX.lowerBound, box.minX - cropBuffer)
        let maxX = min(clampX.upperBound, box.maxX + cropBuffer)
        let minY = max(0, box.minY - cropBuffer)
        let maxY = min(1, box.maxY + cropBuffer)
        return NormalizedBox(x: minX, y: minY, width: max(0.01, maxX - minX), height: max(0.01, maxY - minY))
    }
}
