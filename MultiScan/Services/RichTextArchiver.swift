//
//  RichTextArchiver.swift
//  MultiScan
//
//  Canonical rich text persistence for the TextKit 2 text engine.
//
//  ## Storage Format
//  Page text is persisted in `Page.richTextData` as:
//  - **RTF** when the text is text-only — `NSAttributedString`'s native document format; encode/decode is one framework call on both AppKit and UIKit, and it round-trips fonts, bold/italic traits, underline/strikethrough, and paragraph styles.
//  - **RTFD** (a *flattened* RTFD package — `NSFileWrapper`'s serialized representation) when the text contains inline attachments. RTF has no way to carry attachments; RTFD stores each one as a file inside the package. MultiScan's attachments are tiny *reference* files (see `InlineAttachments.swift`): a capture attachment holds the `PageCapture` uuid, a table attachment holds the table's JSON. So an RTFD page is only slightly larger than an RTF one, and the `TextExportCache` stays small.
//  Both remain plain `Data` blobs, so CloudKit external storage (CKAsset) and the SwiftData schema are unaffected. The *format* change is what bumped `SchemaVersioning.currentVersion` to 3: a 2.0 preview build (schema 2) decodes RTFD as RTF, gets an empty string, and could write it back.
//
//  ## Legacy Migration
//  Versions prior to 2.0 stored JSON-encoded SwiftUI `AttributedString` (Codable).
//  `attributedString(from:)` sniffs the format: RTF begins with `{\rtf`, a flattened RTFD package begins with `rtfd`; anything else is tried as legacy JSON. Migration is lazy: reads accept all formats forever, writes always produce RTF/RTFD.
//
//  ## Font Normalization
//  Fonts are normalized at the storage boundary so content is portable:
//  - **Storage/export font**: Helvetica Neue at 13 pt (resolvable by every word processor; the app's historical export font).
//  - **Display font**: the platform body font, applied when text is loaded into the editor. Bold/italic traits survive both directions; all other attributes — including attachments — pass through untouched.
//
//  ## Headings
//  Markdown-based OCR engines and chapter titles produce headings. They are expressed purely as font traits/sizes on the storage font (`PageTextStyle.headingFont(level:)`) so they survive RTF, every word processor, and the normalization passes (which preserve relative size via `PageTextStyle.relativeScale`).
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
/// `nonisolated`: fonts are created wherever text is encoded — on the main actor, inside `@concurrent` export work, and on `ProjectStore`.
nonisolated enum PageTextStyle {
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

    /// Size multipliers for heading levels relative to the body size (1 = largest). Level 0 / unknown = body.
    /// Kept modest: these are scanned documents, not a design tool, and the storage font is 13 pt.
    static func relativeScale(forHeadingLevel level: Int) -> CGFloat {
        switch level {
        case 1: 1.6
        case 2: 1.35
        case 3: 1.15
        case 4...6: 1.0
        default: 1.0
        }
    }

    /// A heading font on `base`: bold, scaled by `relativeScale(forHeadingLevel:)`.
    static func headingFont(level: Int, base: PlatformFont) -> PlatformFont {
        let scaled = base.withSize(base.pointSize * relativeScale(forHeadingLevel: level))
        return scaled.applyingTraits(bold: true, italic: scaled.isItalic)
    }

    /// Font for a run that was `existing` in a different base: keeps bold/italic and the run's *relative* size (so headings stay headings when switching between the display and storage fonts).
    static func normalizedFont(from existing: PlatformFont?, baseSizeOfExisting: CGFloat, to baseFont: PlatformFont) -> PlatformFont {
        guard let existing else { return baseFont }
        let scale = baseSizeOfExisting > 0 ? existing.pointSize / baseSizeOfExisting : 1
        // Snap near-1 scales to exactly the base size so ordinary body text never drifts by rounding.
        let size = abs(scale - 1) < 0.05 ? baseFont.pointSize : baseFont.pointSize * scale
        return baseFont.withSize(size).applyingTraits(bold: existing.isBold, italic: existing.isItalic)
    }
}

// MARK: - Font Trait Helpers

nonisolated extension PlatformFont {
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

    #if os(macOS)
    /// UIKit has `withSize(_:)`; AppKit spells it differently. One name for the normalization code.
    func withSize(_ size: CGFloat) -> NSFont {
        NSFont(descriptor: fontDescriptor, size: size) ?? NSFont.systemFont(ofSize: size)
    }
    #endif
}

// MARK: - Archiver

/// `nonisolated`: encoding and decoding run on whichever actor holds the text — the editor on the main actor, `TextExporter.buildResult` on the cooperative pool, `ProjectStore` on its model actor.
nonisolated enum RichTextArchiver {

    // MARK: Encoding

    /// Encodes page text for persistence, choosing RTF for text-only content and flattened RTFD when the string carries attachments. This is what `Page.attributedText`'s setter calls.
    static func richTextData(from attributedString: NSAttributedString) -> Data? {
        containsAttachments(attributedString) ? rtfdData(from: attributedString) : rtfData(from: attributedString)
    }

    /// Encodes an attributed string as RTF data. Attachments are dropped by RTF — callers with attachments use `richTextData(from:)` / `rtfdData(from:)`. Returns nil only if the framework conversion fails (should not happen for text-only content).
    static func rtfData(from attributedString: NSAttributedString) -> Data? {
        try? attributedString.data(
            from: NSRange(location: 0, length: attributedString.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    /// Encodes an attributed string (with attachments) as a *flattened* RTFD package — one `Data` blob, readable back with `decodeRTFD` on both platforms.
    static func rtfdData(from attributedString: NSAttributedString) -> Data? {
        try? attributedString.data(
            from: NSRange(location: 0, length: attributedString.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
    }

    /// Whether any run carries an `NSTextAttachment`.
    static func containsAttachments(_ attributedString: NSAttributedString) -> Bool {
        guard attributedString.length > 0 else { return false }
        var found = false
        attributedString.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributedString.length), options: .longestEffectiveRangeNotRequired) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    // MARK: Decoding (format-sniffing)

    /// Decodes persisted page text, accepting the current RTF/RTFD formats and the legacy JSON-encoded `AttributedString` format. Returns an empty string for nil or undecodable data.
    static func attributedString(from data: Data?) -> NSAttributedString {
        guard let data, !data.isEmpty else { return NSAttributedString() }

        if isRTF(data), let decoded = decodeRTF(data) {
            return decoded
        }
        if isRTFD(data), let decoded = decodeRTFD(data) {
            return decoded
        }
        if let legacy = decodeLegacyJSON(data) {
            return legacy
        }
        // Last resort: an RTFD whose serialized header we didn't recognize.
        if let decoded = decodeRTFD(data) {
            return decoded
        }
        print("⚠️ RichTextArchiver: unrecognized rich text data format (\(data.count) bytes)")
        return NSAttributedString()
    }

    /// RTF documents always begin with the ASCII bytes `{\rtf`.
    static func isRTF(_ data: Data) -> Bool {
        hasPrefix(data, [0x7B, 0x5C, 0x72, 0x74, 0x66]) // "{\rtf"
    }

    /// A flattened RTFD package (`FileWrapper.serializedRepresentation`) begins with the ASCII bytes `rtfd`.
    /// REVIEW: verify the magic against a real `data(from:documentAttributes: [.documentType: .rtfd])` payload on device; `attributedString(from:)` falls back to trying the RTFD decoder anyway, so a wrong magic only costs a failed RTF/JSON attempt first.
    static func isRTFD(_ data: Data) -> Bool {
        hasPrefix(data, [0x72, 0x74, 0x66, 0x64]) // "rtfd"
    }

    private static func hasPrefix(_ data: Data, _ magic: [UInt8]) -> Bool {
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

    /// Decodes a flattened RTFD package. Attachments come back as plain `NSTextAttachment`s carrying their `fileWrapper` (filename + contents), which is how `CaptureAttachment`/`TableAttachment` recognize their own.
    static func decodeRTFD(_ data: Data) -> NSAttributedString? {
        try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: nil
        )
    }

    /// Extracts plain text from persisted data (search, statistics, TTS), without attachment placeholders.
    static func plainText(from data: Data?) -> String {
        attributedString(from: data).string.strippingAttachmentCharacters()
    }

    // MARK: Legacy JSON Decoding (pre-2.0 format)

    /// Decodes the pre-2.0 JSON-encoded SwiftUI `AttributedString` format and converts
    /// it to an `NSAttributedString` on the canonical storage font. Bold/italic come
    /// from `inlinePresentationIntent` (Markdown-style) or the SwiftUI `Font` attribute
    /// (set by the old formatting toolbar); underline/strikethrough map directly.
    static func decodeLegacyJSON(_ data: Data) -> NSAttributedString? {
        // JSON starts with `{` or `[`; skip the (expensive, throwing) decode attempt for anything else.
        guard let first = data.first, first == 0x7B || first == 0x5B else { return nil }
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
    /// bold/italic traits and relative size (headings), and display-only colors stripped. All other attributes
    /// (underline, strikethrough, paragraph styles, attachments) pass through.
    /// - Parameter baseSizeOfExisting: the body size the incoming text was normalized to, so a 1.6× heading stays 1.6× in the new base.
    static func normalizing(_ attributedString: NSAttributedString, to baseFont: PlatformFont, baseSizeOfExisting: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: attributedString)
        let fullRange = NSRange(location: 0, length: result.length)

        result.removeAttribute(.foregroundColor, range: fullRange)
        result.removeAttribute(.backgroundColor, range: fullRange)

        result.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            let normalized = PageTextStyle.normalizedFont(
                from: value as? PlatformFont,
                baseSizeOfExisting: baseSizeOfExisting,
                to: baseFont
            )
            result.addAttribute(.font, value: normalized, range: range)
        }

        return result
    }

    /// Normalizes editor content for persistence (canonical storage font).
    static func normalizedForStorage(_ attributedString: NSAttributedString) -> NSAttributedString {
        normalizing(attributedString, to: PageTextStyle.storageFont, baseSizeOfExisting: PageTextStyle.displayFont.pointSize)
    }

    /// Normalizes persisted content for on-screen editing (platform body font + label color).
    static func normalizedForDisplay(_ attributedString: NSAttributedString) -> NSAttributedString {
        applyingDisplayColor(normalizing(attributedString, to: PageTextStyle.displayFont, baseSizeOfExisting: PageTextStyle.storageFontSize))
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
