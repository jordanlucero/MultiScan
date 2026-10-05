//
//  InlineAttachments.swift
//  MultiScan
//
//  The two kinds of inline object MultiScan places in page text, and how they are persisted.
//
//  ## Reference attachments
//  Both are `NSTextAttachment`s whose payload is a small file with a MultiScan-specific UTType (declared in `Info.plist` under `UTExportedTypeDeclarations`):
//
//  | Kind    | UTType                            | Extension          | Contents                        |
//  |---------|-----------------------------------|--------------------|---------------------------------|
//  | Capture | `co.jservices.multiscan.capture`  | `.multiscancapture`| the `PageCapture.uuid` (UTF-8)  |
//  | Table   | `co.jservices.multiscan.table`    | `.multiscantable`  | `TextTableModel` as JSON        |
//
//  RTFD serializes each attachment as a file inside the package and restores it as a plain `NSTextAttachment` with a `fileWrapper` — subclasses do **not** survive the round trip, which is why identity lives in the file type + contents, not in a Swift type. `kind(of:)` classifies any attachment coming out of `RichTextArchiver.decodeRTFD`.
//
//  Rendering is handled by `NSTextAttachmentViewProvider` subclasses registered per file type (`AttachmentViewProviders.swift`), so TextKit 2 asks us for a view wherever one of these appears — in the editor, the export preview, and the Digest alike.
//
//  Why references and not pixels: see `PageCapture.swift`.
//

import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Table model

/// A simple rectangular text table — what Vision's table detection, a markdown table from a transformer OCR engine, or a user edit produce. Cells are plain strings; formatting inside cells is out of scope for 2.1.
nonisolated struct TextTableModel: Codable, Sendable, Equatable, Hashable {
    static let currentVersion = 1

    var version: Int = currentVersion
    /// `rows[r][c]`; every row is padded to `columnCount` on init so consumers can index freely.
    var rows: [[String]]
    /// Whether the first row is a header (markdown tables always have one; Vision tables usually do).
    var hasHeaderRow: Bool

    init(rows: [[String]], hasHeaderRow: Bool = true) {
        let width = rows.map(\.count).max() ?? 0
        self.rows = rows.map { row in
            row + Array(repeating: "", count: max(0, width - row.count))
        }
        self.hasHeaderRow = hasHeaderRow
    }

    var rowCount: Int { rows.count }
    var columnCount: Int { rows.first?.count ?? 0 }
    var isEmpty: Bool { rows.isEmpty || columnCount == 0 }

    /// Tab-separated rows, newline-separated — the plain-text/iOS export form and what search should see.
    var tabSeparatedText: String {
        rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
    }

    /// GitHub-flavored markdown, for Digest copy and for round-tripping through markdown-based engines.
    var markdown: String {
        guard !isEmpty else { return "" }
        var lines: [String] = []
        let header = hasHeaderRow ? rows[0] : Array(repeating: "", count: columnCount)
        lines.append("| " + header.map(escapeCell).joined(separator: " | ") + " |")
        lines.append("|" + Array(repeating: " --- |", count: columnCount).joined())
        for row in rows.dropFirst(hasHeaderRow ? 1 : 0) {
            lines.append("| " + row.map(escapeCell).joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    private func escapeCell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(_ data: Data?) -> TextTableModel? {
        guard let data, let table = try? JSONDecoder().decode(TextTableModel.self, from: data), table.version == currentVersion else { return nil }
        return table
    }

    /// From a Vision table: merged cells are placed at their start row/column; other covered slots stay empty.
    init(visionTable table: VisionDocumentLayout.Table) {
        let rowCount = table.rowCount
        let columnCount = table.columnCount
        var grid = Array(repeating: Array(repeating: "", count: max(columnCount, 0)), count: max(rowCount, 0))
        for row in table.rows {
            for cell in row where cell.rowStart < rowCount && cell.columnStart < columnCount {
                grid[cell.rowStart][cell.columnStart] = cell.text
            }
        }
        self.init(rows: grid, hasHeaderRow: rowCount > 1)
    }
}

// MARK: - Attachment kinds

/// Classification of an `NSTextAttachment` found in page text.
nonisolated enum InlineAttachmentKind: Equatable {
    case capture(UUID)
    case table(TextTableModel)
    /// A real image (e.g. pasted by the user, or an exported document re-imported). Not produced by MultiScan's own UI yet.
    case image
    case unknown
}

nonisolated enum InlineAttachments {

    // MARK: Type identifiers

    static let captureTypeIdentifier = "co.jservices.multiscan.capture"
    static let captureFileExtension = "multiscancapture"
    static let tableTypeIdentifier = "co.jservices.multiscan.table"
    static let tableFileExtension = "multiscantable"

    static var captureType: UTType { UTType(captureTypeIdentifier) ?? UTType(exportedAs: captureTypeIdentifier) }
    static var tableType: UTType { UTType(tableTypeIdentifier) ?? UTType(exportedAs: tableTypeIdentifier) }

    // MARK: Creating attachments

    /// A reference attachment for `capture`. `aspectRatio` seeds `bounds` so layout is right before the view provider loads.
    static func makeCaptureAttachment(captureID: UUID) -> NSTextAttachment {
        let contents = Data(captureID.uuidString.utf8)
        let attachment = NSTextAttachment(data: contents, ofType: captureTypeIdentifier)
        let wrapper = FileWrapper(regularFileWithContents: contents)
        wrapper.preferredFilename = "capture-\(captureID.uuidString).\(captureFileExtension)"
        attachment.fileWrapper = wrapper
        return attachment
    }

    /// A reference attachment holding `table`.
    static func makeTableAttachment(_ table: TextTableModel) -> NSTextAttachment? {
        guard let contents = table.encoded() else { return nil }
        let attachment = NSTextAttachment(data: contents, ofType: tableTypeIdentifier)
        let wrapper = FileWrapper(regularFileWithContents: contents)
        wrapper.preferredFilename = "table-\(UUID().uuidString).\(tableFileExtension)"
        attachment.fileWrapper = wrapper
        return attachment
    }

    /// An attributed string containing just the attachment, on `font` so line height around it is sane. Insert this into page text.
    static func attributedString(for attachment: NSTextAttachment, font: PlatformFont) -> NSAttributedString {
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font, value: font, range: NSRange(location: 0, length: result.length))
        return result
    }

    // MARK: Classifying attachments

    /// Works for attachments we just created (`contents` + `fileType`) and for attachments restored from RTFD (`fileWrapper` with filename and contents).
    static func kind(of attachment: NSTextAttachment) -> InlineAttachmentKind {
        let contents = attachment.contents ?? attachment.fileWrapper?.regularFileContents
        let typeIdentifier = attachment.fileType
        let fileExtension = attachment.fileWrapper?.preferredFilename.map { ($0 as NSString).pathExtension.lowercased() }
            ?? attachment.fileWrapper?.filename.map { ($0 as NSString).pathExtension.lowercased() }

        if typeIdentifier == captureTypeIdentifier || fileExtension == captureFileExtension {
            if let contents, let string = String(data: contents, encoding: .utf8), let uuid = UUID(uuidString: string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return .capture(uuid)
            }
            return .unknown
        }
        if typeIdentifier == tableTypeIdentifier || fileExtension == tableFileExtension {
            if let table = TextTableModel.decode(contents) {
                return .table(table)
            }
            return .unknown
        }
        if attachment.image != nil {
            return .image
        }
        if let typeIdentifier, let type = UTType(typeIdentifier), type.conforms(to: .image) {
            return .image
        }
        return .unknown
    }

    /// Every capture uuid referenced by `text`, in document order.
    static func captureIDs(in text: NSAttributedString) -> [UUID] {
        var ids: [UUID] = []
        enumerateAttachments(in: text) { attachment, _ in
            if case .capture(let id) = kind(of: attachment) { ids.append(id) }
        }
        return ids
    }

    /// Range of the attachment referencing `captureID`, if present.
    static func range(ofCapture captureID: UUID, in text: NSAttributedString) -> NSRange? {
        var found: NSRange?
        enumerateAttachments(in: text) { attachment, range in
            if found == nil, case .capture(let id) = kind(of: attachment), id == captureID { found = range }
        }
        return found
    }

    static func enumerateAttachments(in text: NSAttributedString, _ body: (NSTextAttachment, NSRange) -> Void) {
        guard text.length > 0 else { return }
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length), options: .longestEffectiveRangeNotRequired) { value, range, _ in
            if let attachment = value as? NSTextAttachment { body(attachment, range) }
        }
    }

    /// The plain text to store in `Page.plainText` / cache entries / Spotlight: captures vanish, tables become tab-separated text (so their cells are searchable). Cheap when there are no attachments.
    static func searchablePlainText(of text: NSAttributedString) -> String {
        guard RichTextArchiver.containsAttachments(text) else { return text.string }
        return flattenedToText(text, captureLabel: { _ in "" }).string.strippingAttachmentCharacters()
    }

    /// Replaces every reference attachment in `text` with a plain-text rendering (`[Illustration]`, tab-separated table) — the fallback for destinations that can't show attachments (plain-text share, Spotlight, iOS RTF export of tables).
    static func flattenedToText(_ text: NSAttributedString, captureLabel: (UUID) -> String) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        var replacements: [(NSRange, String)] = []
        enumerateAttachments(in: result) { attachment, range in
            switch kind(of: attachment) {
            case .capture(let id): replacements.append((range, captureLabel(id)))
            case .table(let table): replacements.append((range, "\n" + table.tabSeparatedText + "\n"))
            case .image, .unknown: replacements.append((range, ""))
            }
        }
        // Back to front so earlier ranges stay valid.
        for (range, replacement) in replacements.reversed() {
            let attributes = result.attributes(at: range.location, effectiveRange: nil).filter { $0.key != .attachment }
            result.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: attributes))
        }
        return result
    }
}
