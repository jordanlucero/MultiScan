//
//  RichTextSupport.swift
//  MultiScan
//
//  Transferable rich text wrapper for ShareLink / pasteboard export.
//
//  RTF conversion is native: `NSAttributedString.data(from:documentAttributes:)`.
//  The wrapper stores pre-encoded, Sendable data (RTF bytes + plain text) so it can
//  cross actor boundaries and be exported from Transferable's async closures without
//  touching the non-Sendable NSAttributedString.
//

import Foundation
import CoreTransferable
import UniformTypeIdentifiers

// MARK: - Export Error Types

enum RichTextExportError: LocalizedError {
    case rtfConversionFailed
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .rtfConversionFailed: return "Failed to convert rich text to RTF"
        case .emptyContent: return "No content to export"
        }
    }
}

// MARK: - Transferable Rich Text Wrapper

/// A Sendable rich text payload that exports RTF (file + data) with a plain text fallback.
struct RichText: Transferable, Sendable {
    /// Pre-encoded RTF. Nil when conversion failed — file/data representations then
    /// throw at share time, and the plain text fallback still works.
    let rtfData: Data?
    let plainText: String

    /// Wraps an attributed string, encoding RTF eagerly.
    init(_ attributedString: NSAttributedString) {
        self.plainText = attributedString.string
        self.rtfData = RichTextArchiver.rtfData(from: attributedString)
    }

    /// Wraps already-encoded content (e.g., from the export pipeline).
    init(rtfData: Data?, plainText: String) {
        self.rtfData = rtfData
        self.plainText = plainText
    }

    static var transferRepresentation: some TransferRepresentation {
        // 1. File-based RTF for Finder, Save to Files, Notes, etc.
        FileRepresentation(exportedContentType: .rtf) { richText in
            let data = try richText.rtfDataOrThrow()
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("rtf")
            try data.write(to: tempURL)
            return SentTransferredFile(tempURL)
        }
        .suggestedFileName("Exported Text.rtf") // doesn't work

        // 2. Data-based RTF for clipboard operations (Copy)
        DataRepresentation(exportedContentType: .rtf) { richText in
            try richText.rtfDataOrThrow()
        }

        // 3. Plain text fallback
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
}
