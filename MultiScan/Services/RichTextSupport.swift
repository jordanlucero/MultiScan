//
//  RichTextSupport.swift
//  MultiScan
//
//  Transferable rich text wrapper for ShareLink / pasteboard / Save As export.
//
//  ## What the share sheet gets (2.0 export fix)
//  The 2.0 share path offered a `FileRepresentation` first. Transferable picks the *first* representation a destination accepts, and almost everything accepts a file URL — so Messages, Notes, and Mail all received a temp file named after a UUID (`SentTransferredFile` keeps the URL's own name; `.suggestedFileName` doesn't rename it). Users wanted the *text*.
//
//  Now the representations are ordered **data first, file never** for sharing:
//  1. RTFD data (only when the text has attachments) — rich text with embedded images, for destinations that take rich pasteboard data (Notes, Pages, Mail on macOS).
//  2. RTF data — rich text for everything else that understands it.
//  3. Plain text (`ProxyRepresentation` to `String`) — the universal fallback (Messages, search fields, terminals).
//  Saving to a *file* is an explicit action instead: `RichTextFileDocument` + SwiftUI's `fileExporter`, which lets the user pick the location and gets a real default filename (the project name).
//
//  The wrapper is a **Sendable value**: RTF/RTFD are encoded eagerly, so it can cross actor boundaries and export from Transferable's async closures without touching a live `NSAttributedString`.
//

import Foundation
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Export Error Types

/// Conforms to `CustomLocalizedStringResourceConvertible` as well as `LocalizedError`: the App Intents framework routes thrown errors by type and keys on the former, so a `LocalizedError` alone would surface as a generic failure in Siri/Shortcuts.
nonisolated enum RichTextExportError: LocalizedError, CustomLocalizedStringResourceConvertible {
    case rtfConversionFailed
    case emptyContent

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .rtfConversionFailed: "Failed to convert rich text to RTF."
        case .emptyContent: "There is no text to export."
        }
    }

    var errorDescription: String? {
        String(localized: localizedStringResource)
    }
}

// MARK: - Transferable Rich Text Wrapper

/// A Sendable rich text payload that shares RTFD/RTF data with a plain text fallback.
/// `nonisolated`: Transferable's export closures run off the main actor.
nonisolated struct RichText: Transferable, Sendable {
    /// Pre-encoded RTF (attachments dropped). Nil when conversion failed — the RTF representation then throws at share time, and the plain text fallback still works.
    let rtfData: Data?
    /// Pre-encoded flattened RTFD with real image attachments, when the content has any. Nil for text-only content.
    let rtfdData: Data?
    let plainText: String
    /// Suggested base name for files ("My Book" → "My Book.rtf"); the project or page title.
    let suggestedName: String

    /// Wraps an attributed string, encoding RTF (and RTFD when it carries attachments) eagerly.
    init(_ attributedString: NSAttributedString, suggestedName: String = String(localized: "Exported Text", comment: "Default export file name")) {
        self.plainText = attributedString.string.strippingAttachmentCharacters()
        self.rtfData = RichTextArchiver.rtfData(from: attributedString)
        self.rtfdData = RichTextArchiver.containsAttachments(attributedString) ? RichTextArchiver.rtfdData(from: attributedString) : nil
        self.suggestedName = suggestedName
    }

    /// Wraps already-encoded content (e.g., from the export pipeline).
    init(rtfData: Data?, rtfdData: Data? = nil, plainText: String, suggestedName: String = String(localized: "Exported Text", comment: "Default export file name")) {
        self.rtfData = rtfData
        self.rtfdData = rtfdData
        self.plainText = plainText
        self.suggestedName = suggestedName
    }

    static var transferRepresentation: some TransferRepresentation {
        // 1. Rich text with embedded images — only offered when the content actually has attachments.
        DataRepresentation(exportedContentType: .rtfd) { richText in
            guard let rtfd = richText.rtfdData, !rtfd.isEmpty else { throw RichTextExportError.rtfConversionFailed }
            return rtfd
        }
        .exportingCondition { $0.rtfdData != nil }

        // 2. Rich text (data, not a file) for Notes, Pages, Mail, TextEdit…
        DataRepresentation(exportedContentType: .rtf) { richText in
            try richText.rtfDataOrThrow()
        }

        // 3. Plain text: works everywhere.
        ProxyRepresentation { richText in
            richText.plainText
        }
    }

    /// Returns the RTF data with proper error handling.
    func rtfDataOrThrow() throws -> Data {
        guard !plainText.isEmpty else {
            throw RichTextExportError.emptyContent
        }
        guard let rtfData, !rtfData.isEmpty else {
            throw RichTextExportError.rtfConversionFailed
        }
        return rtfData
    }

    /// The richest file payload: RTFD when there are images, RTF otherwise.
    var preferredFileType: UTType { rtfdData != nil ? .rtfd : .rtf }

    /// A sanitized filename (no path separators / colons), without extension.
    var fileBaseName: String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = suggestedName.components(separatedBy: forbidden).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? String(localized: "Exported Text", comment: "Default export file name") : String(cleaned.prefix(120))
    }
}

// MARK: - Pasteboard

extension RichText {
    /// Copies RTF (+ RTFD when present) and plain text to the general pasteboard. Main actor: pasteboards are UI state.
    @MainActor
    func copyToPasteboard() {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let rtfdData { pasteboard.setData(rtfdData, forType: .rtfd) }
        if let rtfData { pasteboard.setData(rtfData, forType: .rtf) }
        pasteboard.setString(plainText, forType: .string)
        #else
        var items: [String: Any] = [UTType.plainText.identifier: plainText]
        if let rtfData { items[UTType.rtf.identifier] = rtfData }
        if let rtfdData { items[UTType.rtfd.identifier] = rtfdData }
        UIPasteboard.general.items = [items]
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
}

// MARK: - Save As… (fileExporter)

/// A `FileDocument` over a `RichText`, so `.fileExporter` can write it with a user-chosen name and location. Write-only: MultiScan never opens these files.
nonisolated struct RichTextFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = []
    static let writableContentTypes: [UTType] = [.rtfd, .rtf, .plainText]

    let richText: RichText
    let contentType: UTType

    init(richText: RichText, contentType: UTType) {
        self.richText = richText
        self.contentType = contentType
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        switch contentType {
        case .rtfd:
            guard let rtfd = richText.rtfdData else { return FileWrapper(regularFileWithContents: try richText.rtfDataOrThrow()) }
            // A flattened RTFD *is* a serialized FileWrapper (package). Unflatten so the exporter writes a real .rtfd bundle.
            if let package = FileWrapper(serializedRepresentation: rtfd) { return package }
            return FileWrapper(regularFileWithContents: rtfd)
        case .plainText:
            return FileWrapper(regularFileWithContents: Data(richText.plainText.utf8))
        default:
            return FileWrapper(regularFileWithContents: try richText.rtfDataOrThrow())
        }
    }
}
