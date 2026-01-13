// TextManipulationService may be useful for exaptation from MultiScan.
// Based on the version from MultiScan v1.x releases

import Foundation

/// Service for programmatic text transformations on AttributedString
/// All operations preserve formatting attributes (bold, italic, etc.)
enum TextManipulationService {

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
}
