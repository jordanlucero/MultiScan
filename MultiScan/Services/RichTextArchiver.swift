//
//  RichTextArchiver.swift
//  MultiScan
//
//  Canonical rich text persistence for the TextKit 2 text engine.
//
//  ## Storage Format
//  Page text is persisted as **RTF data** in `Page.richTextData`:
//  - RTF is `NSAttributedString`'s native document format — encode/decode is a single
//    framework call on both AppKit and UIKit, with no manual attribute mapping.
//  - RTF round-trips fonts, bold/italic traits, underline/strikethrough, paragraph
//    styles, and (on macOS) `NSTextTable`/`NSTextTableBlock` — the planned inline
//    table feature serializes through this format with no storage changes.
//  - It remains a plain `Data` blob, so CloudKit external storage (CKAsset) and the
//    SwiftData schema are unaffected.
//
//  ## Legacy Migration
//  Versions prior to 2.0 stored JSON-encoded SwiftUI `AttributedString` (Codable).
//  `attributedString(from:)` sniffs the format: RTF data always begins with `{\rtf`;
//  anything else is decoded through the legacy JSON path and converted to an
//  `NSAttributedString`, mapping the old SwiftUI attributes (inlinePresentationIntent,
//  SwiftUI Font, underline/strikethrough styles) onto platform equivalents.
//  Migration is lazy: reads accept both formats forever, writes always produce RTF.
//
//  ## Font Normalization
//  Fonts are normalized at the storage boundary so content is portable:
//  - **Storage/export font**: Helvetica Neue at 13 pt (resolvable by every word
//    processor; the app's historical export font).
//  - **Display font**: the platform body font, applied when text is loaded into the
//    editor. Bold/italic traits survive both directions; all other attributes pass
//    through untouched.
//

import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Platform Typealiases

#if os(macOS)
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#else
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#endif

// MARK: - Text Style Configuration

/// Font configuration for page text at each boundary of the pipeline.
enum PageTextStyle {
    /// Font family stored in RTF and used for export. Chosen for word processor
    /// compatibility (system fonts encode as private names like ".SFNS" that other
    /// apps cannot resolve).
    static let storageFontName = "Helvetica Neue"
    static let storageFontSize: CGFloat = 13

    /// The canonical font written to persisted RTF and exported documents.
    static var storageFont: PlatformFont {
        PlatformFont(name: storageFontName, size: storageFontSize)
            ?? .systemFont(ofSize: storageFontSize)
    }

    /// The font used for on-screen editing — platform body metrics so the editor
    /// feels native on each device.
    static var displayFont: PlatformFont {
        #if os(macOS)
        return .systemFont(ofSize: NSFont.systemFontSize)
        #else
        return .preferredFont(forTextStyle: .body)
        #endif
    }
}

// MARK: - Font Trait Helpers

extension PlatformFont {
    var isBold: Bool {
        #if os(macOS)
        fontDescriptor.symbolicTraits.contains(.bold)
        #else
        fontDescriptor.symbolicTraits.contains(.traitBold)
        #endif
    }

    var isItalic: Bool {
        #if os(macOS)
        fontDescriptor.symbolicTraits.contains(.italic)
        #else
        fontDescriptor.symbolicTraits.contains(.traitItalic)
        #endif
    }

    /// Returns a copy of this font with the given traits applied or removed.
    /// Falls back to the original font if the family has no matching face.
    func applyingTraits(bold: Bool, italic: Bool) -> PlatformFont {
        #if os(macOS)
        var traits = fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) } else { traits.remove(.bold) }
        if italic { traits.insert(.italic) } else { traits.remove(.italic) }
        let descriptor = fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
        #else
        var traits = fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) } else { traits.remove(.traitBold) }
        if italic { traits.insert(.traitItalic) } else { traits.remove(.traitItalic) }
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
        #endif
    }
}

// MARK: - Archiver

enum RichTextArchiver {

    // MARK: Encoding

    /// Encodes an attributed string as RTF data. Returns nil only if the framework
    /// conversion fails (should not happen for text-only content).
    static func rtfData(from attributedString: NSAttributedString) -> Data? {
        try? attributedString.data(
            from: NSRange(location: 0, length: attributedString.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    // MARK: Decoding (format-sniffing)

    /// Decodes persisted page text, accepting both the current RTF format and the
    /// legacy JSON-encoded `AttributedString` format. Returns an empty string for
    /// nil or undecodable data.
    static func attributedString(from data: Data?) -> NSAttributedString {
        guard let data, !data.isEmpty else { return NSAttributedString() }

        if isRTF(data), let decoded = decodeRTF(data) {
            return decoded
        }
        if let legacy = decodeLegacyJSON(data) {
            return legacy
        }
        print("⚠️ RichTextArchiver: unrecognized rich text data format (\(data.count) bytes)")
        return NSAttributedString()
    }

    /// RTF documents always begin with the ASCII bytes `{\rtf`.
    static func isRTF(_ data: Data) -> Bool {
        let magic: [UInt8] = [0x7B, 0x5C, 0x72, 0x74, 0x66] // "{\rtf"
        guard data.count >= magic.count else { return false }
        return data.prefix(magic.count).elementsEqual(magic)
    }

    /// Decodes RTF data. Safe off the main thread (RTF import does not use WebKit).
    static func decodeRTF(_ data: Data) -> NSAttributedString? {
        try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
    }

    /// Extracts plain text from persisted data (search, statistics, TTS).
    static func plainText(from data: Data?) -> String {
        attributedString(from: data).string
    }

    // MARK: Legacy JSON Decoding (pre-2.0 format)

    /// Decodes the pre-2.0 JSON-encoded SwiftUI `AttributedString` format and converts
    /// it to an `NSAttributedString` on the canonical storage font. Bold/italic come
    /// from `inlinePresentationIntent` (Markdown-style) or the SwiftUI `Font` attribute
    /// (set by the old formatting toolbar); underline/strikethrough map directly.
    static func decodeLegacyJSON(_ data: Data) -> NSAttributedString? {
        guard let legacy = try? JSONDecoder().decode(AttributedString.self, from: data) else {
            return nil
        }

        let result = NSMutableAttributedString()
        let baseFont = PageTextStyle.storageFont

        for run in legacy.runs {
            let text = String(legacy[run.range].characters)
            var bold = false
            var italic = false

            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { bold = true }
                if intent.contains(.emphasized) { italic = true }
            }

            if !bold, !italic, let font = run.font {
                let resolved = font.resolve(in: EnvironmentValues().fontResolutionContext)
                bold = resolved.isBold
                italic = resolved.isItalic
            }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: baseFont.applyingTraits(bold: bold, italic: italic)
            ]
            if run.underlineStyle != nil {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if run.strikethroughStyle != nil {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }

            result.append(NSAttributedString(string: text, attributes: attributes))
        }

        return result
    }

    // MARK: Font Normalization

    /// Returns a copy with every run's font replaced by `baseFont` carrying that run's
    /// bold/italic traits, and display-only colors stripped. All other attributes
    /// (underline, strikethrough, paragraph styles, future text tables) pass through.
    static func normalizing(_ attributedString: NSAttributedString, to baseFont: PlatformFont) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: attributedString)
        let fullRange = NSRange(location: 0, length: result.length)

        result.removeAttribute(.foregroundColor, range: fullRange)
        result.removeAttribute(.backgroundColor, range: fullRange)

        result.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            let existing = value as? PlatformFont
            let normalized = baseFont.applyingTraits(
                bold: existing?.isBold ?? false,
                italic: existing?.isItalic ?? false
            )
            result.addAttribute(.font, value: normalized, range: range)
        }

        return result
    }

    /// Normalizes editor content for persistence (canonical storage font).
    static func normalizedForStorage(_ attributedString: NSAttributedString) -> NSAttributedString {
        normalizing(attributedString, to: PageTextStyle.storageFont)
    }

    /// Normalizes persisted content for on-screen editing (platform body font + label color).
    static func normalizedForDisplay(_ attributedString: NSAttributedString) -> NSAttributedString {
        applyingDisplayColor(normalizing(attributedString, to: PageTextStyle.displayFont))
    }

    /// Stamps the dynamic label color onto every run. Text views render runs without a
    /// `.foregroundColor` attribute in default black regardless of appearance, so display
    /// paths must set it explicitly; the dynamic system color then adapts to light/dark
    /// at draw time. `normalizedForStorage` strips it again, so it never persists.
    static func applyingDisplayColor(_ attributedString: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: attributedString)
        let fullRange = NSRange(location: 0, length: result.length)
        #if os(macOS)
        result.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)
        #else
        result.addAttribute(.foregroundColor, value: UIColor.label, range: fullRange)
        #endif
        return result
    }
}
