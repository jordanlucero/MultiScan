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

    /// Complete result of analyzing a document for cleanup candidates
    struct SmartCleanupResult: Sendable {
        let pageNumbers: [PageNumberDetection]
        let sectionHeaders: [SectionHeaderDetection]
        let totalPages: Int

        var isEmpty: Bool {
            pageNumbers.isEmpty && sectionHeaders.isEmpty
        }
    }

    /// A concrete cleanup action the user can take
    enum CleanupOption: Identifiable, Sendable {
        case removePageNumber(detection: PageNumberDetection)
        case removeSectionHeaderFromPage(header: SectionHeaderDetection, pageNumber: Int)
        case removeSectionHeaderFromRange(header: SectionHeaderDetection)
        case removeAllPageNumbers(detections: [PageNumberDetection])
        case removeAllSectionHeaders(headers: [SectionHeaderDetection])

        var id: String {
            switch self {
            case .removePageNumber(let d):
                "pn-\(d.pageNumber)"
            case .removeSectionHeaderFromPage(let h, let p):
                "sh-page-\(p)-\(h.headerText)"
            case .removeSectionHeaderFromRange(let h):
                "sh-range-\(h.pageRange.lowerBound)-\(h.pageRange.upperBound)-\(h.headerText)"
            case .removeAllPageNumbers:
                "all-pn"
            case .removeAllSectionHeaders:
                "all-sh"
            }
        }

        var label: String {
            switch self {
            case .removePageNumber(let d):
                String(localized: "Remove page number (\(d.detectedNumber)) from this page")
            case .removeSectionHeaderFromPage(let h, _):
                String(localized: "Remove \"\(h.displayText)\" from this page")
            case .removeSectionHeaderFromRange(let h):
                String(localized: "Remove \"\(h.displayText)\" from pages \(h.pageRange.lowerBound)–\(h.pageRange.upperBound)")
            case .removeAllPageNumbers:
                String(localized: "Remove detected page numbers from the entire document")
            case .removeAllSectionHeaders:
                String(localized: "Remove detected section headers from the entire document")
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
    static func extractPageNumber(from line: String) -> Int? {
        let normalized = normalize(line)
        guard !normalized.isEmpty else { return nil }

        // Pattern 1: Standalone number (e.g., "42")
        if let num = Int(normalized) {
            return num
        }

        // Pattern 2: "page X" or "page X." (e.g., "page 42", "Page 42.")
        if let rest = dropPrefix("page ", from: normalized),
           let num = Int(rest.trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
            return num
        }

        // Pattern 3: "p. X" or "p X" (e.g., "p. 42", "p 42")
        if normalized.hasPrefix("p") {
            let afterP = String(normalized.dropFirst())
                .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            if let num = Int(afterP) {
                return num
            }
        }

        // Pattern 4: "- X -" centered page number (e.g., "- 42 -")
        if normalized.hasPrefix("-") && normalized.hasSuffix("-") {
            let inner = normalized.dropFirst().dropLast()
                .trimmingCharacters(in: .whitespaces)
            if let num = Int(inner) {
                return num
            }
        }

        return nil
    }

    // MARK: - String Helpers

    /// Checks if a string starts with a prefix and returns the remainder
    private static func dropPrefix(_ prefix: String, from string: String) -> String? {
        guard string.hasPrefix(prefix) else { return nil }
        return String(string.dropFirst(prefix.count))
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
        if tokens.count > 1, let num = Int(tokens.last!) {
            let coreTokens = tokens.dropLast()
            return LineComponents(
                coreText: coreTokens.joined(separator: " "),
                pageNumber: num,
                fullNormalized: normalizedLine
            )
        }

        // Check if first token is a standalone number
        if tokens.count > 1, let num = Int(tokens.first!) {
            let coreTokens = tokens.dropFirst()
            return LineComponents(
                coreText: coreTokens.joined(separator: " "),
                pageNumber: num,
                fullNormalized: normalizedLine
            )
        }

        // Single token that's a number
        if tokens.count == 1, let num = Int(tokens[0]) {
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
            return SmartCleanupResult(pageNumbers: [], sectionHeaders: [], totalPages: 0)
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

                if let num = extractPageNumber(from: trimmed) {
                    // Standalone page number pattern (e.g., "42", "Page 42")
                    pageNumberDetections.append(PageNumberDetection(
                        pageNumber: entry.pageNumber,
                        detectedNumber: num,
                        lineText: trimmed,
                        normalizedLine: normalized,
                        position: .firstLine
                    ))
                } else {
                    // Check for trailing/leading number in mixed line (e.g., "Chapter 1  42")
                    let decomposed = decomposeHeaderLine(normalized)
                    if let num = decomposed.pageNumber, !decomposed.coreText.isEmpty {
                        pageNumberDetections.append(PageNumberDetection(
                            pageNumber: entry.pageNumber,
                            detectedNumber: num,
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

                if let num = extractPageNumber(from: trimmed) {
                    pageNumberDetections.append(PageNumberDetection(
                        pageNumber: entry.pageNumber,
                        detectedNumber: num,
                        lineText: trimmed,
                        normalizedLine: normalized,
                        position: .lastLine
                    ))
                } else {
                    let decomposed = decomposeHeaderLine(normalized)
                    if let num = decomposed.pageNumber, !decomposed.coreText.isEmpty {
                        pageNumberDetections.append(PageNumberDetection(
                            pageNumber: entry.pageNumber,
                            detectedNumber: num,
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

        return SmartCleanupResult(
            pageNumbers: pageNumberDetections,
            sectionHeaders: sectionHeaders,
            totalPages: sortedEntries.count
        )
    }

    /// Finds near-contiguous runs of 3+ pages sharing the same header text in their first 2-3 lines.
    /// Strips trailing/leading page numbers before comparing, so "Chapter 1  42" and "Chapter 1  43"
    /// both match under "chapter 1". Allows gaps of 1 page for alternating left/right headers.
    private static func detectSectionHeaders(entries: [PageCacheEntry]) -> [SectionHeaderDetection] {
        // Step 1: Extract top non-empty lines, decompose to strip page numbers
        // Key: core text (numbers stripped), Value: [(pageNumber, originalText)]
        var lineOccurrences: [String: [(pageNumber: Int, originalText: String)]] = [:]

        for entry in entries {
            let plainText = String(entry.richText.characters)
            let lines = plainText.components(separatedBy: .newlines)
            let nonEmptyLines = lines
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .prefix(3)

            for line in nonEmptyLines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let normalized = normalize(trimmed)

                // Skip lines that are purely a page number pattern
                if extractPageNumber(from: trimmed) != nil { continue }

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
                    // Strip the number from the original for display
                    let originalDecomposed = decomposeHeaderLine(normalized)
                    displayCore = originalDecomposed.coreText
                } else {
                    displayCore = trimmed
                }

                lineOccurrences[coreText, default: []].append(
                    (pageNumber: entry.pageNumber, originalText: displayCore)
                )
            }
        }

        // Step 2: Find near-contiguous runs of 3+ pages (gap tolerance of 1 for alternating headers)
        var detections: [SectionHeaderDetection] = []

        for (coreText, occurrences) in lineOccurrences {
            let sorted = occurrences.sorted { $0.pageNumber < $1.pageNumber }
            guard sorted.count >= 3 else { continue }

            // Find near-contiguous runs (allow gap of 1 page for left/right alternation)
            var runStart = 0
            for i in 1...sorted.count {
                let isNearContiguous = i < sorted.count &&
                    sorted[i].pageNumber <= sorted[i - 1].pageNumber + 2

                if !isNearContiguous {
                    let runLength = i - runStart
                    if runLength >= 3 {
                        let startPage = sorted[runStart].pageNumber
                        let endPage = sorted[i - 1].pageNumber
                        let displayText = sorted[runStart].originalText
                        let affectedPages = (runStart..<i).map { sorted[$0].pageNumber }

                        detections.append(SectionHeaderDetection(
                            headerText: coreText,
                            displayText: displayText,
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

    // MARK: - Building Options

    /// Builds the cleanup options relevant to a specific page from the analysis result.
    static func buildOptions(
        from result: SmartCleanupResult,
        forPageNumber pageNumber: Int
    ) -> [CleanupOption] {
        var options: [CleanupOption] = []

        // Per-page page number removal
        let pageNumDetections = result.pageNumbers.filter { $0.pageNumber == pageNumber }
        for detection in pageNumDetections {
            options.append(.removePageNumber(detection: detection))
        }

        // Per-page and per-range section header removal
        let relevantHeaders = result.sectionHeaders.filter { $0.pageRange.contains(pageNumber) }
        for header in relevantHeaders {
            options.append(.removeSectionHeaderFromPage(header: header, pageNumber: pageNumber))
            if header.pageRange.count > 1 {
                options.append(.removeSectionHeaderFromRange(header: header))
            }
        }

        // Document-wide options
        if result.pageNumbers.count >= 2 {
            options.append(.removeAllPageNumbers(detections: result.pageNumbers))
        }
        if !result.sectionHeaders.isEmpty {
            options.append(.removeAllSectionHeaders(headers: result.sectionHeaders))
        }

        return options
    }

    // MARK: - Line Removal

    /// Removes the first line whose normalized content matches `normalizedTarget`
    /// from the given AttributedString. Removes the entire line including its newline character.
    /// Preserves all formatting attributes on surrounding text.
    ///
    /// When `stripNumbers` is true, strips trailing/leading page numbers from each line before
    /// comparing to the target. This allows matching "Chapter 1  42" when searching for "chapter 1".
    static func removeLine(
        matching normalizedTarget: String,
        from text: AttributedString,
        stripNumbers: Bool = false
    ) -> AttributedString {
        let plainText = String(text.characters)
        let lines = plainText.components(separatedBy: "\n")

        var charOffset = 0
        for (lineIndex, line) in lines.enumerated() {
            let normalizedLine = normalize(line)
            let compareText: String
            if stripNumbers {
                let decomposed = decomposeHeaderLine(normalizedLine)
                compareText = decomposed.coreText.isEmpty ? normalizedLine : decomposed.coreText
            } else {
                compareText = normalizedLine
            }
            if compareText == normalizedTarget {
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
