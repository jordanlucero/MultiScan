//
//  PageNumbering.swift
//  MultiScan
//
//  Printed (physical) page numbers, as opposed to MultiScan's own 1…N project page numbers.
//
//  A scanned book rarely starts counting at its first scanned page: front matter is numbered in Roman numerals (or not at all), and a partial scan might begin at printed page 41. `Document` stores three settings — the project page on which Arabic numbering begins, the number printed there, and how the front matter is labelled — and this helper turns them into labels. Printed labels show up in the thumbnail sidebar, the Digest, and in draft-capture reminders ("revisit printed page 7"), where the physical number is the one the user actually needs.
//
//  Pure functions, `nonisolated`: used from the models (any actor) and the UI.
//

import Foundation

/// How pages before the Arabic numbering start are labelled.
nonisolated enum FrontMatterNumberingStyle: String, CaseIterable, Codable, Sendable {
    /// i, ii, iii… (lowercase Roman numerals, the convention in most books).
    case roman
    /// Front matter carries no printed number.
    case none

    var label: LocalizedStringResource {
        switch self {
        case .roman: LocalizedStringResource("Roman numerals (i, ii, iii)", comment: "Front matter numbering style")
        case .none: LocalizedStringResource("Unnumbered", comment: "Front matter numbering style")
        }
    }
}

nonisolated enum PageNumbering {

    /// The label printed on project page `projectPage`, or `nil` when the project has no printed-numbering configuration (or the front matter style says the page is unnumbered).
    ///
    /// Example — numbering starts on project page 9 at printed value 1, Roman front matter:
    /// page 1 → "i", page 8 → "viii", page 9 → "1", page 20 → "12".
    static func printedLabel(forProjectPage projectPage: Int, in document: Document) -> String? {
        guard let start = document.printedNumberingStartPage, start >= 1 else { return nil }
        return printedLabel(
            forProjectPage: projectPage,
            startPage: start,
            startValue: document.printedNumberingStartValue,
            frontMatterStyle: document.frontMatterStyle
        )
    }

    /// Model-free variant (testable).
    static func printedLabel(
        forProjectPage projectPage: Int,
        startPage: Int,
        startValue: Int,
        frontMatterStyle: FrontMatterNumberingStyle
    ) -> String? {
        if projectPage >= startPage {
            return String(startValue + (projectPage - startPage))
        }
        switch frontMatterStyle {
        case .roman:
            return romanNumeral(projectPage).lowercased()
        case .none:
            return nil
        }
    }

    /// The project page that carries printed number `printedValue` (Arabic numbering only), or `nil` if it falls before the numbering start or isn't configured. The inverse of `printedLabel` for the "go to printed page" affordances.
    static func projectPage(forPrintedValue printedValue: Int, in document: Document) -> Int? {
        guard let start = document.printedNumberingStartPage else { return nil }
        let offset = printedValue - document.printedNumberingStartValue
        guard offset >= 0 else { return nil }
        let page = start + offset
        return page <= document.totalPages ? page : nil
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

    /// Parses a Roman numeral (either case); `nil` for anything that isn't one. Used by `ChapterDetector`/Smart Separate heuristics when a front-matter page prints "xii".
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
