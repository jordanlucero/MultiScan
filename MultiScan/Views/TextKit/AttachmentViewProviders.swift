//
//  AttachmentViewProviders.swift
//  MultiScan
//
//  TextKit 2 view providers for MultiScan's inline attachments (artwork captures and tables), plus the small main-actor store the capture views read their pixels from.
//
//  ## How TextKit 2 shows an attachment as a *view*
//  1. `InlineAttachmentViewProviders.registerAll()` (called once at launch) registers a `NSTextAttachmentViewProvider` subclass per file type with `NSTextAttachment.registerViewProviderClass(_:forFileType:)`.
//  2. When a layout fragment containing an attachment is laid out, the text view asks the attachment for a provider (`viewProvider(for:location:textContainer:)`), which the framework instantiates from the registered class.
//  3. The provider's `loadView()` builds the platform view; `attachmentBounds(for:location:textContainer:proposedLineFragment:position:)` tells layout how much room it takes. The text view adds/removes the view as the fragment enters and leaves the viewport — only visible attachments have live views, so a page with many captures stays cheap.
//
//  Attachment views work identically in the editor, the export preview, and the Digest because all three are `PageTextView`s.
//
//  ## Data flow
//  Views never touch SwiftData. `CaptureImageStore` (main actor) holds a decoded thumbnail + metadata per capture uuid; `PageTextController` registers a page's captures when it loads and updates the store when a draft flag flips. A view that can't find its uuid in the store (a capture synced from another device whose asset hasn't arrived yet) shows a placeholder.
//
//  Interaction: clicking (macOS) / tapping (iOS) a capture opens a native menu — Mark as Draft, Recapture…, Remove — which the store forwards to its `actionHandler` (the live `PageTextController`). A menu rather than a SwiftUI popover because the view lives inside AppKit/UIKit text layout; anchoring a SwiftUI popover to a TextKit fragment is fragile.
//
//  ⚠️ Written without a compiler. `NSTextAttachmentViewProvider` API per the UIKit/AppKit docs: `init(textAttachment:parentView:textLayoutManager:location:)`, `loadView()`, `view`, `tracksTextAttachmentViewBounds`, `attachmentBounds(for:location:textContainer:proposedLineFragment:position:)`.
//

import Foundation
import CoreGraphics
import ImageIO
#if os(macOS)
import AppKit
typealias PlatformView = NSView
#else
import UIKit
typealias PlatformView = UIView
#endif

// MARK: - Registration

enum InlineAttachmentViewProviders {
    /// Registers the providers once per process. Call from `MultiScanApp.init`.
    static func registerAll() {
        NSTextAttachment.registerViewProviderClass(CaptureAttachmentViewProvider.self, forFileType: InlineAttachments.captureTypeIdentifier)
        NSTextAttachment.registerViewProviderClass(TableAttachmentViewProvider.self, forFileType: InlineAttachments.tableTypeIdentifier)
    }

    /// Layout constants shared by both providers.
    static let maximumWidth: CGFloat = 420
    static let verticalPadding: CGFloat = 6
}

// MARK: - Capture store

/// What a capture view needs to draw, decoded once per capture per process.
struct CaptureDisplayInfo {
    var thumbnail: CGImage?
    var aspectRatio: CGFloat
    var isDraft: Bool
    var caption: String?
}

/// Actions a capture attachment view can ask for. The live `PageTextController` is the handler.
protocol CaptureAttachmentActionHandling: AnyObject {
    func toggleDraft(forCapture id: UUID)
    func recapture(_ id: UUID)
    func removeCapture(_ id: UUID)
}

/// Process-wide, main-actor cache of capture thumbnails + flags, keyed by `PageCapture.uuid`.
@Observable
final class CaptureImageStore {
    static let shared = CaptureImageStore()

    /// Posted (on the main actor) when a capture's info changes; `object` is the `UUID`. Attachment views observe it to refresh their badge without re-laying-out text.
    nonisolated static let didChangeNotification = Notification.Name("co.jservices.MultiScan.captureInfoDidChange")

    @ObservationIgnored private var infos: [UUID: CaptureDisplayInfo] = [:]
    @ObservationIgnored weak var actionHandler: CaptureAttachmentActionHandling?

    private init() {}

    func info(for id: UUID) -> CaptureDisplayInfo? {
        infos[id]
    }

    /// Decodes the capture's thumbnail (small — ≤ 400 px) and remembers its flags.
    func register(_ capture: PageCapture) {
        guard let id = capture.uuid else { return }
        let thumbnail = capture.thumbnailData.flatMap(Self.decodeImage) ?? capture.imageData.flatMap(Self.decodeImage)
        let aspect: CGFloat
        if let thumbnail { aspect = CGFloat(thumbnail.width) / CGFloat(max(thumbnail.height, 1)) } else { aspect = capture.aspectRatio }
        infos[id] = CaptureDisplayInfo(thumbnail: thumbnail, aspectRatio: aspect, isDraft: capture.isDraft, caption: capture.caption)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: id)
    }

    func register(_ captures: [PageCapture]) {
        captures.forEach(register)
    }

    func update(_ id: UUID, isDraft: Bool) {
        guard var info = infos[id] else { return }
        info.isDraft = isDraft
        infos[id] = info
        NotificationCenter.default.post(name: Self.didChangeNotification, object: id)
    }

    func remove(_ id: UUID) {
        infos.removeValue(forKey: id)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: id)
    }

    private static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Thumbnail-with-transform honors EXIF so the view never shows a sideways crop.
        return PlatformImage.thumbnail(from: source, maxPixelSize: 800)
    }
}

// MARK: - Shared bounds math

private func attachmentBounds(aspectRatio: CGFloat, proposedLineFragment: CGRect, maximumWidth: CGFloat) -> CGRect {
    // Fill the line (minus a little breathing room), capped, and never wider than the container.
    let available = max(proposedLineFragment.width - 8, 40)
    let width = min(available, maximumWidth)
    let height = width / max(aspectRatio, 0.05)
    return CGRect(x: 0, y: 0, width: width, height: height + InlineAttachmentViewProviders.verticalPadding)
}

// MARK: - Capture provider

final class CaptureAttachmentViewProvider: NSTextAttachmentViewProvider {
    private var captureID: UUID? {
        guard let attachment = textAttachment, case .capture(let id) = InlineAttachments.kind(of: attachment) else { return nil }
        return id
    }

    override init(textAttachment: NSTextAttachment, parentView: PlatformView?, textLayoutManager: NSTextLayoutManager?, location: any NSTextLocation) {
        super.init(textAttachment: textAttachment, parentView: parentView, textLayoutManager: textLayoutManager, location: location)
        tracksTextAttachmentViewBounds = true
    }

    override func loadView() {
        let view = CaptureAttachmentView(captureID: captureID)
        self.view = view
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        let aspect = captureID.flatMap { CaptureImageStore.shared.info(for: $0)?.aspectRatio } ?? (4.0 / 3.0)
        return attachmentBounds(aspectRatio: aspect, proposedLineFragment: proposedLineFragment, maximumWidth: InlineAttachmentViewProviders.maximumWidth)
    }
}

// MARK: - Table provider

final class TableAttachmentViewProvider: NSTextAttachmentViewProvider {
    private var table: TextTableModel? {
        guard let attachment = textAttachment, case .table(let table) = InlineAttachments.kind(of: attachment) else { return nil }
        return table
    }

    override init(textAttachment: NSTextAttachment, parentView: PlatformView?, textLayoutManager: NSTextLayoutManager?, location: any NSTextLocation) {
        super.init(textAttachment: textAttachment, parentView: parentView, textLayoutManager: textLayoutManager, location: location)
        tracksTextAttachmentViewBounds = true
    }

    override func loadView() {
        self.view = TableAttachmentView(table: table ?? TextTableModel(rows: []))
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        let width = max(proposedLineFragment.width - 8, 40)
        let rows = CGFloat(max(table?.rowCount ?? 1, 1))
        let height = rows * TableAttachmentView.rowHeight + 2
        return CGRect(x: 0, y: 0, width: width, height: height + InlineAttachmentViewProviders.verticalPadding)
    }
}

// MARK: - Capture view

#if os(macOS)

/// Image + draft badge; click opens the capture menu.
final class CaptureAttachmentView: NSView {
    private let captureID: UUID?
    private let imageLayer = CALayer()
    private let badge = NSTextField(labelWithString: "")
    private var observer: NSObjectProtocol?

    init(captureID: UUID?) {
        self.captureID = captureID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        imageLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(imageLayer)

        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemOrange.cgColor
        badge.layer?.cornerRadius = 4
        badge.isHidden = true
        addSubview(badge)

        toolTip = String(localized: "Click for illustration options", comment: "Tooltip on an inline artwork capture")
        setAccessibilityRole(.image)
        reload()

        observer = NotificationCenter.default.addObserver(forName: CaptureImageStore.didChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let id = note.object as? UUID, id == self.captureID else { return }
            MainActor.assumeIsolated { self.reload() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func reload() {
        guard let captureID, let info = CaptureImageStore.shared.info(for: captureID) else {
            imageLayer.contents = nil
            badge.isHidden = true
            setAccessibilityLabel(String(localized: "Illustration (not yet downloaded)", comment: "Accessibility label for a capture whose image isn't available"))
            return
        }
        imageLayer.contents = info.thumbnail
        badge.isHidden = !info.isDraft
        badge.stringValue = "  " + String(localized: "DRAFT", comment: "Badge on a draft illustration capture") + "  "
        badge.sizeToFit()
        setAccessibilityLabel(info.caption ?? String(localized: "Illustration", comment: "Accessibility label for an inline capture"))
        setAccessibilityValue(info.isDraft ? String(localized: "Draft") : nil)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds.insetBy(dx: 0, dy: InlineAttachmentViewProviders.verticalPadding / 2)
        badge.frame.origin = NSPoint(x: 8, y: bounds.height - badge.frame.height - 8)
    }

    override func mouseDown(with event: NSEvent) {
        showMenu(at: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        showMenu(at: event)
    }

    private func showMenu(at event: NSEvent) {
        guard let captureID else { return }
        let isDraft = CaptureImageStore.shared.info(for: captureID)?.isDraft ?? false
        let menu = NSMenu()
        let draftItem = NSMenuItem(
            title: isDraft ? String(localized: "Clear Draft Flag") : String(localized: "Mark as Draft"),
            action: #selector(toggleDraft), keyEquivalent: ""
        )
        draftItem.target = self
        menu.addItem(draftItem)
        let recapture = NSMenuItem(title: String(localized: "Recapture…"), action: #selector(recapture), keyEquivalent: "")
        recapture.target = self
        menu.addItem(recapture)
        menu.addItem(.separator())
        let remove = NSMenuItem(title: String(localized: "Remove Illustration"), action: #selector(removeCapture), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func toggleDraft() { captureID.map { CaptureImageStore.shared.actionHandler?.toggleDraft(forCapture: $0) } }
    @objc private func recapture() { captureID.map { CaptureImageStore.shared.actionHandler?.recapture($0) } }
    @objc private func removeCapture() { captureID.map { CaptureImageStore.shared.actionHandler?.removeCapture($0) } }
}

/// A plain grid of labels. On the Mac this only shows when a table was *not* expanded into an NSTextTable (export preview of an unresolved attachment); the editor expands tables, see `TextTableRendering`.
final class TableAttachmentView: NSView {
    static let rowHeight: CGFloat = 22
    private let grid: NSGridView

    init(table: TextTableModel) {
        let rows: [[NSView]] = table.rows.enumerated().map { rowIndex, row in
            row.map { cellText in
                let label = NSTextField(labelWithString: cellText)
                label.font = (table.hasHeaderRow && rowIndex == 0) ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12)
                label.lineBreakMode = .byTruncatingTail
                return label
            }
        }
        grid = NSGridView(views: rows.isEmpty ? [[NSTextField(labelWithString: "")]] : rows)
        grid.rowSpacing = 2
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 4
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: InlineAttachmentViewProviders.verticalPadding / 2),
        ])
        setAccessibilityRole(.table)
        setAccessibilityLabel(String(localized: "Table with \(table.rowCount) rows and \(table.columnCount) columns", comment: "Accessibility label for an inline table"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

#else

/// Image + draft badge; tap opens the capture menu (a `UIButton` with `showsMenuAsPrimaryAction`).
final class CaptureAttachmentView: UIView {
    private let captureID: UUID?
    private let imageView = UIImageView()
    private let badge = UILabel()
    private let menuButton = UIButton(type: .custom)
    private var observer: NSObjectProtocol?

    init(captureID: UUID?) {
        self.captureID = captureID
        super.init(frame: .zero)
        layer.cornerRadius = 6
        clipsToBounds = true
        backgroundColor = .quaternarySystemFill

        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = false
        addSubview(imageView)

        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.textColor = .white
        badge.backgroundColor = .systemOrange
        badge.layer.cornerRadius = 4
        badge.clipsToBounds = true
        badge.textAlignment = .center
        badge.isHidden = true
        addSubview(badge)

        menuButton.showsMenuAsPrimaryAction = true
        menuButton.backgroundColor = .clear
        menuButton.accessibilityLabel = String(localized: "Illustration options")
        addSubview(menuButton)

        isAccessibilityElement = true
        accessibilityTraits = [.image, .button]
        reload()

        observer = NotificationCenter.default.addObserver(forName: CaptureImageStore.didChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let id = note.object as? UUID, id == self.captureID else { return }
            MainActor.assumeIsolated { self.reload() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func reload() {
        guard let captureID, let info = CaptureImageStore.shared.info(for: captureID) else {
            imageView.image = nil
            badge.isHidden = true
            accessibilityLabel = String(localized: "Illustration (not yet downloaded)", comment: "Accessibility label for a capture whose image isn't available")
            menuButton.menu = nil
            return
        }
        imageView.image = info.thumbnail.map { UIImage(cgImage: $0) }
        badge.isHidden = !info.isDraft
        badge.text = "  " + String(localized: "DRAFT", comment: "Badge on a draft illustration capture") + "  "
        badge.sizeToFit()
        accessibilityLabel = info.caption ?? String(localized: "Illustration", comment: "Accessibility label for an inline capture")
        accessibilityValue = info.isDraft ? String(localized: "Draft") : nil
        menuButton.menu = makeMenu(isDraft: info.isDraft)
        setNeedsLayout()
    }

    private func makeMenu(isDraft: Bool) -> UIMenu {
        UIMenu(children: [
            UIAction(title: isDraft ? String(localized: "Clear Draft Flag") : String(localized: "Mark as Draft"), image: UIImage(systemName: isDraft ? "flag.slash" : "flag")) { [captureID] _ in
                captureID.map { CaptureImageStore.shared.actionHandler?.toggleDraft(forCapture: $0) }
            },
            UIAction(title: String(localized: "Recapture…"), image: UIImage(systemName: "crop")) { [captureID] _ in
                captureID.map { CaptureImageStore.shared.actionHandler?.recapture($0) }
            },
            UIAction(title: String(localized: "Remove Illustration"), image: UIImage(systemName: "trash"), attributes: .destructive) { [captureID] _ in
                captureID.map { CaptureImageStore.shared.actionHandler?.removeCapture($0) }
            }
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds.insetBy(dx: 0, dy: InlineAttachmentViewProviders.verticalPadding / 2)
        badge.frame.origin = CGPoint(x: 8, y: 8 + InlineAttachmentViewProviders.verticalPadding / 2)
        menuButton.frame = bounds
    }
}

/// A plain grid of labels — read-only: UIKit has no text tables, so tables are edited on the Mac and viewed here.
final class TableAttachmentView: UIView {
    static let rowHeight: CGFloat = 22
    private let stack = UIStackView()

    init(table: TextTableModel) {
        super.init(frame: .zero)
        layer.borderColor = UIColor.separator.cgColor
        layer.borderWidth = 1
        layer.cornerRadius = 4
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (rowIndex, row) in table.rows.enumerated() {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = 12
            rowStack.distribution = .fillEqually
            for cellText in row {
                let label = UILabel()
                label.text = cellText
                label.font = (table.hasHeaderRow && rowIndex == 0) ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 13)
                label.lineBreakMode = .byTruncatingTail
                rowStack.addArrangedSubview(label)
            }
            stack.addArrangedSubview(rowStack)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: InlineAttachmentViewProviders.verticalPadding / 2),
        ])
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Table with \(table.rowCount) rows and \(table.columnCount) columns", comment: "Accessibility label for an inline table")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

#endif
