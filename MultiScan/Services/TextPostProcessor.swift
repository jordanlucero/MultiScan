import Foundation
import CoreGraphics

struct TextPostProcessor {
    /// Process OCR text using bounding box analysis to intelligently merge lines into paragraphs
    /// - Parameters:
    ///   - rawText: The original line-by-line OCR text (newline separated)
    ///   - boundingBoxes: Array of CGRect for each line (from VisionKit, origin is bottom-left)
    /// - Returns: Text with smart paragraph formatting
    static func applySmartParagraphs(rawText: String, boundingBoxes: [CGRect]) -> String {
        let lines = rawText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Need at least 2 lines to detect paragraphs
        guard lines.count > 1, boundingBoxes.count == lines.count else {
            return rawText
        }

        // Calculate vertical gaps between consecutive lines
        var gaps: [CGFloat] = []
        for i in 0..<(boundingBoxes.count - 1) {
            let currentBox = boundingBoxes[i]
            let nextBox = boundingBoxes[i + 1]

            // VisionKit uses bottom-left origin, so higher Y means further up the page
            // Gap = (bottom of current line) - (top of next line)
            let gap = currentBox.minY - nextBox.maxY
            gaps.append(gap)
        }

        // Calculate threshold for paragraph breaks
        // Use median gap * multiplier to be robust against outliers
        let threshold = calculateThreshold(gaps: gaps)

        print("📊 Smart Paragraph Analysis:")
        print("  Lines: \(lines.count)")
        print("  Gaps: \(gaps.map { String(format: "%.3f", $0) })")
        print("  Threshold: \(String(format: "%.3f", threshold))")

        // Build the formatted text
        var result = ""

        for i in 0..<lines.count {
            let line = lines[i]

            // Add the current line
            result += line

            // Determine what to add after this line
            if i < lines.count - 1 {
                let gap = gaps[i]
                let nextLine = lines[i + 1]

                let shouldBreakParagraph = shouldInsertParagraphBreak(
                    currentLine: line,
                    nextLine: nextLine,
                    gap: gap,
                    threshold: threshold
                )

                if shouldBreakParagraph {
                    result += "\n\n" // Paragraph break
                    print("  [\(i)] PARAGRAPH BREAK - gap: \(String(format: "%.3f", gap))")
                } else {
                    result += " " // Continue paragraph
                    print("  [\(i)] MERGE - gap: \(String(format: "%.3f", gap))")
                }
            }
        }

        return result
    }

    /// Calculate the threshold for determining paragraph breaks
    private static func calculateThreshold(gaps: [CGFloat]) -> CGFloat {
        guard !gaps.isEmpty else { return 0.01 }

        // Use median for robustness
        let sorted = gaps.sorted()
        let median = sorted[sorted.count / 2]

        // Paragraph break = gap significantly larger than typical line spacing
        // Multiplier of 1.5 works well empirically
        return median * 1.5
    }

    /// Determine if a paragraph break should be inserted between two lines
    private static func shouldInsertParagraphBreak(
        currentLine: String,
        nextLine: String,
        gap: CGFloat,
        threshold: CGFloat
    ) -> Bool {
        let trimmedCurrent = currentLine.trimmingCharacters(in: .whitespaces)
        let trimmedNext = nextLine.trimmingCharacters(in: .whitespaces)

        // Empty lines always break paragraphs
        if trimmedCurrent.isEmpty || trimmedNext.isEmpty {
            return true
        }

        // Large vertical gap = likely paragraph break
        if gap > threshold {
            return true
        }

        // Small gap - use heuristics to decide if it's a continuation

        // Check if current line ends with sentence-ending punctuation
        let sentenceEnders: Set<Character> = [".", "!", "?", ":", ";"]
        let endsWithPunctuation = trimmedCurrent.last.map { sentenceEnders.contains($0) } ?? false

        // Check if next line starts with capital letter
        let startsWithCapital = trimmedNext.first?.isUppercase ?? false

        // Check if current line ends mid-word (hyphenation)
        let endsWithHyphen = trimmedCurrent.last == "-"

        // Heuristics for continuation vs break:

        // Definitely continue if hyphenated
        if endsWithHyphen {
            return false
        }

        // If ends with punctuation AND next starts with capital AND gap is close to threshold,
        // it's likely a new sentence/paragraph
        if endsWithPunctuation && startsWithCapital && gap > threshold * 0.75 {
            return true
        }

        // If next line starts with lowercase, it's likely a continuation
        if !startsWithCapital {
            return false
        }

        // If current line is very short (<40 chars) and doesn't end with punctuation,
        // might be a heading or list item
        if trimmedCurrent.count < 40 && !endsWithPunctuation {
            return true
        }

        // Default: small gap = continuation
        return false
    }

    /// Get a preview of paragraph detection decisions for debugging
    static func debugParagraphDetection(rawText: String, boundingBoxes: [CGRect]) -> String {
        let lines = rawText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard lines.count > 1, boundingBoxes.count == lines.count else {
            return "Not enough data for analysis"
        }

        var gaps: [CGFloat] = []
        for i in 0..<(boundingBoxes.count - 1) {
            let currentBox = boundingBoxes[i]
            let nextBox = boundingBoxes[i + 1]
            let gap = currentBox.minY - nextBox.maxY
            gaps.append(gap)
        }

        let threshold = calculateThreshold(gaps: gaps)

        var debug = "SMART PARAGRAPH DEBUG\n"
        debug += "=====================\n\n"
        debug += "Total lines: \(lines.count)\n"
        debug += "Threshold: \(String(format: "%.4f", threshold))\n\n"

        for i in 0..<lines.count {
            debug += "[\(i)] \"\(lines[i].prefix(50))...\"\n"

            if i < gaps.count {
                let gap = gaps[i]
                let decision = shouldInsertParagraphBreak(
                    currentLine: lines[i],
                    nextLine: lines[i + 1],
                    gap: gap,
                    threshold: threshold
                )

                debug += "    Gap: \(String(format: "%.4f", gap)) → "
                debug += decision ? "PARAGRAPH BREAK\n" : "MERGE\n"
            }
            debug += "\n"
        }

        return debug
    }
}
