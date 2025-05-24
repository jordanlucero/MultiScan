import Foundation
import AppKit

struct TextFormatter {
    /// Parses text with **bold** and *italic* markers and returns an NSAttributedString
    static func parseFormattedText(_ text: String) -> NSAttributedString {
        let attributedString = NSMutableAttributedString()
        let defaultFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        
        // Regular expressions for matching formatting
        let boldPattern = #"\*\*(.+?)\*\*"#
        let italicPattern = #"\*(.+?)\*"#
        
        // First, handle bold text
        var workingText = text
        var boldRanges: [(String, NSRange)] = []
        
        if let boldRegex = try? NSRegularExpression(pattern: boldPattern, options: []) {
            let matches = boldRegex.matches(in: workingText, options: [], range: NSRange(workingText.startIndex..., in: workingText))
            
            // Process matches in reverse order to maintain string indices
            for match in matches.reversed() {
                if let range = Range(match.range, in: workingText),
                   let contentRange = Range(match.range(at: 1), in: workingText) {
                    let content = String(workingText[contentRange])
                    let nsRange = NSRange(range, in: workingText)
                    boldRanges.insert((content, nsRange), at: 0)
                    workingText.replaceSubrange(range, with: content)
                }
            }
        }
        
        // Then handle italic text
        var italicRanges: [(String, NSRange)] = []
        
        if let italicRegex = try? NSRegularExpression(pattern: italicPattern, options: []) {
            let matches = italicRegex.matches(in: workingText, options: [], range: NSRange(workingText.startIndex..., in: workingText))
            
            // Process matches in reverse order to maintain string indices
            for match in matches.reversed() {
                if let range = Range(match.range, in: workingText),
                   let contentRange = Range(match.range(at: 1), in: workingText) {
                    let content = String(workingText[contentRange])
                    let nsRange = NSRange(range, in: workingText)
                    
                    // Check if this overlaps with any bold range
                    var isInsideBold = false
                    for (_, boldRange) in boldRanges {
                        if nsRange.location >= boldRange.location && 
                           nsRange.location + nsRange.length <= boldRange.location + boldRange.length {
                            isInsideBold = true
                            break
                        }
                    }
                    
                    if !isInsideBold {
                        italicRanges.insert((content, nsRange), at: 0)
                        workingText.replaceSubrange(range, with: content)
                    }
                }
            }
        }
        
        // Create the attributed string with the cleaned text
        attributedString.append(NSAttributedString(string: workingText, attributes: [
            .font: defaultFont
        ]))
        
        // Apply bold formatting
        let fontManager = NSFontManager.shared
        for (_, range) in boldRanges {
            let adjustedRange = calculateAdjustedRange(range, removedCharacters: boldRanges + italicRanges, in: text)
            attributedString.enumerateAttribute(.font, in: adjustedRange, options: []) { value, subrange, stop in
                if let font = value as? NSFont {
                    let boldFont = fontManager.convert(font, toHaveTrait: .boldFontMask)
                    attributedString.addAttribute(.font, value: boldFont, range: subrange)
                }
            }
        }
        
        // Apply italic formatting
        for (_, range) in italicRanges {
            let adjustedRange = calculateAdjustedRange(range, removedCharacters: boldRanges + italicRanges, in: text)
            attributedString.enumerateAttribute(.font, in: adjustedRange, options: []) { value, subrange, stop in
                if let font = value as? NSFont {
                    let italicFont = fontManager.convert(font, toHaveTrait: .italicFontMask)
                    attributedString.addAttribute(.font, value: italicFont, range: subrange)
                }
            }
        }
        
        return attributedString
    }
    
    /// Calculate adjusted range after removing formatting markers
    private static func calculateAdjustedRange(_ originalRange: NSRange, removedCharacters: [(String, NSRange)], in originalText: String) -> NSRange {
        var offset = 0
        var adjustedLocation = originalRange.location
        
        for (content, range) in removedCharacters {
            if range.location < originalRange.location {
                // Calculate how many characters were removed (markers)
                let markersLength = range.length - content.count
                adjustedLocation -= markersLength
            }
        }
        
        // The length should be the content length without markers
        let content = (originalText as NSString).substring(with: originalRange)
        let cleanedContent = content
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "*", with: "")
        
        return NSRange(location: max(0, adjustedLocation), length: cleanedContent.count)
    }
    
    /// Copies formatted text to clipboard
    static func copyFormattedText(_ text: String) {
        let attributedString = parseFormattedText(text)
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        
        // Set both plain text and RTF versions
        pasteboard.setString(attributedString.string, forType: .string)
        
        if let rtfData = try? attributedString.data(from: NSRange(location: 0, length: attributedString.length), 
                                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            pasteboard.setData(rtfData, forType: .rtf)
        }
    }
}