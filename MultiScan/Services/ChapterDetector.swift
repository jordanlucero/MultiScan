//
//  ChapterDetector.swift
//  MultiScan
//
//  Finds where chapters / parts / sections begin and labels those pages (`Page.sectionTitle`), so the thumbnail sidebar, the page grid, the Digest, and exports can group pages.
//
//  ## Signals (strongest first)
//  1. **Explicit chapter lines.** A page whose first non-empty line (or Vision-detected title) reads like "Chapter 7", "CHAPTER SEVEN", "Part II", "Book One", "7. The Return", or a bare Roman numeral on its own line. Regex-based; see `chapterLinePattern`.
//  2. **Running-header runs.** Smart Cleanup already groups near-identical lines that repeat across near-contiguous pages (`TextManipulationService.detectSectionHeaders`). The first page of each run is where that header *starts* — a chapter boundary in most books. Runs covering more than 60 % of the project are the book's own title (alternating-header books put it on every other page) and are ignored; runs shorter than 2 pages are noise.
//  3. **Vision titles.** `VisionDocumentLayout.title` on a page that isn't otherwise a chapter start but whose title is distinct, large, and not repeated elsewhere is treated as a weak candidate — only used when nothing stronger marked a chapter within the previous 2 pages.
//
//  Candidates within one page of each other collapse to the earliest (a chapter opener often has both the explicit line and the first running header).
//
//  ## Applying
//  `apply(to:cache:)` writes `sectionTitle` only on pages the user hasn't hand-edited (`sectionTitleIsAutomatic == true` or no title yet) and clears stale automatic titles. Manual titles always win. It is called after a new import and from the sidebar's "Detect Chapters" action; it is **not** re-run on every save — the user's structure shouldn't shift under them.
//
//  Pure analysis is `nonisolated` and tested; `apply` runs on the main context.
//

import Foundation

nonisolated enum ChapterDetector {

    /// One proposed chapter boundary.
    struct Candidate: Equatable, Sendable {
        enum Source: Equatable, Sendable { case explicitLine, headerRun, visionTitle }
        var pageNumber: Int
        var title: String
        var source: Source
    }

    /// Per-page inputs the detector needs — all stored columns, no external reads.
    struct PageInput: Sendable {
        var pageNumber: Int
        var plainText: String
        var visionTitle: String?
    }

    // MARK: Analysis

    /// Proposes chapter starts for a project. `cache` supplies the repeated-header analysis; `pages` supply per-page text and Vision titles.
    static func detect(pages: [PageInput], cache: TextExportCache?) -> [Candidate] {
        let sorted = pages.sorted { $0.pageNumber < $1.pageNumber }
        guard !sorted.isEmpty else { return [] }
        let totalPages = sorted.count
        var candidates: [Candidate] = []

        // 1. Explicit chapter lines.
        for page in sorted {
            let lines = page.plainText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            // Look at the first three lines: openers often start with a decorative ornament or the running header.
            for line in lines.prefix(3) {
                if let title = explicitChapterTitle(fromLine: line, nextLine: lines.count > 1 ? lines[min(1, lines.count - 1)] : nil) {
                    candidates.append(Candidate(pageNumber: page.pageNumber, title: title, source: .explicitLine))
                    break
                }
            }
            if let visionTitle = page.visionTitle, let title = explicitChapterTitle(fromLine: visionTitle, nextLine: nil),
               !candidates.contains(where: { $0.pageNumber == page.pageNumber }) {
                candidates.append(Candidate(pageNumber: page.pageNumber, title: title, source: .explicitLine))
            }
        }

        // 2. Running-header runs.
        if let cache {
            let analysis = TextManipulationService.analyzeForSmartCleanup(cache: cache)
            for header in analysis.sectionHeaders {
                let coverage = Double(header.affectedPages.count) / Double(totalPages)
                guard header.affectedPages.count >= 2, coverage <= 0.6 else { continue }
                let title = cleanedTitle(header.displayText)
                guard !title.isEmpty else { continue }
                candidates.append(Candidate(pageNumber: header.pageRange.lowerBound, title: title, source: .headerRun))
            }
        }

        // 3. Vision titles (weak).
        let titleCounts = Dictionary(grouping: sorted.compactMap { $0.visionTitle.map(TextManipulationService.normalize) }, by: { $0 }).mapValues(\.count)
        // How many pages carry each (normalized) leading line — a title that is also a line on other pages is a running header.
        var leadingLinePageCounts: [String: Int] = [:]
        for page in sorted {
            let leading = page.plainText.components(separatedBy: .newlines)
                .map { TextManipulationService.normalize($0) }
                .filter { !$0.isEmpty }
                .prefix(3)
            for line in Set(leading) { leadingLinePageCounts[line, default: 0] += 1 }
        }
        for page in sorted {
            guard let visionTitle = page.visionTitle?.trimmingCharacters(in: .whitespacesAndNewlines), visionTitle.count >= 3 else { continue }
            let normalized = TextManipulationService.normalize(visionTitle)
            guard titleCounts[normalized] == 1 else { continue } // repeated → running header, handled above
            guard (leadingLinePageCounts[normalized] ?? 0) <= 1 else { continue } // appears on other pages' text → running header
            guard TextManipulationService.extractPageNumber(from: visionTitle) == nil else { continue }
            candidates.append(Candidate(pageNumber: page.pageNumber, title: cleanedTitle(visionTitle), source: .visionTitle))
        }

        return merge(candidates)
    }

    /// Collapses candidates within one page of each other, preferring explicit lines, then header runs, then Vision titles; drops weak Vision titles that sit within 2 pages after a stronger start.
    static func merge(_ candidates: [Candidate]) -> [Candidate] {
        let strength: (Candidate.Source) -> Int = { source in
            switch source { case .explicitLine: 3; case .headerRun: 2; case .visionTitle: 1 }
        }
        let sorted = candidates.sorted {
            $0.pageNumber != $1.pageNumber ? $0.pageNumber < $1.pageNumber : strength($0.source) > strength($1.source)
        }
        var result: [Candidate] = []
        for candidate in sorted {
            if let last = result.last {
                if candidate.pageNumber - last.pageNumber <= 1 {
                    // Same boundary; keep the stronger (already first by sort) unless the newcomer is stronger.
                    if strength(candidate.source) > strength(last.source) { result[result.count - 1] = candidate }
                    continue
                }
                if candidate.source == .visionTitle, candidate.pageNumber - last.pageNumber <= 2 { continue }
            }
            result.append(candidate)
        }
        return result
    }

    // MARK: Explicit chapter lines

    /// "Chapter 7", "CHAPTER SEVEN: The Return", "Part II", "Book One", "VII", "7 The Return". Returns a display title or nil.
    static func explicitChapterTitle(fromLine line: String, nextLine: String?) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return nil }
        let lower = trimmed.lowercased()

        let keywords = ["chapter", "part", "section", "book", "act", "canto", "capítulo", "parte", "sección", "libro"]
        for keyword in keywords where lower.hasPrefix(keyword + " ") || lower == keyword {
            let rest = trimmed.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
            // Needs a number word, digit, or Roman numeral right after the keyword — "Chapter books are great" is prose.
            let firstToken = rest.split(separator: " ").first.map(String.init) ?? ""
            let token = firstToken.trimmingCharacters(in: CharacterSet(charactersIn: ".:–—-"))
            guard token.isEmpty == false, isNumberLike(token) else { continue }
            // "Chapter 7" alone → borrow the next line as the title when it looks like one.
            if rest.split(separator: " ").count == 1, let nextLine, isTitleLike(nextLine) {
                return cleanedTitle(trimmed) + ": " + cleanedTitle(nextLine)
            }
            return cleanedTitle(trimmed)
        }

        // A bare Roman numeral on its own line (II, XIV) — a common chapter marker in older books.
        if PageNumbering.value(ofRomanNumeral: trimmed) != nil, trimmed.count <= 6, trimmed == trimmed.uppercased() {
            if let nextLine, isTitleLike(nextLine) {
                return trimmed + ": " + cleanedTitle(nextLine)
            }
            return trimmed
        }
        return nil
    }

    private static let numberWords: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty",
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
        "uno", "dos", "tres", "cuatro", "cinco", "seis", "siete", "ocho", "nueve", "diez", "primero", "segundo", "tercero"
    ]

    private static func isNumberLike(_ token: String) -> Bool {
        if Int(token) != nil { return true }
        if PageNumbering.value(ofRomanNumeral: token) != nil { return true }
        return numberWords.contains(token.lowercased())
    }

    /// Short, no terminal period, not a page number: looks like a title rather than body text.
    private static func isTitleLike(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard (2...70).contains(trimmed.count), !trimmed.hasSuffix("."), !trimmed.hasSuffix(",") else { return false }
        guard TextManipulationService.extractPageNumber(from: trimmed) == nil else { return false }
        return trimmed.split(separator: " ").count <= 10
    }

    /// Trims, collapses whitespace, drops a trailing page number, caps length.
    static func cleanedTitle(_ text: String) -> String {
        var title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let decomposed = TextManipulationService.decomposeHeaderLine(TextManipulationService.normalize(title))
        if decomposed.pageNumber != nil, !decomposed.coreText.isEmpty {
            // Remove the edge number from the *original-case* text by dropping the matching token.
            var tokens = title.split(separator: " ").map(String.init)
            if let last = tokens.last, TextManipulationService.parseNumericToken(TextManipulationService.normalize(last)) != nil { tokens.removeLast() }
            else if let first = tokens.first, TextManipulationService.parseNumericToken(TextManipulationService.normalize(first)) != nil { tokens.removeFirst() }
            title = tokens.joined(separator: " ")
        }
        title = title.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        if title.count > 80 { title = String(title.prefix(79)) + "…" }
        return title
    }

    // MARK: Applying (main context)

    /// Marks chapter starts on `document`, honoring manual titles. Returns the number of pages changed.
    @discardableResult
    @MainActor
    static func apply(to document: Document) -> Int {
        let pages = document.sortedPages
        let inputs = pages.map { PageInput(pageNumber: $0.pageNumber, plainText: $0.plainText, visionTitle: $0.visionLayout?.title) }
        let cache = TextExportCacheService.loadFreshCache(from: document)
        let candidates = detect(pages: inputs, cache: cache)
        let byPage = Dictionary(candidates.map { ($0.pageNumber, $0) }, uniquingKeysWith: { first, _ in first })

        var changed = 0
        for page in pages {
            let isEditable = page.sectionTitle == nil || page.sectionTitleIsAutomatic
            guard isEditable else { continue }
            if let candidate = byPage[page.pageNumber] {
                if page.sectionTitle != candidate.title {
                    page.sectionTitle = candidate.title
                    page.sectionTitleIsAutomatic = true
                    changed += 1
                }
            } else if page.sectionTitle != nil, page.sectionTitleIsAutomatic {
                page.sectionTitle = nil
                page.sectionTitleIsAutomatic = false
                changed += 1
            }
        }
        if changed > 0 { document.lastModified = Date() }
        return changed
    }
}
