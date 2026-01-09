//
//  RichTextSupport.swift
//  MultiScan
//
//  Rich text utilities and AttributedString extensions for macOS 26+
//

import Foundation
import SwiftUI
import CoreText
import UniformTypeIdentifiers

// MARK: - Transferable Rich Text Wrapper

/// A wrapper around AttributedString that properly exports rich text formatting via ShareLink.
/// Converts SwiftUI Font attributes to Foundation font attributes for RTF export.
struct RichText: Transferable {
    let attributedString: AttributedString

    init(_ attributedString: AttributedString) {
        self.attributedString = attributedString
    }

    static var transferRepresentation: some TransferRepresentation {
        // Primary: RTF with full formatting
        DataRepresentation(exportedContentType: .rtf) { richText in
            richText.toRTFData() ?? Data()
        }
        // Fallback: Plain text
        DataRepresentation(exportedContentType: .plainText) { richText in
            Data(String(richText.attributedString.characters).utf8)
        }
    }

    /// Converts the AttributedString to RTF data, properly handling SwiftUI Font attributes
    func toRTFData() -> Data? {
        let nsAttributedString = convertToNSAttributedString(attributedString)

        return try? nsAttributedString.data(
            from: NSRange(location: 0, length: nsAttributedString.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    /// Converts SwiftUI AttributedString to NSAttributedString with proper font conversion using CoreText
    private func convertToNSAttributedString(_ source: AttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseFont = CTFontCreateWithName("Helvetica" as CFString, 13.0, nil)

        for run in source.runs {
            let text = String(source[run.range].characters)
            var attributes: [NSAttributedString.Key: Any] = [:]

            // Detect bold/italic from SwiftUI Font and create CoreText font with traits
            var traits: CTFontSymbolicTraits = []
            if let font = run.font {
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

