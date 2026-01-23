//  Rich text utilities and AttributedString extensions for macOS 26+ aligned releases

import Foundation
import SwiftUI
import CoreText
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

/// A wrapper around AttributedString that properly exports rich text formatting via ShareLink.
/// Converts SwiftUI Font attributes to Foundation font attributes for RTF export.
struct RichText: Transferable {
    let attributedString: AttributedString

    init(_ attributedString: AttributedString) {
        self.attributedString = attributedString
    }

    static var transferRepresentation: some TransferRepresentation {
        // 1. File-based RTF for Finder, Save to Files, Notes, etc.
        FileRepresentation(exportedContentType: .rtf) { richText in
            let data = try richText.toRTFDataOrThrow()
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("rtf")
            try data.write(to: tempURL)
            return SentTransferredFile(tempURL)
        }
        .suggestedFileName("Exported Text.rtf")

        // 2. Data-based RTF for clipboard operations (Copy)
        DataRepresentation(exportedContentType: .rtf) { richText in
            try richText.toRTFDataOrThrow()
        }

        // 3. Plain text fallback - works everywhere
        ProxyRepresentation { richText in
            String(richText.attributedString.characters)
        }
    }

    /// Converts the AttributedString to RTF data with proper error handling
    func toRTFDataOrThrow() throws -> Data {
        guard !attributedString.characters.isEmpty else {
            throw RichTextExportError.emptyContent
        }

        let nsAttributedString = convertToNSAttributedString(attributedString)

        guard let data = try? nsAttributedString.data(
            from: NSRange(location: 0, length: nsAttributedString.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ), !data.isEmpty else {
            throw RichTextExportError.rtfConversionFailed
        }

        return data
    }

    /// Converts the AttributedString to RTF data, returning nil on failure (legacy method)
    func toRTFData() -> Data? {
        try? toRTFDataOrThrow()
    }

    /// Converts SwiftUI AttributedString to NSAttributedString with proper font conversion using CoreText
    private func convertToNSAttributedString(_ source: AttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseFont = CTFontCreateWithName("Helvetica Neue" as CFString, 13.0, nil)

        for run in source.runs {
            let text = String(source[run.range].characters)
            var attributes: [NSAttributedString.Key: Any] = [:]

            // Detect bold/italic from SwiftUI attributes
            var traits: CTFontSymbolicTraits = []

            // First check inlinePresentationIntent (more reliable for semantic formatting)
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { traits.insert(.boldTrait) }
                if intent.contains(.emphasized) { traits.insert(.italicTrait) }
            }

            // Fallback: check SwiftUI Font if inlinePresentationIntent not set
            if traits.isEmpty, let font = run.font {
                let resolved = font.resolve(in: EnvironmentValues().fontResolutionContext)
                if resolved.isBold { traits.insert(.boldTrait) }
                if resolved.isItalic { traits.insert(.italicTrait) }
            }

            // Create font with appropriate traits using CoreText
            if !traits.isEmpty,
               let styledFont = CTFontCreateCopyWithSymbolicTraits(baseFont, 0, nil, traits, traits) {
                attributes[.font] = styledFont
            } else {
                attributes[.font] = baseFont
            }

            // Copy underline style
            if run.underlineStyle != nil {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }

            // Copy strikethrough style
            if run.strikethroughStyle != nil {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }

            result.append(NSAttributedString(string: text, attributes: attributes))
        }

        return result
    }
}

// MARK: - AttributedString Extensions

extension AttributedString {
    /// Creates an AttributedString from plain text (e.g., OCR output)
    init(plainText: String) {
        self.init(plainText)
    }

    /// Returns the plain text content without formatting
    var plainText: String {
        String(characters)
    }

    /// Checks if the given range has bold formatting
    func isBold(at range: Range<AttributedString.Index>) -> Bool {
        guard let font = self[range].font else { return false }
        let resolved = font.resolve(in: EnvironmentValues().fontResolutionContext)
        return resolved.isBold
    }

    /// Checks if the given range has italic formatting
    func isItalic(at range: Range<AttributedString.Index>) -> Bool {
        guard let font = self[range].font else { return false }
        let resolved = font.resolve(in: EnvironmentValues().fontResolutionContext)
        return resolved.isItalic
    }

    /// Toggles bold formatting on the given range
    mutating func toggleBold(in range: Range<AttributedString.Index>) {
        let currentlyBold = isBold(at: range)
        let currentlyItalic = isItalic(at: range)

        if currentlyBold {
            self[range].font = currentlyItalic ? .body.italic() : nil
        } else {
            self[range].font = currentlyItalic ? .body.bold().italic() : .body.bold()
        }
    }

    /// Toggles italic formatting on the given range
    mutating func toggleItalic(in range: Range<AttributedString.Index>) {
        let currentlyBold = isBold(at: range)
        let currentlyItalic = isItalic(at: range)

        if currentlyItalic {
            self[range].font = currentlyBold ? .body.bold() : nil
        } else {
            self[range].font = currentlyBold ? .body.bold().italic() : .body.italic()
        }
    }
}

