//
//  TextFormatter.swift
//  MultiScan
//
//  Handles rich text export and clipboard operations.
//

import SwiftUI
import AppKit

struct TextFormatter {
    /// Copies a page's rich text to the clipboard
    @MainActor
    static func copyPageText(_ page: Page) {
        copyToClipboard(page.richText)
    }

    /// Copies all pages' rich text to the clipboard
    @MainActor
    static func copyAllPagesText(_ pages: [Page]) {
        let sortedPages = pages.sorted { $0.pageNumber < $1.pageNumber }
        var combined = AttributedString()

        for (index, page) in sortedPages.enumerated() {
            combined.append(page.richText)
            if index < sortedPages.count - 1 {
                combined.append(AttributedString("\n\n"))
            }
        }

        copyToClipboard(combined)
    }

    /// Copies AttributedString to clipboard, converting SwiftUI fonts to AppKit fonts for RTF
    @MainActor
    private static func copyToClipboard(_ attributedString: AttributedString) {
        let nsAttributedString = convertToNSAttributedString(attributedString)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // Set plain text version
        pasteboard.setString(nsAttributedString.string, forType: .string)

        // Set RTF version
        if let rtfData = try? nsAttributedString.data(
            from: NSRange(location: 0, length: nsAttributedString.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) {
            pasteboard.setData(rtfData, forType: .rtf)
        }
    }

    /// Converts SwiftUI AttributedString to NSAttributedString with proper font conversion
    private static func convertToNSAttributedString(_ attributedString: AttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

        for run in attributedString.runs {
            let text = String(attributedString[run.range].characters)
            var attributes: [NSAttributedString.Key: Any] = [:]

            // Convert SwiftUI Font to NSFont with proper traits
            if let swiftUIFont = run.font {
                let resolved = swiftUIFont.resolve(in: EnvironmentValues().fontResolutionContext)
                var font = baseFont

                if resolved.isBold && resolved.isItalic {
                    font = NSFontManager.shared.convert(baseFont, toHaveTrait: [.boldFontMask, .italicFontMask])
                } else if resolved.isBold {
                    font = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
                } else if resolved.isItalic {
                    font = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
                }

                attributes[.font] = font
            } else {
                attributes[.font] = baseFont
            }

            result.append(NSAttributedString(string: text, attributes: attributes))
        }

        return result
    }
}
