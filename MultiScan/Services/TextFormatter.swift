//
//  TextFormatter.swift
//  MultiScan
//
//  Handles rich text export and clipboard operations.
//

import Foundation
import AppKit
import SwiftUI

struct TextFormatter {
    /// Copies an AttributedString to the clipboard as both RTF and plain text
    static func copyRichText(_ attributedString: AttributedString) {
        let nsAttributedString = NSAttributedString(attributedString)

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

    /// Copies multiple AttributedStrings to clipboard, joined with double newlines
    static func copyRichText(_ attributedStrings: [AttributedString]) {
        var combined = AttributedString()

        for (index, str) in attributedStrings.enumerated() {
            combined.append(str)
            if index < attributedStrings.count - 1 {
                combined.append(AttributedString("\n\n"))
            }
        }

        copyRichText(combined)
    }

    /// Copies a page's rich text to the clipboard
    static func copyPageText(_ page: Page) {
        copyRichText(page.richText)
    }

    /// Copies all pages' rich text to the clipboard
    static func copyAllPagesText(_ pages: [Page]) {
        let sortedPages = pages.sorted { $0.pageNumber < $1.pageNumber }
        let attributedStrings = sortedPages.map { $0.richText }
        copyRichText(attributedStrings)
    }
}
