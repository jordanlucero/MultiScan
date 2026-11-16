//
//  PageNumbering.swift
//  MultiScan
//
//  Printed (physical) page numbers, as opposed to MultiScan's own 1…N project page numbers.
//
//  A scanned book rarely starts counting at its first scanned page: front matter is numbered in Roman numerals (or not at all), a partial scan might begin at printed page 41, and an appendix may restart at 1. The model is a **plan of ranges**: each range says "from this page onward, print in style X starting at value V" and applies until the next range starts. Most books need two ranges — Roman front matter from the first page, Arabic from the first body page — and the settings sheet shows exactly that; additional ranges live behind a disclosure so the common case stays simple.
//
//  ## Two forms of the same plan
//  - **`PrintedNumberingPlan`** is what is *stored* (`Document.printedNumberingData`, JSON). Each range is anchored to the **page it starts on**, by `Page.uuid` — "this physical page is printed 1" is a fact about that page, so it has to survive the page moving. Position-based anchors (the first implementation) silently shifted every label whenever a page was inserted, deleted, reordered, or split by Smart Separate. A range may instead have *no* anchor page, meaning "from the first page of the project, whichever page that is" — the front-matter case, where a page added at the front should simply become "i".
//  - **`ResolvedPrintedNumbering`** is the plan *placed* against the project's current page order: every range knows the project page number it currently starts on. Labels, the inverse lookup, and the settings sheet (which talks to the user in project page numbers) all work on this form. `plan.resolved(positions:)` goes one way, `resolved.anchored(to:)` the other.
//
//  A range whose anchor page isn't in the project (deleted on another device, or its record hasn't synced yet) is skipped while resolving and left in storage, so it comes back by itself if the page arrives. Deleting an anchor page locally hands the range to the page that takes its place (`PageNumbering.pageWillBeDeleted`) — every remaining page keeps counting from the same value, exactly as when a non-anchor page is deleted.
//
//  ## Stored versions
//  Plan version 1 (schema-3 development builds only, never shipped) stored `startPage` positions. `decode(_:pages:)` reads it and anchors each range to the page currently at that position; `ProjectMaintenance` rewrites such blobs at launch. Same field, same SwiftData/CloudKit schema — no schema version bump.
//
//  Labels show up in the thumbnail sidebar, the page grid, the Digest, context-menu headers, and in draft-capture reminders ("revisit printed page 7"), where the physical number is the one the user actually needs.
//
//  Pure value types and functions, `nonisolated`: used from the models (any actor) and the UI.
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

// MARK: - Stored plan (anchored to pages)

/// One stretch of printed numbering as stored: from its anchor page until the next range begins.
nonisolated struct PrintedNumberingRange: Sendable, Equatable, Hashable, Identifiable {
    var id: UUID
    /// `Page.uuid` of the page this range starts on. `nil` = the first page of the project, whichever page that currently is.
    var startPageID: UUID?
    var style: PrintedNumberingStyle
    /// The printed value on the anchor page (ignored for `.none`).
    var startValue: Int

    init(id: UUID = UUID(), startPageID: UUID?, style: PrintedNumberingStyle, startValue: Int = 1) {
        self.id = id
        self.startPageID = startPageID
        self.style = style
        self.startValue = max(1, startValue)
    }
}

/// The whole document's printed numbering, as stored.
nonisolated struct PrintedNumberingPlan: Sendable, Equatable {
    static let currentVersion = 2

    var ranges: [PrintedNumberingRange]

    init(ranges: [PrintedNumberingRange]) {
        self.ranges = ranges
    }

    /// Places every range at its anchor page's current position. `positions` maps `Page.uuid` → project page number (`PageNumbering.positions(of:)`). Ranges whose anchor page is missing are skipped; if two ranges land on the same page the later one in `ranges` wins.
    func resolved(positions: [UUID: Int]) -> ResolvedPrintedNumbering {
        var byStartPage: [Int: ResolvedPrintedNumbering.Range] = [:]
        for range in ranges {
            let startPage: Int
            if let anchor = range.startPageID {
                guard let position = positions[anchor] else { continue }
                startPage = position
            } else {
                startPage = 1
            }
            byStartPage[startPage] = ResolvedPrintedNumbering.Range(id: range.id, startPage: startPage, style: range.style, startValue: range.startValue)
        }
        return ResolvedPrintedNumbering(ranges: Array(byStartPage.values))
    }

    func resolved(against pages: [Page]) -> ResolvedPrintedNumbering {
        resolved(positions: PageNumbering.positions(of: pages))
    }

    /// The plan after the page `deleted` leaves the project: a range anchored to it moves to `successor` (the page taking its place) and keeps its start value, so the pages after it count exactly as before. The range is dropped when there is no successor, or when the successor already starts a range of its own.
    func reanchoring(deleted: UUID, to successor: UUID?) -> PrintedNumberingPlan {
        guard ranges.contains(where: { $0.startPageID == deleted }) else { return self }
        let successorIsTaken = successor.map { id in ranges.contains { $0.startPageID == id } } ?? true
        var updated: [PrintedNumberingRange] = []
        for var range in ranges {
            if range.startPageID == deleted {
                guard let successor, !successorIsTaken else { continue }
                range.startPageID = successor
            }
            updated.append(range)
        }
        return PrintedNumberingPlan(ranges: updated)
    }

    // MARK: Persistence

    /// The JSON shape on disk, covering both stored versions: version 2 ranges carry `startPageID` (absent = first page), version 1 ranges carried `startPage` (a project page number).
    private struct Wire: Codable {
        struct Range: Codable {
            var id: UUID
            var startPageID: UUID?
            var startPage: Int?
            var style: PrintedNumberingStyle
            var startValue: Int
        }
        var version: Int
        var ranges: [Range]
    }

    func encoded() -> Data? {
        let wire = Wire(version: Self.currentVersion, ranges: ranges.map {
            Wire.Range(id: $0.id, startPageID: $0.startPageID, startPage: nil, style: $0.style, startValue: $0.startValue)
        })
        return try? JSONEncoder().encode(wire)
    }

    /// Version number inside a stored blob, or `nil` if it isn't a plan at all. `ProjectMaintenance` uses it to find version-1 blobs to rewrite.
    static func storedVersion(of data: Data?) -> Int? {
        guard let data, let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        return wire.version
    }

    /// Decodes a stored plan. `pages` is only consulted for a version-1 (position-based) blob, whose ranges are anchored to the pages currently at those positions; a range whose page has no `uuid` yet is left out until the launch backfill has assigned one. Returns `nil` for no data, an unknown version, or an empty plan.
    static func decode(_ data: Data?, pages: @autoclosure () -> [Page]) -> PrintedNumberingPlan? {
        guard let data, let wire = try? JSONDecoder().decode(Wire.self, from: data), !wire.ranges.isEmpty else { return nil }
        switch wire.version {
        case currentVersion:
            return PrintedNumberingPlan(ranges: wire.ranges.map {
                PrintedNumberingRange(id: $0.id, startPageID: $0.startPageID, style: $0.style, startValue: $0.startValue)
            })
        case 1:
            let legacy = ResolvedPrintedNumbering(ranges: wire.ranges.map {
                ResolvedPrintedNumbering.Range(id: $0.id, startPage: $0.startPage ?? 1, style: $0.style, startValue: $0.startValue)
            })
            let plan = legacy.anchored(to: pages())
            return plan.ranges.isEmpty ? nil : plan
        default:
            return nil
        }
    }
}

// MARK: - Resolved plan (placed against the current page order)

/// A numbering plan with every range placed at the project page it currently starts on. This is the form labels are computed from and the form the settings sheet edits.
nonisolated struct ResolvedPrintedNumbering: Sendable, Equatable {
    /// One stretch of printed numbering: from `startPage` (project page, 1-based) until the next range begins.
    struct Range: Sendable, Equatable, Hashable, Identifiable {
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

    /// Sorted by `startPage`; a later range takes over from the page it starts on.
    var ranges: [Range]

    init(ranges: [Range]) {
        self.ranges = ranges.sorted { $0.startPage < $1.startPage }
    }

    /// The common two-range shape: front matter (Roman or unnumbered) from page 1, then Arabic numbering from `startPage` at `startValue`. When `startPage == 1` the front-matter range is omitted.
    static func simple(startPage: Int, startValue: Int, frontMatter: PrintedNumberingStyle) -> ResolvedPrintedNumbering {
        var ranges: [Range] = []
        if startPage > 1 {
            ranges.append(Range(startPage: 1, style: frontMatter == .arabic ? .roman : frontMatter, startValue: 1))
        }
        ranges.append(Range(startPage: startPage, style: .arabic, startValue: startValue))
        return ResolvedPrintedNumbering(ranges: ranges)
    }

    /// The range in force on `projectPage`, if any.
    func range(forProjectPage projectPage: Int) -> Range? {
        ranges.last { $0.startPage <= projectPage }
    }

    /// The label printed on `projectPage`, or nil when unnumbered / before the first range.
    func label(forProjectPage projectPage: Int) -> String? {
        guard let range = range(forProjectPage: projectPage) else { return nil }
        return Self.label(in: range, forProjectPage: projectPage)
    }

    private static func label(in range: Range, forProjectPage projectPage: Int) -> String? {
        let value = range.startValue + (projectPage - range.startPage)
        switch range.style {
        case .arabic: return String(value)
        case .roman: return PageNumbering.romanNumeral(value).lowercased()
        case .none: return nil
        }
    }

    /// Labels for pages 1…`pageCount` in one pass, keyed by project page number (unnumbered pages are absent).
    func labels(pageCount: Int) -> [Int: String] {
        guard pageCount > 0, !ranges.isEmpty else { return [:] }
        var result: [Int: String] = [:]
        for (index, range) in ranges.enumerated() where range.startPage <= pageCount {
            let end = index + 1 < ranges.count ? min(ranges[index + 1].startPage - 1, pageCount) : pageCount
            guard range.style != .none, range.startPage <= end else { continue }
            for page in range.startPage...end {
                result[page] = Self.label(in: range, forProjectPage: page)
            }
        }
        return result
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
    var mainRange: Range? {
        ranges.first { $0.style == .arabic }
    }

    /// Style of the pages before `mainRange` (the leading range starting at page 1, when it is not the main range itself).
    var frontMatterStyle: PrintedNumberingStyle {
        guard let first = ranges.first, first.style != .arabic else { return .none }
        return first.style
    }

    /// Ranges beyond the simple two: everything after the main Arabic range (an appendix restarting at 1, a second Roman section…).
    var additionalRanges: [Range] {
        guard let main = mainRange, let mainIndex = ranges.firstIndex(of: main) else { return [] }
        return Array(ranges[(mainIndex + 1)...])
    }

    // MARK: Anchoring

    /// The storable plan: each range anchored to the page currently at its start position.
    ///
    /// A range that starts on page 1 *counting from 1* is anchored to "the first page of the project" rather than to that particular page — it means "numbering begins at the beginning", so a page later added at the front becomes 1 / i. A range on page 1 with any other start value ("this scan begins at printed page 41") is a statement about that page and is anchored to it. Ranges past the last page, or on a page without a `uuid`, are dropped.
    func anchored(to pages: [Page]) -> PrintedNumberingPlan {
        var idsByPosition: [Int: UUID] = [:]
        for page in pages {
            if let uuid = page.uuid { idsByPosition[page.pageNumber] = uuid }
        }
        let stored: [PrintedNumberingRange] = ranges.compactMap { range in
            if range.startPage == 1, range.startValue == 1 || range.style == .none {
                return PrintedNumberingRange(id: range.id, startPageID: nil, style: range.style, startValue: range.startValue)
            }
            guard let anchor = idsByPosition[range.startPage] else { return nil }
            return PrintedNumberingRange(id: range.id, startPageID: anchor, style: range.style, startValue: range.startValue)
        }
        return PrintedNumberingPlan(ranges: stored)
    }
}

nonisolated enum PageNumbering {

    /// The label printed on project page `projectPage`, or `nil` when the project has no printed-numbering plan (or the page is unnumbered).
    ///
    /// Example — plan `ResolvedPrintedNumbering.simple(startPage: 9, startValue: 1, frontMatter: .roman)`:
    /// page 1 → "i", page 8 → "viii", page 9 → "1", page 20 → "12".
    static func printedLabel(forProjectPage projectPage: Int, in document: Document) -> String? {
        resolvedPlan(for: document)?.label(forProjectPage: projectPage)
    }

    /// The project page that carries printed number `printedValue` (Arabic ranges only), or `nil` if none does.
    static func projectPage(forPrintedValue printedValue: Int, in document: Document) -> Int? {
        resolvedPlan(for: document)?.projectPage(forPrintedValue: printedValue, totalPages: document.totalPages)
    }

    /// The document's plan placed against its current page order, or `nil` when printed numbering is off.
    static func resolvedPlan(for document: Document) -> ResolvedPrintedNumbering? {
        let pages = document.sortedPages
        guard let plan = PrintedNumberingPlan.decode(document.printedNumberingData, pages: pages) else { return nil }
        return plan.resolved(against: pages)
    }

    /// `Page.uuid` → project page number, the lookup `PrintedNumberingPlan.resolved(positions:)` takes.
    static func positions(of pages: [Page]) -> [UUID: Int] {
        var positions: [UUID: Int] = [:]
        for page in pages {
            if let uuid = page.uuid { positions[uuid] = page.pageNumber }
        }
        return positions
    }

    /// Keeps the numbering plan intact when `page` is about to leave `document` (delete, or the second half going away when separated pages are rejoined): a range anchored to it moves to the page that will take its place. Call **before** removing the page or renumbering the others.
    static func pageWillBeDeleted(_ page: Page, from document: Document) {
        guard let deleted = page.uuid, let plan = document.printedNumbering,
              plan.ranges.contains(where: { $0.startPageID == deleted }) else { return }
        let successor = document.unwrappedPages.first { $0.pageNumber == page.pageNumber + 1 }?.uuid
        let updated = plan.reanchoring(deleted: deleted, to: successor)
        document.printedNumbering = updated.ranges.isEmpty ? nil : updated
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
