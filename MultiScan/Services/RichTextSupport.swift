//
//  RichTextSupport.swift
//  MultiScan
//
//  Rich text utilities and AttributedString extensions for macOS 26+
//

import Foundation
import SwiftUI

// MARK: - AttributedString Extensions

extension AttributedString {
    /// Creates an AttributedString from plain text (e.g., OCR output)
    init(plainText: String) {
        self.init(plainText)
    }

    /// Exports the attributed string to RTF data for clipboard operations
    func toRTFData() -> Data? {
        let nsAttributedString = NSAttributedString(self)
        return try? nsAttributedString.data(
            from: NSRange(location: 0, length: nsAttributedString.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
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

// MARK: - JSON Serialization Helpers

extension AttributedString {
    /// Encodes the attributed string to JSON data for SwiftData storage
    /// Uses SwiftUI attribute scope to preserve font formatting
    func encodeToJSON() throws -> Data {
        try JSONEncoder().encode(self, configuration: AttributeScopes.SwiftUIAttributes.self)
    }

    /// Decodes an attributed string from JSON data
    static func decodeFromJSON(_ data: Data) throws -> AttributedString {
        try JSONDecoder().decode(AttributedString.self, from: data, configuration: AttributeScopes.SwiftUIAttributes.self)
    }
}
