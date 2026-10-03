//
//  RichTextArchiverTests.swift
//  MultiScanTests
//

import Foundation
import SwiftUI
import Testing
@testable import MultiScan

@Suite("Rich text persistence")
struct RichTextArchiverTests {
    @Test func rtfRoundTripKeepsTextAndTraits() throws {
        let bold = PageTextStyle.storageFont.applyingTraits(bold: true, italic: false)
        let original = NSAttributedString(string: "Hello", attributes: [.font: bold])

        let data = try #require(RichTextArchiver.rtfData(from: original))
        #expect(RichTextArchiver.isRTF(data))

        let decoded = RichTextArchiver.attributedString(from: data)
        #expect(decoded.string == "Hello")
        let font = decoded.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont
        #expect(font?.isBold == true)
        #expect(RichTextArchiver.plainText(from: data) == "Hello")
    }

    @Test func legacyJSONIsDecodedAndMappedToPlatformTraits() throws {
        var legacy = AttributedString("Bold")
        legacy.inlinePresentationIntent = .stronglyEmphasized
        let data = try JSONEncoder().encode(legacy)

        #expect(!RichTextArchiver.isRTF(data))
        let decoded = RichTextArchiver.attributedString(from: data)
        #expect(decoded.string == "Bold")
        let font = decoded.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont
        #expect(font?.isBold == true)
    }

    @Test func undecodableDataBecomesEmptyText() {
        #expect(RichTextArchiver.attributedString(from: nil).length == 0)
        #expect(RichTextArchiver.attributedString(from: Data()).length == 0)
        #expect(RichTextArchiver.attributedString(from: Data("garbage".utf8)).length == 0)
        #expect(RichTextArchiver.plainText(from: nil) == "")
    }

    @Test func storageNormalizationStripsColorsAndUsesStorageFont() throws {
        let displayBold = PageTextStyle.displayFont.applyingTraits(bold: true, italic: false)
        let text = NSAttributedString(string: "Hi", attributes: [
            .font: displayBold,
            .foregroundColor: PlatformColor.red,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ])

        let stored = RichTextArchiver.normalizedForStorage(text)
        #expect(stored.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil)
        let font = try #require(stored.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont)
        #expect(font.isBold)
        #expect(font.fontName.hasPrefix("HelveticaNeue"))
        #expect(font.pointSize == PageTextStyle.storageFontSize)
        // Other attributes pass through untouched
        #expect(stored.attribute(.underlineStyle, at: 0, effectiveRange: nil) != nil)
    }

    @Test func displayNormalizationStampsLabelColor() {
        let text = NSAttributedString(string: "Hi", attributes: [.font: PageTextStyle.storageFont])
        let display = RichTextArchiver.normalizedForDisplay(text)
        #expect(display.attribute(.foregroundColor, at: 0, effectiveRange: nil) != nil)
        let font = display.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont
        #expect(font?.isBold == false)
    }

    @Test func fontTraitsToggleBothWays() {
        let base = PageTextStyle.storageFont
        let boldItalic = base.applyingTraits(bold: true, italic: true)
        #expect(boldItalic.isBold && boldItalic.isItalic)
        let plain = boldItalic.applyingTraits(bold: false, italic: false)
        #expect(!plain.isBold && !plain.isItalic)
    }

    @Test func richTextWrapperExportsRTFAndPlainText() throws {
        let richText = RichText(NSAttributedString(string: "Share me", attributes: [.font: PageTextStyle.storageFont]))
        #expect(richText.plainText == "Share me")
        let data = try richText.rtfDataOrThrow()
        #expect(RichTextArchiver.isRTF(data))

        let empty = RichText(rtfData: nil, plainText: "")
        #expect(throws: RichTextExportError.self) { try empty.rtfDataOrThrow() }
    }
}
