//
//  PageNumbering.swift
//  MultiScan
//
//  Printed (physical) page numbers, as opposed to MultiScan's own 1…N project page numbers.
//
//  A scanned book rarely starts counting at its first scanned page: front matter is numbered in Roman numerals (or not at all), a partial scan might begin at printed page 41, and an appendix may restart at 1. The model is a **plan of ranges** (`PrintedNumberingPlan`): each `PrintedNumberingRange` says "from project page S onward, print in style X starting at value V" and applies until the next range starts. Most books need two ranges — Roman front matter from page 1, Arabic from the first body page — and the settings sheet shows exactly that; additional ranges live behind a disclosure so the common case stays simple.
//
//  Labels show up in the thumbnail sidebar, the page grid, the Digest, context-menu headers, and in draft-capture reminders ("revisit printed page 7"), where the physical number is the one the user actually needs.
//
//  Pure functions, `nonisolated`: used from the models (any actor) and the UI. Persisted on `Document.printedNumberingData` as JSON.
//

import Foundation

/// How a range of pages is numbered.
nonisolated enum PrintedNumberingStyle: String, CaseIterable, Codable, Sendable {
    /// 1, 2, 3…
    case arabic
    /// i, ii, iii… (lowercase Roman numerals, the convention for front matter).
    case roman
    /// No printed number.
    case none

    var label: LocalizedStringResource {
        switch self {
        case .arabic: LocalizedStringResource("Numbers (1, 2, 3)", comment: "Printed page numbering style")
        case .roman: LocalizedStringResource("Roman numerals (i, ii, iii)", comment: "Printed page numbering style")
        case .none: LocalizedStringResource("Unnumbered", comment: "Printed page numbering style")
        }
    }
}

/// One stretch of printed numbering: from `startPage` (project page, 1-based) until the next range begins.
nonisolated struct PrintedNumberingRange: Codable, Sendable, Equatable, Hashable, Identifiable {
    var id: UUID
    var startPage: Int
    var style: PrintedNumberingStyle
    /// The printed value on `startPage` (ignored for `.none`).
    var startValue: Int

    init(id: UUID = UUID(), startPage: Int, style: PrintedNumberingStyle, startValue: Int = 1) {
        self.id = id
        self.startPage = max(1, startPage)
        self.style = style
        self.startValue = max(1, startValue)
    }
}

/// The whole document's printed numbering.
nonisolated struct PrintedNumberingPlan: Codable, Sendable, Equatable {
    static let currentVersion = 1

    var version: Int = currentVersion
    /// Sorted by `startPage`; later ranges win for the pages they cover.
    var ranges: [PrintedNumberingRange]

    init(ranges: [PrintedNumberingRange]) {
        self.ranges = ranges.sorted { $0.startPage < $1.startPage }
    }

    /// The common two-range shape: front matter (Roman or unnumbered) from page 1, then Arabic numbering from `startPage` at `startValue`. When `startPage == 1` the front-matter range is omitted.
    static func simple(startPage: Int, startValue: Int, frontMatter: PrintedNumberingStyle) -> PrintedNumberingPlan {
        var ranges: [PrintedNumberingRange] = []
        if startPage > 1 {
            ranges.append(PrintedNumberingRange(startPage: 1, style: frontMatter == .arabic ? .roman : frontMatter, startValue: 1))
        }
        ranges.append(PrintedNumberingRange(startPage: startPage, style: .arabic, startValue: startValue))
        return PrintedNumberingPlan(ranges: ranges)
    }

    /// The range in force on `projectPage`, if any.
    func range(forProjectPage projectPage: Int) -> PrintedNumberingRange? {
        ranges.last { $0.startPage <= projectPage }
    }

    /// The label printed on `projectPage`, or nil when unnumbered / before the first range.
    func label(forProjectPage projectPage: Int) -> String? {
        guard let range = range(forProjectPage: projectPage) else { return nil }
        let value = range.startValue + (projectPage - range.startPage)
        switch range.style {
        case .arabic: return String(value)
        case .roman: return PageNumbering.romanNumeral(value).lowercased()
        case .none: return nil
        }
    }

    /// The first project page whose printed label is `printedValue` in an Arabic range (the inverse of `label`, for "go to printed page" affordances). `nil` when no range prints it.
    func projectPage(forPrintedValue printedValue: Int, totalPages: Int) -> Int? {
        for (index, range) in ranges.enumerated() where range.style == .arabic {
            let offset = printedValue - range.startValue
            guard offset >= 0 else { continue }
            let page = range.startPage + offset
            let end = index + 1 < ranges.count ? ranges[index + 1].startPage - 1 : totalPages
            if page <= end { return page }
        }
        return nil
    }

    // MARK: Simple-shape decomposition (for the settings sheet)

    /// The Arabic range the simple controls edit: the first `.arabic` range.
    var mainRange: PrintedNumberingRange? {
        ranges.first { $0.style == .arabic }
    }

    /// Style of the pages before `mainRange` (the leading range starting at page 1, when it is not the main range itself).
    var frontMatterStyle: PrintedNumberingStyle {
        guard let first = ranges.first, first.style != .arabic else { return .none }
        return first.style
    }

    /// Ranges beyond the simple two: everything after the main Arabic range (an appendix restarting at 1, a second Roman section…).
    var additionalRanges: [PrintedNumberingRange] {
        guard let main = mainRange, let mainIndex = ranges.firstIndex(of: main) else { return [] }
        return Array(ranges[(mainIndex + 1)...])
    }

    // MARK: Persistence

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(_ data: Data?) -> PrintedNumberingPlan? {
        guard let data, let plan = try? JSONDecoder().decode(PrintedNumberingPlan.self, from: data), plan.version == currentVersion, !plan.ranges.isEmpty else { return nil }
        return PrintedNumberingPlan(ranges: plan.ranges)
    }
}

nonisolated enum PageNumbering {

    /// The label printed on project page `projectPage`, or `nil` when the project has no printed-numbering plan (or the page is unnumbered).
    ///
    /// Example — plan `.simple(startPage: 9, startValue: 1, frontMatter: .roman)`:
    /// page 1 → "i", page 8 → "viii", page 9 → "1", page 20 → "12".
    static func printedLabel(forProjectPage projectPage: Int, in document: Document) -> String? {
        document.printedNumbering?.label(forProjectPage: projectPage)
    }

    /// The project page that carries printed number `printedValue` (Arabic ranges only), or `nil` if none does.
    static func projectPage(forPrintedValue printedValue: Int, in document: Document) -> Int? {
        document.printedNumbering?.projectPage(forPrintedValue: printedValue, totalPages: document.totalPages)
    }

    /// Uppercase Roman numeral for 1…3999 (the range any front matter realistically needs). Values outside it fall back to Arabic digits rather than producing nonsense.
    static func romanNumeral(_ value: Int) -> String {
        guard value >= 1, value <= 3999 else { return String(value) }
        let table: [(Int, String)] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
            (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
            (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")
        ]
        var remaining = value
        var result = ""
        for (number, numeral) in table {
            while remaining >= number {
                result += numeral
                remaining -= number
            }
        }
        return result
    }

    /// Parses a Roman numeral (either case); `nil` for anything that isn't one. Used by `ChapterDetector` when a front-matter page prints "xii".
    static func value(ofRomanNumeral text: String) -> Int? {
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000]
        let upper = text.uppercased()
        guard !upper.isEmpty, upper.allSatisfy({ values[$0] != nil }) else { return nil }
        var total = 0
        var previous = 0
        for character in upper.reversed() {
            let current = values[character]!
            if current < previous {
                total -= current
            } else {
                total += current
                previous = current
            }
        }
        // Reject malformed sequences ("IIII", "VX") by round-tripping.
        return romanNumeral(total) == upper ? total : nil
    }
}
