//
//  TextExporter.swift
//  MultiScan
//
//  Handles building combined AttributedString for export with configurable separators.
//

import SwiftUI

struct TextExporter {
    let pages: [Page]
    let settings: ExportSettings

    /// Build combined AttributedString based on current settings
    @MainActor
    func buildCombinedText() -> AttributedString {
        let sortedPages = pages.sorted { $0.pageNumber < $1.pageNumber }
        var combined = AttributedString()

        for (index, page) in sortedPages.enumerated() {
            // Add separator before each page
            // For visual separation: include first page header
            // For inline/line break: skip first page (no leading space/newline needed)
            let includeFirstPage = settings.flowStyle == .visualSeparation
            if index > 0 || includeFirstPage {
                combined.append(buildSeparator(
                    beforePage: page,
                    pageIndex: index,
                    totalPages: sortedPages.count,
                    isFirstPage: index == 0
                ))
            }

            combined.append(page.richText)
        }

        return combined
    }

    /// Build the appropriate separator based on settings
    @MainActor
    private func buildSeparator(beforePage page: Page, pageIndex: Int, totalPages: Int, isFirstPage: Bool) -> AttributedString {
        switch settings.flowStyle {
        case .inline:
            return AttributedString(" ")

        case .lineBreak:
            return AttributedString("\n\n")

        case .visualSeparation:
            return buildVisualSeparator(beforePage: page, pageIndex: pageIndex, totalPages: totalPages, isFirstPage: isFirstPage)
        }
    }

    /// Build a visual separator with metadata
    @MainActor
    private func buildVisualSeparator(beforePage page: Page, pageIndex: Int, totalPages: Int, isFirstPage: Bool) -> AttributedString {
        // No leading newlines for the first page
        var separator = isFirstPage ? AttributedString() : AttributedString("\n\n")

        // Collect metadata components
        var components: [String] = []

        if settings.includePageNumber {
            components.append(String(localized: "Page \(page.pageNumber) of \(totalPages)"))
        }

        if settings.includeFilename, let filename = page.originalFileName {
            components.append(filename)
        }

        if settings.includeStatistics {
            let words = page.plainText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            let chars = page.plainText.count
            components.append(String(localized: "\(words) words, \(chars) characters"))
        }

        // Format based on separator style
        switch settings.separatorStyle {
        case .singleLine:
            if !components.isEmpty {
                separator.append(AttributedString("[\(components.joined(separator: " | "))]"))
            }

        case .multipleLines:
            for component in components {
                separator.append(AttributedString("\(component)\n"))
            }
            // Remove trailing newline since we'll add \n\n after
            if !components.isEmpty {
                separator = AttributedString(String(separator.characters).trimmingCharacters(in: .newlines))
            }

        case .hyphenLine:
            separator.append(AttributedString(String(repeating: "-", count: 40)))
            if !components.isEmpty {
                separator.append(AttributedString("\n"))
                separator.append(AttributedString(components.joined(separator: "\n")))
            }
        }

        separator.append(AttributedString("\n\n"))
        return separator
    }
}
