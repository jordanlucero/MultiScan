// TextManipulationService may be useful for exaptation from MultiScan.
// Based on the version from MultiScan v1.x releases

import Foundation

/// Service for programmatic text transformations on AttributedString.
/// All operations preserve formatting attributes (bold, italic, etc.)
enum TextManipulationService {

    // MARK: - Line Break Removal

    /// Replaces all line break characters (\n, \r\n, \r) with single spaces
    /// - Parameter text: The attributed string to transform
    /// - Returns: A new attributed string with line breaks replaced by spaces
    static func removingLineBreaks(from text: AttributedString) -> AttributedString {
        var result = AttributedString()

        // Iterate through runs to preserve attributes on each segment
        for run in text.runs {
            var runText = String(text[run.range].characters)

            // Replace all line break variants with single space
            runText = runText.replacingOccurrences(of: "\r\n", with: " ")
            runText = runText.replacingOccurrences(of: "\n", with: " ")
            runText = runText.replacingOccurrences(of: "\r", with: " ")

            // Create new attributed substring with same attributes
            var newSegment = AttributedString(runText)
            newSegment.mergeAttributes(run.attributes)
            result.append(newSegment)
        }

        return result
    }

    // MARK: - Smart Cleanup Types

    /// Where a detected artifact appears in the page text
    enum LinePosition: Sendable {
        case firstLine
        case lastLine
    }

    /// A detected page number at the top or bottom of a page's text
    struct PageNumberDetection: Sendable {
        let pageNumber: Int
        let detectedNumber: Int
        let numberText: String       // exact text of the number for token-level removal (e.g., "42", "1,234")
        let lineText: String
        let normalizedLine: String
        let position: LinePosition
    }

    /// A detected section header that repeats across a contiguous run of pages
    struct SectionHeaderDetection: Sendable {
        let headerText: String
        let displayText: String
        let pageRange: ClosedRange<Int>
        let affectedPages: [Int]  // actual pages with this header (subset of range for alternating headers)
    }

    /// A group of consecutive integers detected across adjacent project pages
    struct ConsecutiveNumberGroup: Sendable {
        let numbers: [Int]                  // consecutive values in order
        let pageMapping: [Int: [String]]    // project page → number texts found on that page
        let pageRange: ClosedRange<Int>     // span of project pages
    }

    /// Complete result of analyzing a document for cleanup candidates
    struct SmartCleanupResult: Sendable {
        let pageNumbers: [PageNumberDetection]
        let sectionHeaders: [SectionHeaderDetection]
        let consecutiveNumbers: [ConsecutiveNumberGroup]
        let totalPages: Int

        var isEmpty: Bool {
            pageNumbers.isEmpty && sectionHeaders.isEmpty && consecutiveNumbers.isEmpty
        }
    }

    /// A concrete cleanup action the user can take
    enum CleanupOption: Identifiable, Sendable {
        case removePageNumber(detection: PageNumberDetection)
        case removeSectionHeaderFromPage(header: SectionHeaderDetection, pageNumber: Int)
        case removeSectionHeaderFromRange(header: SectionHeaderDetection)
        case removeConsecutiveNumbers(group: ConsecutiveNumberGroup, pageNumber: Int)
        case removeConsecutiveNumbersFromRange(group: ConsecutiveNumberGroup)
        case removeAllPageNumbers(detections: [PageNumberDetection], consecutiveGroups: [ConsecutiveNumberGroup])

        var id: String {
            switch self {
            case .removePageNumber(let d):
                "pn-\(d.pageNumber)-\(d.detectedNumber)"
            case .removeSectionHeaderFromPage(let h, let p):
                "sh-page-\(p)-\(h.headerText)"
            case .removeSectionHeaderFromRange(let h):
                "sh-range-\(h.pageRange.lowerBound)-\(h.pageRange.upperBound)-\(h.headerText)"
            case .removeConsecutiveNumbers(let g, let p):
                "cn-page-\(p)-\(g.numbers.first ?? 0)"
            case .removeConsecutiveNumbersFromRange(let g):
                "cn-range-\(g.pageRange.lowerBound)-\(g.pageRange.upperBound)"
            case .removeAllPageNumbers:
                "all-pn"
            }
        }

        var label: String {
            switch self {
            case .removePageNumber(let d):
                return String(localized: "Remove page number (\(d.detectedNumber)) from this page")
            case .removeSectionHeaderFromPage(let h, _):
                return String(localized: "Remove \"\(h.displayText)\" from this page")
            case .removeSectionHeaderFromRange(let h):
                return String(localized: "Remove \"\(h.displayText)\" from pages \(h.pageRange.lowerBound)–\(h.pageRange.upperBound)")
            case .removeConsecutiveNumbers(let g, let p):
                let texts = g.pageMapping[p] ?? []
                let joined = texts.joined(separator: ", ")
                return String(localized: "Remove \(joined) from this page")
            case .removeConsecutiveNumbersFromRange(let g):
                return String(localized: "Remove consecutive page numbers from pages \(g.pageRange.lowerBound)–\(g.pageRange.upperBound)")
            case .removeAllPageNumbers:
                return String(localized: "Remove detected page numbers from the entire document")
            }
        }
    }

    // MARK: - Text Normalization

    /// Normalizes text for fuzzy matching across OCR variations.
    /// Lowercases, collapses whitespace, normalizes dashes and smart quotes.
    static func normalize(_ text: String) -> String {
        var result = text.lowercased()
        // Normalize dash variants to hyphen-minus
        result = result.replacingOccurrences(of: "\u{2014}", with: "-") // em-dash
        result = result.replacingOccurrences(of: "\u{2013}", with: "-") // en-dash
        result = result.replacingOccurrences(of: "\u{2012}", with: "-") // figure-dash
        result = result.replacingOccurrences(of: "\u{2212}", with: "-") // minus sign
        // Normalize smart quotes
        result = result.replacingOccurrences(of: "\u{201C}", with: "\"") // left double
        result = result.replacingOccurrences(of: "\u{201D}", with: "\"") // right double
        result = result.replacingOccurrences(of: "\u{2018}", with: "'")  // left single
        result = result.replacingOccurrences(of: "\u{2019}", with: "'")  // right single
        // Collapse whitespace
        result = result.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Page Number Detection

    /// Attempts to extract a page number from a single line of text.
    /// Matches standalone numbers, "Page X", "p. X", and "- X -" patterns.
    /// Attempts to extract a page number from a single line of text.
    /// Matches standalone numbers, "Page X", "p. X", and "- X -" patterns.
    /// Also returns the text of the matched number portion for token-level removal.
    static func extractPageNumber(from line: String) -> (number: Int, numberText: String)? {
        let normalized = normalize(line)
        guard !normalized.isEmpty else { return nil }

        // Pattern 1: Standalone number (e.g., "42", "1,234")
        if let num = parseNumericToken(normalized) {
            return (num, normalized)
        }

        // Pattern 2: "page X" or "page X." (e.g., "page 42", "Page 42.")
        if let rest = dropPrefix("page ", from: normalized) {
            let cleaned = rest.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if let num = parseNumericToken(cleaned) {
                return (num, cleaned)
            }
        }

        // Pattern 3: "p. X" or "p X" (e.g., "p. 42", "p 42")
        if normalized.hasPrefix("p") {
            let afterP = String(normalized.dropFirst())
                .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            if let num = parseNumericToken(afterP) {
                return (num, afterP)
            }
        }

        // Pattern 4: "- X -" centered page number (e.g., "- 42 -")
        if normalized.hasPrefix("-") && normalized.hasSuffix("-") {
            let inner = normalized.dropFirst().dropLast()
                .trimmingCharacters(in: .whitespaces)
            if let num = parseNumericToken(inner) {
                return (num, inner)
            }
        }

        return nil
    }

    // MARK: - String Helpers

    /// Parses a numeric token that may contain thousands-separator commas.
    /// Enforces a maximum of 5 characters (digits + commas) to limit to reasonable page numbers.
    /// Returns nil for non-numeric input or tokens exceeding the length limit.
    static func parseNumericToken(_ text: String) -> Int? {
        guard !text.isEmpty, text.count <= 5 else { return nil }

        // Must contain only digits and commas
        guard text.allSatisfy({ $0.isNumber || $0 == "," }) else { return nil }

        // Must not start or end with comma
        guard !text.hasPrefix(","), !text.hasSuffix(",") else { return nil }

        // Must not have consecutive commas
        guard !text.contains(",,") else { return nil }

        // Remove commas and parse
        let digitsOnly = text.replacingOccurrences(of: ",", with: "")
        guard !digitsOnly.isEmpty else { return nil }
        return Int(digitsOnly)
    }

    /// Checks if a string starts with a prefix and returns the remainder
    private static func dropPrefix(_ prefix: String, from string: String) -> String? {
        guard string.hasPrefix(prefix) else { return nil }
        return String(string.dropFirst(prefix.count))
    }

    /// Maps commonly confused digit-letter characters to canonical forms for OCR-variant matching.
    /// Applied after normalize() to group visually similar strings.
    static func ocrNormalize(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "1", with: "l")
        result = result.replacingOccurrences(of: "0", with: "o")
        return result
    }

    /// Computes the Levenshtein edit distance between two strings.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a)
        let b = Array(b)
        let m = a.count
        let n = b.count

        if m == 0 { return n }
        if n == 0 { return m }

        var prev = Array(0...n)
        var curr = Array(repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    curr[j] = prev[j - 1]
                } else {
                    curr[j] = 1 + min(prev[j], curr[j - 1], prev[j - 1])
                }
            }
            (prev, curr) = (curr, prev)
        }

        return prev[n]
    }

    /// Maximum allowed edit distance for fuzzy section header matching, scaled by string length.
    private static func maxEditDistance(for length: Int) -> Int {
        length >= 5 ? 2 : 1
    }

    /// Result of decomposing a header line into its text and number parts
    struct LineComponents: Sendable {
        let coreText: String    // normalized text without trailing/leading number
        let pageNumber: Int?    // extracted trailing/leading number, if any
        let fullNormalized: String // the original normalized line
    }

    /// Splits a normalized line into its header text and optional trailing/leading page number.
    /// Only strips numbers at the edges, not embedded ones (e.g., "chapter 1 of 3 42" → core: "chapter 1 of 3", number: 42).
    static func decomposeHeaderLine(_ normalizedLine: String) -> LineComponents {
        let tokens = normalizedLine.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else {
            return LineComponents(coreText: "", pageNumber: nil, fullNormalized: normalizedLine)
        }

        // Check if last token is a standalone number
        if tokens.count > 1, let num = parseNumericToken(tokens.last!) {
            let coreTokens = tokens.dropLast()
            return LineComponents(
                coreText: coreTokens.joined(separator: " "),
                pageNumber: num,
                fullNormalized: normalizedLine
            )
        }

        // Check if first token is a standalone number
        if tokens.count > 1, let num = parseNumericToken(tokens.first!) {
            let coreTokens = tokens.dropFirst()
            return LineComponents(
                coreText: coreTokens.joined(separator: " "),
                pageNumber: num,
                fullNormalized: normalizedLine
            )
        }

        // Single token that's a number
        if tokens.count == 1, let num = parseNumericToken(tokens[0]) {
            return LineComponents(coreText: "", pageNumber: num, fullNormalized: normalizedLine)
        }

        // No number found
        return LineComponents(coreText: normalizedLine, pageNumber: nil, fullNormalized: normalizedLine)
    }

    // MARK: - Analysis

    /// Analyzes a document's text cache for removable artifacts (page numbers and section headers).
    static func analyzeForSmartCleanup(cache: TextExportCache) -> SmartCleanupResult {
        let sortedEntries = cache.pages.sorted { $0.pageNumber < $1.pageNumber }
        guard !sortedEntries.isEmpty else {
            return SmartCleanupResult(pageNumbers: [], sectionHeaders: [], consecutiveNumbers: [], totalPages: 0)
        }

        // Detect page numbers (standalone patterns AND mixed header+number lines)
        var pageNumberDetections: [PageNumberDetection] = []
        for entry in sortedEntries {
            let plainText = String(entry.richText.characters)
            let lines = plainText.components(separatedBy: .newlines)
            let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

            // Check first non-empty line
            if let firstLine = nonEmptyLines.first {
                let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
                let normalized = normalize(trimmed)

                if let result = extractPageNumber(from: trimmed) {
                    // Standalone page number pattern (e.g., "42", "Page 42")
                    pageNumberDetections.append(PageNumberDetection(
                        pageNumber: entry.pageNumber,
                        detectedNumber: result.number,
                        numberText: result.numberText,
                        lineText: trimmed,
                        normalizedLine: normalized,
                        position: .firstLine
                    ))
                } else {
                    // Check for trailing/leading number in mixed line (e.g., "Chapter 1  42")
                    let decomposed = decomposeHeaderLine(normalized)
                    if let num = decomposed.pageNumber, !decomposed.coreText.isEmpty {
                        // Find the actual number text from the original tokens
                        let tokens = normalized.split(separator: " ").map(String.init)
                        let numText = tokens.last.flatMap({ parseNumericToken($0) != nil ? tokens.last! : nil })
                            ?? tokens.first.flatMap({ parseNumericToken($0) != nil ? tokens.first! : nil })
                            ?? String(num)
                        pageNumberDetections.append(PageNumberDetection(
                            pageNumber: entry.pageNumber,
                            detectedNumber: num,
                            numberText: numText,
                            lineText: trimmed,
                            normalizedLine: normalized,
                            position: .firstLine
                        ))
                    }
                }
            }

            // Check last non-empty line (only if page has more than one line)
            if let lastLine = nonEmptyLines.last, nonEmptyLines.count > 1 {
                let trimmed = lastLine.trimmingCharacters(in: .whitespaces)
                let normalized = normalize(trimmed)

                if let result = extractPageNumber(from: trimmed) {
                    pageNumberDetections.append(PageNumberDetection(
                        pageNumber: entry.pageNumber,
                        detectedNumber: result.number,
                        numberText: result.numberText,
                        lineText: trimmed,
                        normalizedLine: normalized,
                        position: .lastLine
                    ))
                } else {
                    let decomposed = decomposeHeaderLine(normalized)
                    if let num = decomposed.pageNumber, !decomposed.coreText.isEmpty {
                        let tokens = normalized.split(separator: " ").map(String.init)
                        let numText = tokens.last.flatMap({ parseNumericToken($0) != nil ? tokens.last! : nil })
                            ?? tokens.first.flatMap({ parseNumericToken($0) != nil ? tokens.first! : nil })
                            ?? String(num)
                        pageNumberDetections.append(PageNumberDetection(
                            pageNumber: entry.pageNumber,
                            detectedNumber: num,
                            numberText: numText,
                            lineText: trimmed,
                            normalizedLine: normalized,
                            position: .lastLine
                        ))
                    }
                }
            }
        }

        // Detect section headers
        let sectionHeaders = detectSectionHeaders(entries: sortedEntries)

        // Detect consecutive numbers anywhere in text
        let consecutiveNumbers = detectConsecutiveNumbers(entries: sortedEntries)

        return SmartCleanupResult(
            pageNumbers: pageNumberDetections,
            sectionHeaders: sectionHeaders,
            consecutiveNumbers: consecutiveNumbers,
            totalPages: sortedEntries.count
        )
    }

    /// Finds near-contiguous runs of 2+ pages sharing the same text anywhere in their non-empty lines.
    /// Uses OCR-aware fuzzy matching: applies digit-letter normalization, then merges groups within
    /// edit distance ≤ 2. Displays the most common text variant in the UI.
    /// Lines must be at least 3 characters (after normalization) to avoid false positives on short OCR artifacts.
    private static func detectSectionHeaders(entries: [PageCacheEntry]) -> [SectionHeaderDetection] {
        // Phase 1: Extract candidate lines and group by OCR-normalized core text
        struct Occurrence {
            let pageNumber: Int
            let coreText: String     // raw normalized core text (for removal matching)
            let displayText: String  // for UI display
        }

        // Key: OCR-normalized core text, Value: occurrences
        var lineOccurrences: [String: [Occurrence]] = [:]

        for entry in entries {
            let plainText = String(entry.richText.characters)
            let lines = plainText.components(separatedBy: .newlines)
            let allNonEmpty = lines
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

            // Collect all non-empty lines (deduplicated — same line appearing multiple times on a page counts once)
            var seenLines: Set<String> = []
            var candidateLines: [String] = []
            for line in allNonEmpty {
                if seenLines.insert(line).inserted {
                    candidateLines.append(line)
                }
            }

            for line in candidateLines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let normalized = normalize(trimmed)

                // Skip lines that are purely a page number pattern
                if extractPageNumber(from: trimmed)?.number != nil { continue }

                // Decompose to get core text (without trailing/leading number)
                let decomposed = decomposeHeaderLine(normalized)
                let coreText = decomposed.coreText.isEmpty ? normalized : decomposed.coreText

                // Skip very short core texts
                guard coreText.count >= 3 else { continue }

                // Use the core text (without number) for display
                let displayCore: String
                if decomposed.coreText.isEmpty {
                    displayCore = trimmed
                } else if decomposed.pageNumber != nil {
                    let originalDecomposed = decomposeHeaderLine(normalized)
                    displayCore = originalDecomposed.coreText
                } else {
                    displayCore = trimmed
                }

                let ocrKey = ocrNormalize(coreText)
                lineOccurrences[ocrKey, default: []].append(
                    Occurrence(pageNumber: entry.pageNumber, coreText: coreText, displayText: displayCore)
                )
            }
        }

        // Phase 2: Merge groups whose OCR-normalized keys are within edit distance threshold
        let keys = Array(lineOccurrences.keys)
        var mergedGroups: [[String]] = []
        var assigned: Set<String> = []

        // Sort by occurrence count (most common first becomes canonical)
        let sortedKeys = keys.sorted { (lineOccurrences[$0]?.count ?? 0) > (lineOccurrences[$1]?.count ?? 0) }

        for key in sortedKeys {
            if assigned.contains(key) { continue }
            var group = [key]
            assigned.insert(key)

            for otherKey in sortedKeys {
                if assigned.contains(otherKey) { continue }
                let maxAllowed = maxEditDistance(for: min(key.count, otherKey.count))
                if editDistance(key, otherKey) <= maxAllowed {
                    group.append(otherKey)
                    assigned.insert(otherKey)
                }
            }

            mergedGroups.append(group)
        }

        // Build merged occurrences with most common text variants
        struct MergedGroup {
            let headerText: String   // most common coreText for removal matching
            let displayText: String  // most common display variant
            let occurrences: [(pageNumber: Int, displayText: String)]
        }

        var merged: [MergedGroup] = []
        for group in mergedGroups {
            var allOccurrences: [Occurrence] = []
            for key in group {
                allOccurrences.append(contentsOf: lineOccurrences[key] ?? [])
            }

            guard allOccurrences.count >= 2 else { continue }

            // Most common coreText variant (for removal matching)
            let coreTextCounts = Dictionary(grouping: allOccurrences, by: { $0.coreText })
                .mapValues { $0.count }
            let bestCoreText = coreTextCounts.max(by: { $0.value < $1.value })!.key

            // Most common display variant (for UI)
            let displayCounts = Dictionary(grouping: allOccurrences, by: { $0.displayText })
                .mapValues { $0.count }
            let bestDisplay = displayCounts.max(by: { $0.value < $1.value })!.key

            merged.append(MergedGroup(
                headerText: bestCoreText,
                displayText: bestDisplay,
                occurrences: allOccurrences.map { (pageNumber: $0.pageNumber, displayText: $0.displayText) }
            ))
        }

        // Phase 3: Find near-contiguous runs of 2+ pages
        var detections: [SectionHeaderDetection] = []

        for group in merged {
            let sorted = group.occurrences.sorted { $0.pageNumber < $1.pageNumber }

            var runStart = 0
            for i in 1...sorted.count {
                let isNearContiguous = i < sorted.count &&
                    sorted[i].pageNumber <= sorted[i - 1].pageNumber + 5

                if !isNearContiguous {
                    let runLength = i - runStart
                    if runLength >= 2 {
                        let startPage = sorted[runStart].pageNumber
                        let endPage = sorted[i - 1].pageNumber
                        let affectedPages = (runStart..<i).map { sorted[$0].pageNumber }

                        detections.append(SectionHeaderDetection(
                            headerText: group.headerText,
                            displayText: group.displayText,
                            pageRange: startPage...endPage,
                            affectedPages: affectedPages
                        ))
                    }
                    runStart = i
                }
            }
        }

        return detections
    }

    // MARK: - Consecutive Number Detection

    /// Extracts all standalone numeric tokens from text, excluding the first and last non-empty lines
    /// (those are handled by the existing first/last line page number detection).
    private static func extractStandaloneNumbers(from plainText: String) -> [(value: Int, text: String)] {
        let lines = plainText.components(separatedBy: .newlines)
        let nonEmptyLines = lines.enumerated().filter {
            !$0.element.trimmingCharacters(in: .whitespaces).isEmpty
        }

        // Skip first and last non-empty lines
        guard nonEmptyLines.count > 2 else { return [] }
        let interiorIndices = Set(nonEmptyLines.dropFirst().dropLast().map { $0.offset })

        var results: [(value: Int, text: String)] = []
        for (lineIndex, line) in lines.enumerated() {
            guard interiorIndices.contains(lineIndex) else { continue }

            let tokens = line.split(whereSeparator: { $0.isWhitespace })
            for token in tokens {
                // Strip leading/trailing non-digit characters (punctuation)
                var stripped = String(token)
                while let first = stripped.first, !first.isNumber {
                    stripped.removeFirst()
                }
                while let last = stripped.last, !last.isNumber {
                    stripped.removeLast()
                }
                guard !stripped.isEmpty else { continue }

                if let value = parseNumericToken(stripped) {
                    results.append((value: value, text: stripped))
                }
            }
        }

        return results
    }

    /// Detects consecutive number series that span adjacent project pages.
    /// Only numbers found in interior lines (not first/last) are considered.
    /// Each number must have at least one adjacent project page with a number from the same consecutive run.
    private static func detectConsecutiveNumbers(entries: [PageCacheEntry]) -> [ConsecutiveNumberGroup] {
        // Step 1: Extract standalone numbers from each page's interior text
        // Key: number value, Value: [(projectPage, numberText)]
        var valueToOccurrences: [Int: [(page: Int, text: String)]] = [:]

        for entry in entries {
            let plainText = String(entry.richText.characters)
            let numbers = extractStandaloneNumbers(from: plainText)
            for num in numbers {
                valueToOccurrences[num.value, default: []].append((page: entry.pageNumber, text: num.text))
            }
        }

        guard !valueToOccurrences.isEmpty else { return [] }

        // Step 2: Find maximal consecutive integer runs
        let allValues = valueToOccurrences.keys.sorted()
        var runs: [[Int]] = []
        var currentRun: [Int] = []

        for value in allValues {
            if let last = currentRun.last, value == last + 1 {
                currentRun.append(value)
            } else {
                if currentRun.count >= 2 {
                    runs.append(currentRun)
                }
                currentRun = [value]
            }
        }
        if currentRun.count >= 2 {
            runs.append(currentRun)
        }

        // Step 3: For each run, verify cross-page adjacency and build groups
        var groups: [ConsecutiveNumberGroup] = []

        for run in runs {
            // Build set of pages that have numbers in this run
            var pagesInRun: Set<Int> = []
            for value in run {
                if let occurrences = valueToOccurrences[value] {
                    for occ in occurrences {
                        pagesInRun.insert(occ.page)
                    }
                }
            }

            // For each (value, page), check if an adjacent page also has a number in this run
            var validPairs: [(value: Int, page: Int, text: String)] = []
            for value in run {
                guard let occurrences = valueToOccurrences[value] else { continue }
                for occ in occurrences {
                    let hasAdjacentPage = pagesInRun.contains(occ.page - 1) || pagesInRun.contains(occ.page + 1)
                    if hasAdjacentPage {
                        validPairs.append((value: value, page: occ.page, text: occ.text))
                    }
                }
            }

            guard !validPairs.isEmpty else { continue }

            // Must span at least 2 different project pages
            let uniquePages = Set(validPairs.map { $0.page })
            guard uniquePages.count >= 2 else { continue }

            // Build the group
            let sortedValues = Set(validPairs.map { $0.value }).sorted()
            var pageMapping: [Int: [String]] = [:]
            for pair in validPairs {
                pageMapping[pair.page, default: []].append(pair.text)
            }

            let sortedPages = uniquePages.sorted()
            groups.append(ConsecutiveNumberGroup(
                numbers: sortedValues,
                pageMapping: pageMapping,
                pageRange: sortedPages.first!...sortedPages.last!
            ))
        }

        return groups
    }

    // MARK: - Building Options

    /// Builds the cleanup options relevant to a specific page from the analysis result.
    static func buildOptions(
        from result: SmartCleanupResult,
        forPageNumber pageNumber: Int
    ) -> [CleanupOption] {
        var options: [CleanupOption] = []

        // Per-page page number removal (first/last line)
        let pageNumDetections = result.pageNumbers.filter { $0.pageNumber == pageNumber }
        for detection in pageNumDetections {
            options.append(.removePageNumber(detection: detection))
        }

        // Per-page and per-range section header removal (no document-wide option)
        let relevantHeaders = result.sectionHeaders.filter { $0.pageRange.contains(pageNumber) }
        for header in relevantHeaders {
            options.append(.removeSectionHeaderFromPage(header: header, pageNumber: pageNumber))
            if header.pageRange.count > 1 {
                options.append(.removeSectionHeaderFromRange(header: header))
            }
        }

        // Per-page and per-range consecutive number removal
        // Collect first/last line detected numbers on this page for deduplication
        let firstLastNumbers = Set(pageNumDetections.map { $0.detectedNumber })
        let relevantGroups = result.consecutiveNumbers.filter { $0.pageMapping[pageNumber] != nil }
        for group in relevantGroups {
            // Filter out numbers already covered by first/last line detection
            let pageTexts = group.pageMapping[pageNumber] ?? []
            let dedupedTexts = pageTexts.filter { text in
                guard let value = parseNumericToken(text) else { return true }
                return !firstLastNumbers.contains(value)
            }
            if !dedupedTexts.isEmpty {
                // Build a filtered group with only the deduped texts for this page
                var filteredMapping = group.pageMapping
                filteredMapping[pageNumber] = dedupedTexts
                let filteredGroup = ConsecutiveNumberGroup(
                    numbers: group.numbers,
                    pageMapping: filteredMapping,
                    pageRange: group.pageRange
                )
                options.append(.removeConsecutiveNumbers(group: filteredGroup, pageNumber: pageNumber))
            }
            // Range option uses the full group (includes all pages)
            if group.pageMapping.count > 1 {
                options.append(.removeConsecutiveNumbersFromRange(group: group))
            }
        }

        // Document-wide page number option (includes both first/last line AND consecutive)
        let hasPageNumbers = result.pageNumbers.count >= 2
        let hasConsecutive = !result.consecutiveNumbers.isEmpty
        if hasPageNumbers || hasConsecutive {
            options.append(.removeAllPageNumbers(
                detections: result.pageNumbers,
                consecutiveGroups: result.consecutiveNumbers
            ))
        }

        return options
    }

    // MARK: - Page Number Token Removal

    /// Removes a page number token and adjacent whitespace from an AttributedString.
    /// Only removes the number text (not the entire line). Collapses the line if it becomes empty.
    /// Searches for the first standalone occurrence of `numberText` (surrounded by non-digit/non-comma characters).
    static func removePageNumberToken(
        _ numberText: String,
        from text: AttributedString
    ) -> AttributedString {
        let plainText = String(text.characters)
        guard !plainText.isEmpty, !numberText.isEmpty else { return text }

        // Find the number as a standalone token in the plain text
        guard let tokenRange = findStandaloneToken(numberText, in: plainText) else {
            return text
        }

        let tokenStart = tokenRange.lowerBound
        let tokenEnd = tokenRange.upperBound

        // Find line boundaries
        let lineStart = findLineStart(in: plainText, before: tokenStart)
        let lineEnd = findLineEnd(in: plainText, after: tokenEnd)

        // Check if removing the token leaves an empty line
        let beforeToken = plainText[plainText.index(plainText.startIndex, offsetBy: lineStart)..<plainText.index(plainText.startIndex, offsetBy: tokenStart)]
        let afterToken = plainText[plainText.index(plainText.startIndex, offsetBy: tokenEnd)..<plainText.index(plainText.startIndex, offsetBy: lineEnd)]
        let remainingContent = String(beforeToken) + String(afterToken)

        var removeStart: Int
        var removeEnd: Int

        if remainingContent.trimmingCharacters(in: .whitespaces).isEmpty {
            // Line becomes empty — collapse it (remove line + newline)
            removeStart = lineStart
            removeEnd = lineEnd
            // Include the newline character
            if removeEnd < plainText.count {
                // Not last line: include trailing newline
                removeEnd += 1
            } else if removeStart > 0 {
                // Last line: include preceding newline
                removeStart -= 1
            }
        } else {
            // Line has other content — remove token + adjacent whitespace
            removeStart = tokenStart
            removeEnd = tokenEnd

            // Try to extend to preceding whitespace (spaces/tabs, not newlines)
            var precedingSpaces = 0
            var checkPos = removeStart - 1
            while checkPos >= lineStart {
                let idx = plainText.index(plainText.startIndex, offsetBy: checkPos)
                let ch = plainText[idx]
                if ch == " " || ch == "\t" {
                    precedingSpaces += 1
                    checkPos -= 1
                } else {
                    break
                }
            }

            if precedingSpaces > 0 {
                removeStart -= precedingSpaces
            } else {
                // No preceding space — try following whitespace
                var followingSpaces = 0
                checkPos = removeEnd
                while checkPos < lineEnd {
                    let idx = plainText.index(plainText.startIndex, offsetBy: checkPos)
                    let ch = plainText[idx]
                    if ch == " " || ch == "\t" {
                        followingSpaces += 1
                        checkPos += 1
                    } else {
                        break
                    }
                }
                removeEnd += followingSpaces
            }
        }

        // Map character offsets to AttributedString indices and remove
        var result = text
        let startIdx = result.characters.index(result.startIndex, offsetBy: removeStart)
        let endIdx = result.characters.index(result.startIndex, offsetBy: removeEnd)
        result.removeSubrange(startIdx..<endIdx)
        return result
    }

    /// Finds the first standalone occurrence of a token in text.
    /// "Standalone" means the character before and after are not digits or commas.
    /// Returns the character offset range, or nil if not found.
    private static func findStandaloneToken(_ token: String, in text: String) -> Range<Int>? {
        var searchStart = text.startIndex
        while let range = text.range(of: token, range: searchStart..<text.endIndex) {
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)
            let endOffset = offset + token.count

            // Check character before
            let beforeOK: Bool
            if range.lowerBound == text.startIndex {
                beforeOK = true
            } else {
                let before = text[text.index(before: range.lowerBound)]
                beforeOK = !before.isNumber && before != ","
            }

            // Check character after
            let afterOK: Bool
            if range.upperBound == text.endIndex {
                afterOK = true
            } else {
                let after = text[range.upperBound]
                afterOK = !after.isNumber && after != ","
            }

            if beforeOK && afterOK {
                return offset..<endOffset
            }

            // Move past this match
            searchStart = text.index(after: range.lowerBound)
        }
        return nil
    }

    /// Returns the character offset of the start of the line containing `position`.
    private static func findLineStart(in text: String, before position: Int) -> Int {
        var pos = position - 1
        while pos >= 0 {
            let idx = text.index(text.startIndex, offsetBy: pos)
            if text[idx] == "\n" {
                return pos + 1
            }
            pos -= 1
        }
        return 0
    }

    /// Returns the character offset of the end of the line containing or starting at `position` (exclusive, before newline).
    private static func findLineEnd(in text: String, after position: Int) -> Int {
        var pos = position
        while pos < text.count {
            let idx = text.index(text.startIndex, offsetBy: pos)
            if text[idx] == "\n" {
                return pos
            }
            pos += 1
        }
        return text.count
    }

    // MARK: - Line Removal

    /// Removes the first line whose content matches `normalizedTarget` from the given AttributedString.
    /// Removes the entire line including its newline character.
    /// Preserves all formatting attributes on surrounding text.
    ///
    /// When `stripNumbers` is true, uses OCR-aware fuzzy matching: strips trailing/leading page numbers,
    /// applies OCR normalization (digit-letter confusions), and allows edit distance ≤ 2.
    static func removeLine(
        matching normalizedTarget: String,
        from text: AttributedString,
        stripNumbers: Bool = false
    ) -> AttributedString {
        let plainText = String(text.characters)
        let lines = plainText.components(separatedBy: "\n")

        // Pre-compute OCR-normalized target for fuzzy matching
        let ocrTarget = stripNumbers ? ocrNormalize(normalizedTarget) : ""

        var charOffset = 0
        for (lineIndex, line) in lines.enumerated() {
            let normalizedLine = normalize(line)
            let compareText: String
            if stripNumbers {
                let decomposed = decomposeHeaderLine(normalizedLine)
                let coreText = decomposed.coreText.isEmpty ? normalizedLine : decomposed.coreText
                compareText = ocrNormalize(coreText)
            } else {
                compareText = normalizedLine
            }

            let isMatch: Bool
            if stripNumbers {
                let maxAllowed = maxEditDistance(for: min(compareText.count, ocrTarget.count))
                isMatch = editDistance(compareText, ocrTarget) <= maxAllowed
            } else {
                isMatch = compareText == normalizedTarget
            }

            if isMatch {
                // Calculate the range to remove (line + newline)
                var removeStart = charOffset
                var removeLength = line.count

                if lineIndex < lines.count - 1 {
                    // Not the last line: include trailing newline
                    removeLength += 1
                } else if lineIndex > 0 {
                    // Last line: include preceding newline
                    removeStart -= 1
                    removeLength += 1
                }

                // Map character offsets to AttributedString indices
                var result = text
                let startIdx = result.characters.index(
                    result.startIndex, offsetBy: removeStart
                )
                let endIdx = result.characters.index(
                    startIdx, offsetBy: removeLength
                )
                result.removeSubrange(startIdx..<endIdx)
                return result
            }
            charOffset += line.count + 1 // +1 for the \n separator
        }

        // No match found
        return text
    }
}
