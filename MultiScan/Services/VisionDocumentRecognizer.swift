//
//  VisionDocumentRecognizer.swift
//  MultiScan
//
//  The Vision side of OCR, on the Swift-native Vision API (iOS/macOS 26+): `RecognizeDocumentsRequest` instead of the Objective-C era `VNRecognizeTextRequest`.
//
//  ## Why RecognizeDocumentsRequest
//  `RecognizeTextRequest` returns a flat list of lines. `RecognizeDocumentsRequest` understands the *page*: it groups lines into paragraphs (so two narrow columns with a thin gutter don't get read straight across), detects tables and lists, flags a title, and still exposes every line with its geometry. That structure is what Smart Separate (gutter detection), inline tables, chapter detection, and the per-page layout store all need — so Vision runs on **every** import, even when the user picked a transformer model as the primary OCR engine (see `OCRService`).
//
//  ## Orientation
//  Vision analyzes the pixels it is given. A phone photo stored with an EXIF orientation is *rotated pixels + a tag*, so the recognizer turns the bitmap upright first (`PlatformImage.oriented`) and then reads it; the old implementation read sideways text. Regions come back normalized to the upright image, which is also what the viewer shows, so `VisionDocumentLayout` records the upright pixel size.
//
//  ## Coordinates
//  Vision's normalized rectangles have a lower-left origin. `VisionDocumentLayout` stores everything with an **upper-left** origin (0…1), the convention of every drawing API the app uses (SwiftUI, Core Graphics contexts in the capture overlay, `PageCapture.normalizedRect`, `Page.imageCrop`). The flip happens once, here.
//
//  ## Quality over speed: the detail pass
//  Vision reads an image at a fixed working resolution, so what it can see depends on how big the text is *relative to the image*, not on how many pixels the scan has. Measured on macOS 27 with a synthetic 2550×3300 page: text at 1/90 of the image height is read completely, at 1/110 about 14 % of the words are missing, and at 1/140 the request returns **no text at all** — with no error. Upscaling the image changes nothing; cropping to a region reads the same text perfectly. Footnotes under normal body text are dropped the same way, silently.
//
//  So every page is read more than once: the whole image (which gives the page structure — paragraphs, tables, lists, title) plus two or three overlapping horizontal **bands**, in which the same text is proportionally larger. `merging(whole:bands:)` then adds every band line the whole-image pass has no counterpart for. A page the whole pass already read completely comes back unchanged — the bands only ever *add*. The passes run concurrently (Vision schedules them on the GPU/Neural Engine), which measured at roughly the wall-clock time of one pass on a Mac; where it does cost time, that is the trade this app makes on purpose.
//
//  Bands are horizontal only: a line of text never straddles a horizontal cut for long (the overlap covers it), whereas a vertical cut would slice every line in two.
//
import Foundation
import CoreGraphics
import ImageIO
import Vision

// MARK: - Stored layout

/// A normalized rectangle (0…1) with an upper-left origin. Codable scalars rather than `CGRect` so the plist encoding is stable across platforms.
nonisolated struct NormalizedBox: Codable, Sendable, Equatable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var minX: Double { x }
    var maxX: Double { x + width }
    var minY: Double { y }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    /// Converts a Vision `NormalizedRect` (lower-left origin) to upper-left origin.
    init(flippingVision rect: CGRect) {
        self.init(x: rect.origin.x, y: 1 - (rect.origin.y + rect.height), width: rect.width, height: rect.height)
    }

    /// Scales to pixel coordinates (upper-left origin, as Core Graphics image contexts expect after flipping).
    func pixelRect(in size: CGSize) -> CGRect {
        CGRect(x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height)
    }

    /// Smallest box containing both.
    func union(_ other: NormalizedBox) -> NormalizedBox {
        let minX = min(self.minX, other.minX)
        let minY = min(self.minY, other.minY)
        let maxX = max(self.maxX, other.maxX)
        let maxY = max(self.maxY, other.maxY)
        return NormalizedBox(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func union(of boxes: [NormalizedBox]) -> NormalizedBox? {
        guard var result = boxes.first else { return nil }
        for box in boxes.dropFirst() { result = result.union(box) }
        return result
    }
}

/// Everything MultiScan keeps from a `RecognizeDocumentsRequest` pass over one page image. Persisted on `Page.visionLayoutData` as a binary plist.
nonisolated struct VisionDocumentLayout: Codable, Sendable, Equatable {
    /// Bump when the structure changes; `decode` returns nil for other versions so callers fall back gracefully (the layout is derived data and can be regenerated by re-running Vision on the page image).
    static let currentVersion = 1

    /// One recognized line: Vision's top transcript candidate and its box.
    struct Line: Codable, Sendable, Equatable {
        var text: String
        var box: NormalizedBox
    }

    /// A paragraph: Vision's grouping of lines that read together (one column, one block). `box` is the union of the lines.
    struct Paragraph: Codable, Sendable, Equatable {
        var text: String
        var box: NormalizedBox
        var lines: [Line]
    }

    /// A table cell; ranges are row/column indices (a merged cell spans several).
    struct TableCell: Codable, Sendable, Equatable {
        var rowStart: Int
        var rowEnd: Int        // inclusive
        var columnStart: Int
        var columnEnd: Int     // inclusive
        var text: String
        var box: NormalizedBox
    }

    struct Table: Codable, Sendable, Equatable {
        var box: NormalizedBox
        /// Rows of cells, in reading order. Row/column counts come from the ranges.
        var rows: [[TableCell]]

        var rowCount: Int { (rows.flatMap { $0 }.map(\.rowEnd).max() ?? -1) + 1 }
        var columnCount: Int { (rows.flatMap { $0 }.map(\.columnEnd).max() ?? -1) + 1 }
    }

    struct ListBlock: Codable, Sendable, Equatable {
        var box: NormalizedBox
        var items: [String]
    }

    var version: Int = currentVersion

    /// Pixel size of the *oriented* image the regions are normalized against.
    var imageWidth: Int
    var imageHeight: Int

    /// Full-page transcript in reading order (Vision's `Container.Text.transcript`).
    var transcript: String

    /// Vision's title detection (`Container.title`), if any — a strong hint for `ChapterDetector` and `ProjectTitleSuggester`.
    var title: String?

    var paragraphs: [Paragraph]
    var tables: [Table]
    var lists: [ListBlock]

    /// BCP-47 identifiers of the recognized languages, when Vision reports them.
    var languages: [String]

    /// The page's user rotation (degrees clockwise) that was already applied to the bitmap Vision read; `nil` = none, which is every layout written at import. A page read again after the user turned it (`PageRecognitionService`, `PageSeparationService`) is read the way it is displayed, so its boxes are in *display* space. Geometry consumers compare this with `Page.rotation` and re-run Vision when they differ. Optional so layouts stored before this field decode unchanged.
    var recognizedAtRotation: Int?

    /// Every line across all paragraphs, in document order — what Smart Separate and the capture overlay snap to.
    var allLines: [Line] { paragraphs.flatMap(\.lines) }

    var imageSize: CGSize { CGSize(width: imageWidth, height: imageHeight) }

    // MARK: Persistence

    func encoded() -> Data? {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try? encoder.encode(self)
    }

    static func decode(_ data: Data?) -> VisionDocumentLayout? {
        guard let data,
              let layout = try? PropertyListDecoder().decode(VisionDocumentLayout.self, from: data),
              layout.version == currentVersion else { return nil }
        return layout
    }

    /// The legacy `boundingBoxesData` shape (lower-left-origin `CGRect`s per line), so older code paths that still read `Page.boundingBoxes` keep working for new pages if ever needed.
    func legacyBoundingBoxesData() -> Data? {
        let rects = allLines.map { line -> CGRect in
            CGRect(x: line.box.x, y: 1 - line.box.maxY, width: line.box.width, height: line.box.height)
        }
        return try? JSONEncoder().encode(rects)
    }
}

// MARK: - Recognizer

/// Stateless, `nonisolated`: called from `OCRService`'s `@concurrent` per-image work.
nonisolated enum VisionDocumentRecognizer {

    /// Images shorter than this are read in one pass: there is nothing a band could enlarge usefully.
    static let minimumHeightForDetailPass = 600

    /// Runs document recognition on an already-decoded image: the whole image plus the detail bands (see the file header), merged.
    /// - Parameters:
    ///   - cgImage: the raw decoded bitmap (NOT pre-rotated).
    ///   - orientation: the EXIF orientation of `cgImage`, so Vision reads the text upright. Regions are returned relative to the upright image.
    static func recognize(_ cgImage: CGImage, orientation: CGImagePropertyOrientation) async throws -> VisionDocumentLayout {
        // Bands are cut from the upright bitmap, so turn it once up front. If that fails, read the image as given and let Vision apply the orientation.
        guard let upright = PlatformImage.oriented(cgImage, orientation) else {
            return try await recognizeSinglePass(cgImage, orientation: orientation)
        }

        let regions = detailBands(forImageWidth: upright.width, height: upright.height)
        async let wholePass = recognizeSinglePass(upright, orientation: .up)

        // A band that fails only costs its own contribution; the whole-image pass decides whether the page fails.
        let bands = await withTaskGroup(of: (NormalizedBox, VisionDocumentLayout)?.self) { group -> [(region: NormalizedBox, layout: VisionDocumentLayout)] in
            for region in regions {
                group.addTask {
                    guard let crop = PlatformImage.cropped(upright, to: region.cgRect),
                          let layout = try? await recognizeSinglePass(crop, orientation: .up) else { return nil }
                    return (region, layout)
                }
            }
            var results: [(region: NormalizedBox, layout: VisionDocumentLayout)] = []
            for await result in group {
                if let result { results.append((region: result.0, layout: result.1)) }
            }
            return results.sorted { $0.region.y < $1.region.y }
        }

        return merging(whole: try await wholePass, bands: bands)
    }

    // MARK: Detail bands

    /// The overlapping horizontal bands read in addition to the whole image: three for a portrait page, two for a landscape one (bands of a landscape image are already wide and short). Empty for small images.
    static func detailBands(forImageWidth width: Int, height: Int) -> [NormalizedBox] {
        guard height >= minimumHeightForDetailPass else { return [] }
        let spans: [(start: Double, end: Double)] = height >= width
            ? [(0, 0.4), (0.3, 0.7), (0.6, 1)]
            : [(0, 0.58), (0.42, 1)]
        return spans.map { NormalizedBox(x: 0, y: $0.start, width: 1, height: $0.end - $0.start) }
    }

    /// Adds to `whole` every line the band passes found that the whole-image pass has no counterpart for. Pure; unit-tested.
    ///
    /// - A band line counts as already known when it overlaps a whole-pass line (or lies inside a whole-pass table or list, whose text isn't necessarily repeated in `paragraphs`), or a line an earlier band already contributed.
    /// - Lines touching a band's cut edge are ignored: they may be sliced, and the neighboring band sees them whole.
    /// - Recovered lines keep the band's paragraph grouping and are placed by vertical position; their text is spliced into the transcript after the paragraph that precedes them (or appended when that can't be located).
    static func merging(whole: VisionDocumentLayout, bands: [(region: NormalizedBox, layout: VisionDocumentLayout)]) -> VisionDocumentLayout {
        guard !bands.isEmpty else { return whole }

        var knownLines = whole.allLines.map(\.box)
        let structuredRegions = whole.tables.map(\.box) + whole.lists.map(\.box)
        var recovered: [VisionDocumentLayout.Paragraph] = []
        var languages = whole.languages

        for band in bands {
            let region = band.region
            for paragraph in band.layout.paragraphs {
                var newLines: [VisionDocumentLayout.Line] = []
                for line in paragraph.lines {
                    // Sliced by the cut? (Only internal edges count — the image's own top and bottom are real edges.)
                    let margin = line.box.height * 0.25
                    if region.minY > 0.0001, line.box.minY < margin { continue }
                    if region.maxY < 0.9999, line.box.maxY > 1 - margin { continue }

                    let box = NormalizedBox(
                        x: line.box.x,
                        y: region.y + line.box.y * region.height,
                        width: line.box.width,
                        height: line.box.height * region.height
                    )
                    if structuredRegions.contains(where: { $0.cgRect.contains(CGPoint(x: box.midX, y: box.midY)) }) { continue }
                    if knownLines.contains(where: { overlapShare($0, box) > 0.25 }) { continue }
                    knownLines.append(box)
                    newLines.append(VisionDocumentLayout.Line(text: line.text, box: box))
                }
                guard !newLines.isEmpty, let union = NormalizedBox.union(of: newLines.map(\.box)) else { continue }
                recovered.append(VisionDocumentLayout.Paragraph(text: newLines.map(\.text).joined(separator: "\n"), box: union, lines: newLines))
            }
            for language in band.layout.languages where !languages.contains(language) { languages.append(language) }
        }

        guard !recovered.isEmpty else { return whole }

        var merged = whole
        merged.languages = languages
        if merged.title == nil { merged.title = bands.first?.layout.title }

        for paragraph in recovered.sorted(by: { $0.box.minY < $1.box.minY }) {
            // Reading position: after the last paragraph that starts above the recovered text's middle.
            let index = (merged.paragraphs.lastIndex { $0.box.minY <= paragraph.box.midY }).map { $0 + 1 } ?? 0
            let anchorText = index > 0 ? merged.paragraphs[index - 1].text : nil
            merged.paragraphs.insert(paragraph, at: index)
            merged.transcript = splicing(paragraph.text, into: merged.transcript, after: anchorText, atStart: index == 0)
        }
        return merged
    }

    /// Intersection area over the smaller box's area: 1 when one box contains the other.
    static func overlapShare(_ a: NormalizedBox, _ b: NormalizedBox) -> Double {
        let width = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let height = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        guard width > 0, height > 0 else { return 0 }
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 ? (width * height) / smaller : 0
    }

    /// Inserts `text` into `transcript` after the last occurrence of `anchor`'s final line (Vision's transcript reflows paragraphs, so a whole-paragraph match is not reliable; its last line is). Falls back to the start or the end.
    private static func splicing(_ text: String, into transcript: String, after anchor: String?, atStart: Bool) -> String {
        guard !transcript.isEmpty else { return text }
        if atStart { return text + "\n" + transcript }
        if let lastLine = anchor?.split(whereSeparator: \.isNewline).last.map(String.init), !lastLine.isEmpty,
           let range = transcript.range(of: lastLine, options: .backwards) {
            var result = transcript
            result.insert(contentsOf: "\n" + text, at: range.upperBound)
            return result
        }
        return transcript + "\n" + text
    }

    // MARK: One Vision pass

    /// One `RecognizeDocumentsRequest` over one bitmap.
    static func recognizeSinglePass(_ cgImage: CGImage, orientation: CGImagePropertyOrientation) async throws -> VisionDocumentLayout {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.useLanguageCorrection = true
        request.textRecognitionOptions.automaticallyDetectLanguage = true
        // No lower bound on text size: the default (1/32 of the image height) asks Vision to skip small print.
        request.textRecognitionOptions.minimumTextHeightFraction = 0
        // Language detection still runs; this only tells Vision which languages to try first — the user's own, then English — instead of English alone.
        let preferred = preferredRecognitionLanguages(supported: request.supportedRecognitionLanguages)
        if !preferred.isEmpty { request.textRecognitionOptions.recognitionLanguages = preferred }

        let handler = ImageRequestHandler(cgImage, orientation: orientation)
        let observations = try await handler.perform(request)

        let orientedSize = orientedPixelSize(of: cgImage, orientation: orientation)
        let layouts = observations.map { layout(from: $0.document, orientedSize: orientedSize) }
        guard var combined = layouts.first else {
            // Vision found no document structure at all (blank page, photo of a wall). Return an empty layout so the page still gets created.
            return VisionDocumentLayout(
                imageWidth: Int(orientedSize.width), imageHeight: Int(orientedSize.height),
                transcript: "", title: nil, paragraphs: [], tables: [], lists: [], languages: []
            )
        }
        // One image normally yields one document; if Vision reports several (two sheets in one photo), keep them all, in the order reported.
        for extra in layouts.dropFirst() {
            if !extra.transcript.isEmpty {
                combined.transcript += (combined.transcript.isEmpty ? "" : "\n\n") + extra.transcript
            }
            combined.title = combined.title ?? extra.title
            combined.paragraphs += extra.paragraphs
            combined.tables += extra.tables
            combined.lists += extra.lists
            for language in extra.languages where !combined.languages.contains(language) { combined.languages.append(language) }
        }
        return combined
    }

    /// The user's preferred languages that Vision can recognize, in preference order, followed by English.
    static func preferredRecognitionLanguages(supported: [Locale.Language], preferredIdentifiers: [String] = Locale.preferredLanguages) -> [Locale.Language] {
        var result: [Locale.Language] = []
        func add(_ code: Locale.LanguageCode?) {
            guard let code, let match = supported.first(where: { $0.languageCode == code }),
                  !result.contains(where: { $0.languageCode == code }) else { return }
            result.append(match)
        }
        for identifier in preferredIdentifiers { add(Locale.Language(identifier: identifier).languageCode) }
        add(.english)
        return result
    }

    /// Builds the stored layout from a Vision container. Separate so a cell's nested container can reuse the paragraph/line mapping.
    private static func layout(from document: DocumentObservation.Container, orientedSize: CGSize) -> VisionDocumentLayout {
        let paragraphs: [VisionDocumentLayout.Paragraph] = document.paragraphs.map { paragraph in
            let lines: [VisionDocumentLayout.Line] = paragraph.lines.map { line in
                VisionDocumentLayout.Line(
                    text: line.transcript,
                    box: NormalizedBox(flippingVision: line.boundingRegion.boundingBox.cgRect)
                )
            }
            return VisionDocumentLayout.Paragraph(
                text: paragraph.transcript,
                box: NormalizedBox(flippingVision: paragraph.boundingRegion.boundingBox.cgRect),
                lines: lines
            )
        }

        let tables: [VisionDocumentLayout.Table] = document.tables.map { table in
            let rows: [[VisionDocumentLayout.TableCell]] = table.rows.map { row in
                row.map { cell in
                    VisionDocumentLayout.TableCell(
                        rowStart: cell.rowRange.lowerBound,
                        rowEnd: cell.rowRange.upperBound,
                        columnStart: cell.columnRange.lowerBound,
                        columnEnd: cell.columnRange.upperBound,
                        text: cell.content.text.transcript,
                        box: NormalizedBox(flippingVision: cell.content.boundingRegion.boundingBox.cgRect)
                    )
                }
            }
            return VisionDocumentLayout.Table(
                box: NormalizedBox(flippingVision: table.boundingRegion.boundingBox.cgRect),
                rows: rows
            )
        }

        let lists: [VisionDocumentLayout.ListBlock] = document.lists.map { list in
            VisionDocumentLayout.ListBlock(
                box: NormalizedBox(flippingVision: list.boundingRegion.boundingBox.cgRect),
                items: list.items.map(\.itemString)
            )
        }

        // Languages are reported per line; collect the distinct set in first-seen order.
        var languages: [String] = []
        for paragraph in document.paragraphs {
            for line in paragraph.lines {
                for language in line.recognitionLanguages {
                    let identifier = language.minimalIdentifier
                    if !languages.contains(identifier) { languages.append(identifier) }
                }
            }
        }

        return VisionDocumentLayout(
            imageWidth: Int(orientedSize.width),
            imageHeight: Int(orientedSize.height),
            transcript: document.text.transcript,
            title: document.title?.transcript,
            paragraphs: paragraphs,
            tables: tables,
            lists: lists,
            languages: languages
        )
    }

    /// Pixel size after applying `orientation` (90°/270° orientations swap width and height).
    static func orientedPixelSize(of cgImage: CGImage, orientation: CGImagePropertyOrientation) -> CGSize {
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return CGSize(width: cgImage.height, height: cgImage.width)
        default:
            return CGSize(width: cgImage.width, height: cgImage.height)
        }
    }

    /// EXIF orientation of the first image in `source` (`.up` when absent).
    static func exifOrientation(of source: CGImageSource) -> CGImagePropertyOrientation {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = properties[kCGImagePropertyOrientation] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: raw) else {
            return .up
        }
        return orientation
    }
}
