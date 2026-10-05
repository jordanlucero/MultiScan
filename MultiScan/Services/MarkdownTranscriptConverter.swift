//
//  MarkdownTranscriptConverter.swift
//  MultiScan
//
//  Turns a transformer OCR engine's page-by-page **markdown** into the `NSAttributedString` MultiScan stores (storage font, bold/italic traits, heading sizes, inline table attachments) — the bridge between "a model wrote markdown" and "TextKit 2 + RTF/RTFD + the export cache expect attributed text".
//
//  ## Approach
//  Foundation's `AttributedString(markdown:options:)` with `.full` interpreted syntax parses GitHub-flavored markdown and annotates runs with
//  - `inlinePresentationIntent` (emphasis, strong, code, strikethrough) and
//  - `presentationIntent` — the *block* structure: `.header(level:)`, `.paragraph`, `.listItem(ordinal:)` inside `.orderedList`/`.unorderedList`, `.blockQuote`, `.codeBlock`, `.thematicBreak`, and `.table(columns:)` / `.tableRow(rowIndex:)` / `.tableCell(columnIndex:)`.
//  The parser gives runs, not a tree, so the converter walks runs in order, groups consecutive runs that share a block identity, and emits:
//  - headings → `PageTextStyle.headingFont(level:)` on the storage font (bold + scaled; survives RTF and both normalization passes);
//  - list items → a `•` / `1.` prefix (RTF list markers are not portable across the two platforms' text systems, and OCR'd lists are read, not restructured);
//  - tables → one `TextTableModel` attachment per table (`InlineAttachments.makeTableAttachment`), rendered by `TableAttachmentViewProvider`;
//  - everything else → paragraphs separated by a single newline, matching how Vision's transcript already reads.
//
//  Inline markdown that the parser rejects (unbalanced emphasis, stray pipes) degrades gracefully: `AttributedString(markdown:)` throws only on malformed input, and the converter then falls back to the raw text on the storage font so a page is never lost.
//
//  `nonisolated`: runs inside the `@concurrent` OCR stage.
//

import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

nonisolated enum MarkdownTranscriptConverter {

    /// Converts `markdown` to storage-font attributed text. Never throws; malformed markdown becomes plain text.
    static func attributedString(fromMarkdown markdown: String) -> NSAttributedString {
        let cleaned = stripOuterCodeFence(markdown).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return NSAttributedString() }

        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible
        // Keep line breaks inside a paragraph as line breaks: a transcription's soft wraps are information (Smart Cleanup's first/last-line detection relies on them).
        options.allowsExtendedAttributes = true

        guard let parsed = try? AttributedString(markdown: cleaned, options: options) else {
            return NSAttributedString(string: cleaned, attributes: [.font: PageTextStyle.storageFont])
        }
        return build(from: parsed)
    }

    /// Markdown-based engines often wrap the whole answer in ```markdown … ``` despite instructions. Remove exactly one outer fence.
    static func stripOuterCodeFence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```") else { return text }
        var lines = trimmed.components(separatedBy: "\n")
        guard lines.count >= 2 else { return text }
        lines.removeFirst() // ```markdown
        lines.removeLast()  // ```
        return lines.joined(separator: "\n")
    }

    // MARK: - Building

    /// A block of the markdown document, reconstructed from the run annotations.
    private struct Block {
        enum Kind: Equatable {
            case paragraph
            case heading(Int)
            case listItem(ordinal: Int?)   // nil = bullet
            case blockQuote
            case codeBlock
            case thematicBreak
            case tableCell(table: Int, row: Int, column: Int)
        }
        var kind: Kind
        /// Identity of the innermost block component, so two adjacent paragraphs stay separate.
        var identity: Int
        var runs: [(text: String, inline: InlinePresentationIntent?)]
    }

    /// Row key under which a markdown table's header cells are collected (`PresentationIntent.Kind.tableHeaderRow` carries no index).
    private static let headerRowKey = -1

    private static func build(from parsed: AttributedString) -> NSAttributedString {
        // Pass 1: group runs into blocks.
        var blocks: [Block] = []
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            let intent = run.presentationIntent
            let (kind, identity) = classify(intent)
            if let last = blocks.last, last.identity == identity, last.kind == kind {
                blocks[blocks.count - 1].runs.append((text, run.inlinePresentationIntent))
            } else {
                blocks.append(Block(kind: kind, identity: identity, runs: [(text, run.inlinePresentationIntent)]))
            }
        }

        // Pass 2: emit.
        let base = PageTextStyle.storageFont
        let output = NSMutableAttributedString()
        var tableCells: [Int: [Int: [Int: String]]] = [:]   // table → row → column → text
        var tableOrder: [Int] = []
        var pendingTableID: Int?

        func flushPendingTable() {
            guard let id = pendingTableID, let rows = tableCells[id] else { pendingTableID = nil; return }
            // The header row is stored under `headerRowKey` (-1) so it sorts first whether body rows are 0- or 1-based.
            let rowIndices = rows.keys.sorted()
            let columnCount = (rows.values.flatMap { $0.keys }.max() ?? -1) + 1
            let grid: [[String]] = rowIndices.map { r in
                (0..<columnCount).map { c in rows[r]?[c] ?? "" }
            }
            let table = TextTableModel(rows: grid, hasHeaderRow: rows[headerRowKey] != nil)
            if !table.isEmpty, let attachment = InlineAttachments.makeTableAttachment(table) {
                appendParagraphBreakIfNeeded(output, font: base)
                output.append(InlineAttachments.attributedString(for: attachment, font: base))
                output.append(NSAttributedString(string: "\n", attributes: [.font: base]))
            }
            pendingTableID = nil
        }

        for block in blocks {
            if case .tableCell(let table, let row, let column) = block.kind {
                if pendingTableID != table { flushPendingTable(); pendingTableID = table; if !tableOrder.contains(table) { tableOrder.append(table) } }
                let cellText = block.runs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                tableCells[table, default: [:]][row, default: [:]][column] = cellText
                continue
            }
            flushPendingTable()

            switch block.kind {
            case .thematicBreak:
                appendParagraphBreakIfNeeded(output, font: base)
                output.append(NSAttributedString(string: "———\n", attributes: [.font: base]))

            case .heading(let level):
                appendParagraphBreakIfNeeded(output, font: base)
                let font = PageTextStyle.headingFont(level: level, base: base)
                output.append(inlineText(block.runs, font: font))
                output.append(NSAttributedString(string: "\n", attributes: [.font: base]))

            case .listItem(let ordinal):
                appendParagraphBreakIfNeeded(output, font: base)
                let marker = ordinal.map { "\($0). " } ?? "• "
                output.append(NSAttributedString(string: marker, attributes: [.font: base]))
                output.append(inlineText(block.runs, font: base))
                output.append(NSAttributedString(string: "\n", attributes: [.font: base]))

            case .blockQuote, .codeBlock, .paragraph:
                appendParagraphBreakIfNeeded(output, font: base)
                output.append(inlineText(block.runs, font: base))
                output.append(NSAttributedString(string: "\n", attributes: [.font: base]))
            }
        }
        flushPendingTable()

        // Drop the trailing newline so a page doesn't end with an empty line (Vision transcripts don't).
        if output.length > 0, output.string.hasSuffix("\n") {
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
        }
        return output
    }

    /// Ensures block boundaries are visible without stacking blank lines.
    private static func appendParagraphBreakIfNeeded(_ output: NSMutableAttributedString, font: PlatformFont) {
        // Blocks already end with "\n"; nothing extra is needed. Kept as a single place to change if double spacing between blocks is wanted later.
        _ = font
    }

    /// Applies inline emphasis to a block's runs on `font`.
    private static func inlineText(_ runs: [(text: String, inline: InlinePresentationIntent?)], font: PlatformFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in runs {
            var attributes: [NSAttributedString.Key: Any] = [:]
            let inline = run.inline ?? []
            let bold = inline.contains(.stronglyEmphasized) || font.isBold
            let italic = inline.contains(.emphasized) || font.isItalic
            attributes[.font] = font.applyingTraits(bold: bold, italic: italic)
            if inline.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            // `.code` (inline code) and `.softBreak`/`.lineBreak` carry no visual mapping worth persisting; their text passes through.
            var text = run.text
            if inline.contains(.softBreak) || inline.contains(.lineBreak) { text = "\n" }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }

    /// Maps a run's block structure to a block kind and an identity for grouping.
    private static func classify(_ intent: PresentationIntent?) -> (Block.Kind, Int) {
        guard let intent else { return (.paragraph, -1) }
        // Components are ordered innermost-first.
        var listOrdinal: Int?
        var inList = false
        var tableIndex: Int?
        var rowIndex: Int?
        var columnIndex: Int?
        var heading: Int?
        var isQuote = false
        var isCode = false
        var isBreak = false
        var innermostIdentity = -1

        for (index, component) in intent.components.enumerated() {
            if index == 0 { innermostIdentity = component.identity }
            switch component.kind {
            case .header(let level): heading = level
            case .listItem(let ordinal): listOrdinal = ordinal
            case .orderedList: inList = true
            case .unorderedList: inList = true; if listOrdinal != nil { listOrdinal = nil }
            case .table: tableIndex = component.identity
            case .tableRow(let row): rowIndex = row
            case .tableCell(let column): columnIndex = column
            case .blockQuote: isQuote = true
            case .codeBlock: isCode = true
            case .thematicBreak: isBreak = true
            case .paragraph: break
            case .tableHeaderRow: rowIndex = headerRowKey
            @unknown default: break
            }
        }

        if let tableIndex, let rowIndex, let columnIndex {
            return (.tableCell(table: tableIndex, row: rowIndex, column: columnIndex), innermostIdentity)
        }
        if isBreak { return (.thematicBreak, innermostIdentity) }
        if let heading { return (.heading(heading), innermostIdentity) }
        if inList || listOrdinal != nil {
            // Ordered lists report the ordinal on the list item; unordered lists report ordinal too (1-based position) — distinguish by the list kind.
            let components = intent.components
            let isOrdered = components.contains { if case .orderedList = $0.kind { return true } else { return false } }
            return (.listItem(ordinal: isOrdered ? listOrdinal : nil), innermostIdentity)
        }
        if isCode { return (.codeBlock, innermostIdentity) }
        if isQuote { return (.blockQuote, innermostIdentity) }
        return (.paragraph, innermostIdentity)
    }
}
