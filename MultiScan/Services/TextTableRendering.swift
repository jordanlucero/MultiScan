//
//  TextTableRendering.swift
//  MultiScan
//
//  macOS: native `NSTextTable` rendering and editing for MultiScan's inline tables.
//
//  ## Two representations, one source of truth
//  Tables are **stored** as reference attachments (`TextTableModel` JSON in a `.multiscantable` file inside the page's RTFD — see `InlineAttachments.swift`). That representation is portable: iOS/iPadOS, which have no `NSTextTable`, render it read-only through `TableAttachmentViewProvider`, CloudKit syncs it unchanged, and the export cache stays small.
//
//  On the Mac, the attachment is **expanded into real `NSTextTable` paragraphs** whenever text is loaded into a text view (editor, export preview, Digest) or exported (RTF → Pages, Word, TextEdit import real tables). AppKit lays the cells out, the user clicks into a cell and edits its text with normal typing undo, and the export carries the structure. On save, `collapsingTables(in:)` walks the paragraph styles back into `TextTableModel`s so the stored page never contains an `NSTextTable` — a Mac-edited table round-trips to an iPhone as the same attachment it always was.
//
//  Cell contents are stored as plain strings in 2.0: formatting typed inside a cell survives the editing session but not the save (the cell text does). Adding/removing rows and columns has no UI yet.
//
//  ⚠️ REVIEW: confirm on macOS 27 that a TextKit 2 `NSTextView` lays out `NSTextTable` content without silently switching to the TextKit 1 compatibility engine (check `textView.textLayoutManager != nil` after loading a page with a table). If it does switch, the fallback is to keep tables as attachment views on the Mac too (`PageTextController` just skips the expansion).
//

#if os(macOS)
import AppKit

nonisolated enum TextTableRendering {

    // MARK: Model → NSTextTable

    /// Native table paragraphs for `table`: one paragraph per cell, each carrying an `NSTextTableBlock` in its paragraph style. Header-row cells are bold.
    static func attributedString(for table: TextTableModel, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        guard !table.isEmpty else { return result }

        let textTable = NSTextTable()
        textTable.numberOfColumns = table.columnCount
        textTable.layoutAlgorithm = .automaticLayoutAlgorithm
        textTable.collapsesBorders = true
        textTable.hidesEmptyCells = false

        for (row, cells) in table.rows.enumerated() {
            for (column, cellText) in cells.enumerated() {
                let block = NSTextTableBlock(table: textTable, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setBorderColor(.separatorColor)
                block.setWidth(4, type: .absoluteValueType, for: .padding)

                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]

                let isHeader = table.hasHeaderRow && row == 0
                let cellFont = isHeader ? font.applyingTraits(bold: true, italic: font.isItalic) : font
                // One paragraph per cell: newlines inside a cell would start a new paragraph in the same block (legal, but the collapse would re-join them anyway).
                let text = cellText.replacingOccurrences(of: "\n", with: " ") + "\n"
                result.append(NSAttributedString(string: text, attributes: [.font: cellFont, .paragraphStyle: style]))
            }
        }
        return result
    }

    /// Replaces every table reference attachment in `text` with native table paragraphs. No-op when there are none.
    static func expandingTableAttachments(in text: NSAttributedString, font: NSFont) -> NSAttributedString {
        guard RichTextArchiver.containsAttachments(text) else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        var replacements: [(NSRange, NSAttributedString)] = []
        InlineAttachments.enumerateAttachments(in: result) { attachment, range in
            if case .table(let table) = InlineAttachments.kind(of: attachment) {
                replacements.append((range, attributedString(for: table, font: font)))
            }
        }
        guard !replacements.isEmpty else { return text }
        let string = result.string as NSString
        for (range, replacement) in replacements.reversed() {
            // The attachment sits on its own paragraph; the table's last cell brings its own terminator, so swallow the newline that followed the attachment to avoid a blank line.
            var target = range
            if target.upperBound < string.length, string.character(at: target.upperBound) == 0x0A {
                target.length += 1
            }
            result.replaceCharacters(in: target, with: replacement)
        }
        return result
    }

    // MARK: NSTextTable → model

    /// Replaces every run of `NSTextTable` paragraphs in `text` with a table reference attachment, for storage. Text without tables is returned untouched.
    static func collapsingTables(in text: NSAttributedString) -> NSAttributedString {
        guard text.length > 0 else { return text }

        // Pass 1: find table paragraphs, grouped by the NSTextTable object they belong to (consecutive runs only).
        struct CellRun {
            let block: NSTextTableBlock
            let range: NSRange
            let isBold: Bool
        }
        struct TableRun {
            let table: NSTextTable
            var range: NSRange
            var cells: [CellRun]
        }
        var runs: [TableRun] = []
        let fullRange = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.paragraphStyle, in: fullRange, options: []) { value, range, _ in
            guard let style = value as? NSParagraphStyle,
                  let block = style.textBlocks.last as? NSTextTableBlock else { return }
            let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            let cell = CellRun(block: block, range: range, isBold: font?.isBold ?? false)
            if var last = runs.last, last.table === block.table, last.range.upperBound == range.location {
                last.range.length += range.length
                last.cells.append(cell)
                runs[runs.count - 1] = last
            } else {
                runs.append(TableRun(table: block.table, range: range, cells: [cell]))
            }
        }
        guard !runs.isEmpty else { return text }

        // Pass 2: rebuild each table and swap the paragraphs for an attachment.
        let result = NSMutableAttributedString(attributedString: text)
        let string = text.string as NSString
        for run in runs.reversed() {
            let rowCount = (run.cells.map { $0.block.startingRow + $0.block.rowSpan }.max() ?? 0)
            let columnCount = max(run.table.numberOfColumns, run.cells.map { $0.block.startingColumn + $0.block.columnSpan }.max() ?? 0)
            guard rowCount > 0, columnCount > 0 else { continue }

            var grid = Array(repeating: Array(repeating: "", count: columnCount), count: rowCount)
            var firstRowAllBold = true
            for cell in run.cells {
                var cellText = string.substring(with: cell.range)
                if cellText.hasSuffix("\n") { cellText.removeLast() }
                let row = cell.block.startingRow
                let column = cell.block.startingColumn
                guard row < rowCount, column < columnCount else { continue }
                // Several paragraphs in one cell arrive as separate runs with the same block: join them.
                grid[row][column] = grid[row][column].isEmpty ? cellText : grid[row][column] + "\n" + cellText
                if row == 0, !cell.isBold { firstRowAllBold = false }
            }
            let model = TextTableModel(rows: grid, hasHeaderRow: rowCount > 1 && firstRowAllBold)

            let font = (text.attribute(.font, at: run.range.location, effectiveRange: nil) as? NSFont) ?? PageTextStyle.storageFont
            let replacement = NSMutableAttributedString()
            if let attachment = InlineAttachments.makeTableAttachment(model) {
                replacement.append(InlineAttachments.attributedString(for: attachment, font: font.applyingTraits(bold: false, italic: false)))
                replacement.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
            result.replaceCharacters(in: run.range, with: replacement)
        }
        return result
    }
}
#endif
