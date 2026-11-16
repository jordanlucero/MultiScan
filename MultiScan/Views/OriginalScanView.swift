//
//  OriginalScanView.swift
//  MultiScan
//
//  The whole scan a separated page was cut from, in a sheet: Edit ▸ Smart Separate ▸ View Original Scan… (and the same item in the page context menu and the iOS More menu).
//
//  A separated page shows one region of a `SharedScan`; this shows all of it, turned the way the page is displayed, with the page's region marked — everything else dimmed, both pages' regions outlined — so it is clear where Smart Separate cut and what, if anything, fell outside either page. "Show Page Regions" turns the marking off to see the bare scan. Nothing here changes the project.
//
//  The picture is shown in the same zoomable viewer as the main image (pinch, scroll-zoom, double-click), with its own `ImageZoomController`; the marking is drawn into the bitmap (`PlatformImage.markingRegions`) rather than layered on top, so it zooms and pans with the image for free.
//

import SwiftUI
import SwiftData

struct OriginalScanView: View {
    let page: Page
    @Environment(\.dismiss) private var dismiss

    @State private var image: ProcessedPageImage?
    @State private var didFail = false
    @State private var showsRegions = true
    @State private var zoomController = ImageZoomController()
    @AppStorage(DefaultsKey.viewerShowsHDR) private var viewerShowsHDR = true

    /// What the picture depends on; reloading is keyed on it.
    private struct Request: Equatable {
        var pageID: PersistentIdentifier
        var rotation: Int
        var showsRegions: Bool
    }

    private var request: Request {
        Request(pageID: page.persistentModelID, rotation: page.rotation, showsRegions: showsRegions)
    }

    /// The pages cut from this scan, first page first.
    private var pagesOfScan: [Page] {
        (page.sharedScan?.unwrappedPages ?? [page]).sorted {
            $0.splitPosition != $1.splitPosition ? $0.splitPosition < $1.splitPosition : $0.pageNumber < $1.pageNumber
        }
    }

    private var caption: String {
        let numbers = pagesOfScan.map(\.pageNumber)
        if numbers.count == 2 {
            return String(localized: "Pages \(numbers[0]) and \(numbers[1]) share this scan. Page \(page.pageNumber) shows the highlighted region.")
        }
        return String(localized: "Page \(page.pageNumber) shows the highlighted region of this scan.")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if let image {
                    GeometryReader { geometry in
                        ZoomableImageView(
                            image: image,
                            controller: zoomController,
                            displaysHDR: viewerShowsHDR,
                            safeAreaInsets: geometry.safeAreaInsets
                        )
                        .ignoresSafeArea()
                    }
                    .accessibilityLabel("Original scan")
                    .accessibilityValue(caption)
                } else if didFail {
                    ContentUnavailableView(
                        "Scan Unavailable",
                        systemImage: "photo",
                        description: Text("The original scan isn't available on this device yet.")
                    )
                } else {
                    ProgressView("Loading scan…")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if image != nil, showsRegions {
                    Text(caption)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect()
                        .padding(10)
                }
            }
            .navigationTitle(page.sharedScan?.originalFileName ?? String(localized: "Original Scan"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $showsRegions) {
                        Label("Show Page Regions", systemImage: "rectangle.split.2x1")
                    }
                    .help("Mark the part of the scan each page shows")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .task(id: request) { await load() }
        #if os(macOS)
        .frame(minWidth: 640, idealWidth: 960, minHeight: 480, idealHeight: 720)
        #endif
    }

    private func load() async {
        guard let data = page.sourceImageData else {
            didFail = true
            return
        }
        let rotation = page.rotation
        // Regions are stored on the upright scan; the picture is shown turned the way this page is.
        let regions = showsRegions
            ? pagesOfScan.compactMap { $0.imageCrop }.map { NormalizedGeometry.rotated($0, clockwise: rotation) }
            : []
        let highlighted = showsRegions ? page.imageCrop.map { NormalizedGeometry.rotated($0, clockwise: rotation) } : nil
        let accent = Self.accentColor

        let rendered = await Self.render(data, rotation: rotation, regions: regions, highlighted: highlighted, accent: accent)
        guard !Task.isCancelled else { return }
        if let rendered {
            // The same content identity across the regions toggle: the picture swaps in place and keeps its zoom.
            image = ProcessedPageImage(cgImage: rendered, contentID: .init(pageID: page.persistentModelID, rotation: rotation, crop: nil))
            didFail = false
        } else {
            didFail = true
        }
    }

    private static var accentColor: CGColor {
        #if os(macOS)
        NSColor.controlAccentColor.cgColor
        #else
        UIColor.tintColor.cgColor
        #endif
    }

    @concurrent
    private nonisolated static func render(_ data: Data, rotation: Int, regions: [CGRect], highlighted: CGRect?, accent: CGColor) async -> CGImage? {
        guard let whole = PlatformImage.processedCGImage(from: data, userRotation: rotation) else { return nil }
        guard !regions.isEmpty else { return whole }
        return PlatformImage.markingRegions(regions, highlighted: highlighted, accent: accent, on: whole) ?? whole
    }
}

#Preview("Separated page") {
    let container = previewContainer()

    // A stand-in for an open book: two "pages" of grey lines on paper.
    let width = 1200, height = 800
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.96, green: 0.95, blue: 0.91, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(gray: 0.25, alpha: 1))
    for column in [80, 660] {
        for line in 0..<26 {
            context.fill(CGRect(x: column, y: 90 + line * 24, width: line == 25 ? 180 : 460, height: 8))
        }
    }
    let data = PlatformImage.encode(context.makeImage()!, as: .jpeg, quality: 0.9)

    let document = Document(name: "Sample", totalPages: 2)
    container.mainContext.insert(document)
    let scan = SharedScan(imageData: data, originalFileName: "spread-014.jpg", document: document)
    container.mainContext.insert(scan)
    let left = Page(pageNumber: 3, text: "Left", imageData: nil)
    let right = Page(pageNumber: 4, text: "Right", imageData: nil)
    for (index, page) in [left, right].enumerated() {
        page.document = document
        document.pages?.append(page)
        page.sharedScan = scan
        page.splitPosition = index + 1
        page.imageCrop = index == 0 ? CGRect(x: 0.03, y: 0.06, width: 0.46, height: 0.88) : CGRect(x: 0.51, y: 0.06, width: 0.46, height: 0.88)
    }

    return OriginalScanView(page: right)
        .modelContainer(container)
}
