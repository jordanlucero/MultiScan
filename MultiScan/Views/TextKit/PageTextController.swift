//
//  PageTextController.swift
//  MultiScan
//
//  The editing controller between a Page model and the TextKit 2 text view.
//
//  One controller exists per selected page (created on page switch, like the old
//  EditablePageText). It owns the authoritative text snapshot, debounces auto-save,
//  routes formatting and Smart Cleanup edits into the text view's storage with undo
//  support on both platforms, and normalizes fonts at the storage boundary.
//
//  ## Ownership & Lifecycle
//  - `init` decodes the page's persisted text once and normalizes it to the display font.
//  - `attach(_:)` loads the snapshot into a platform text view (called by PageTextEditor).
//  - `textDidChange()` (from the view delegate) refreshes the snapshot + statistics and
//    schedules a debounced save.
//  - `detach()` performs a final save and severs the view link, so a debounce that fires
//    after a page switch can never read another page's storage.
//
//  ## Undo
//  Typing undo is native to NSTextView/UITextView (`allowsUndo` on macOS, automatic on
//  iOS — including shake-to-undo and three-finger swipe). Programmatic edits (formatting,
//  Remove Line Breaks, Smart Cleanup) register snapshot-based undo actions on the view's
//  UndoManager, so they participate in the same stack on both platforms.
//

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
@Observable
final class PageTextController {

    // MARK: - State

    @ObservationIgnored let page: Page
    @ObservationIgnored private(set) weak var textView: PageTextView?

    /// Authoritative snapshot of the editor content (display-font normalized).
    /// Updated on every text change so saves never depend on view liveness.
    @ObservationIgnored private var currentText: NSAttributedString

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private(set) var hasUnsavedChanges = false

    /// Live statistics for the Statistics pane.
    private(set) var wordCount: Int
    private(set) var charCount: Int

    private static let saveDebounceInterval: Duration = .seconds(1)

    // MARK: - Init

    init(page: Page) {
        self.page = page
        let display = RichTextArchiver.normalizedForDisplay(page.attributedText)
        self.currentText = display
        self.wordCount = TextStatistics.wordCount(of: display.string)
        self.charCount = display.string.count
    }

    // MARK: - View Attachment

    /// Loads the controller's content into a platform text view. Idempotent for the
    /// same view; reloads when a new view instance appears (e.g., sheet reopened).
    func attach(_ textView: PageTextView) {
        if self.textView === textView { return }
        self.textView = textView
        textView.contentStorage.setAttributedString(currentText)
        textView.undoManager?.removeAllActions()
        textView.selectedRange = NSRange(location: 0, length: 0)
        #if os(macOS)
        textView.scrollToBeginningOfDocument(nil)
        #else
        textView.contentOffset = .zero
        textView.contentSizeCategoryDidChange = { [weak self] in
            self?.dynamicTypeDidChange()
        }
        #endif
    }

    #if os(iOS)
    /// Re-normalizes the live content to the current Dynamic Type body size.
    /// Display-only: `normalizedForStorage` strips sizes on save, so this never
    /// dirties the document or triggers a save.
    private func dynamicTypeDidChange() {
        currentText = RichTextArchiver.normalizedForDisplay(currentText)
        guard let textView else { return }
        let selection = textView.selectedRange
        textView.contentStorage.setAttributedString(currentText)
        let location = min(selection.location, currentText.length)
        let length = min(selection.length, currentText.length - location)
        textView.selectedRange = NSRange(location: location, length: length)
        textView.typingAttributes = [
            .font: PageTextStyle.displayFont,
            .foregroundColor: UIColor.label
        ]
    }
    #endif

    /// Saves pending edits and severs the view link. Call before switching pages.
    func detach() {
        saveNow()
        textView = nil
    }

    // MARK: - Text Change Handling

    /// Called by the view delegate on every user edit.
    func textDidChange() {
        guard let textView else { return }
        currentText = NSAttributedString(attributedString: textView.contentStorage)
        markEdited()
    }

    private func markEdited() {
        hasUnsavedChanges = true
        let plain = currentText.string
        wordCount = TextStatistics.wordCount(of: plain)
        charCount = plain.count
        scheduleDebouncedSave()
    }

    // MARK: - Saving

    private func scheduleDebouncedSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.saveDebounceInterval)
                self?.saveNow()
            } catch {
                // Task was cancelled, no action needed
            }
        }
    }

    /// Persists changes to the page and export cache immediately (no-op when clean).
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil

        guard hasUnsavedChanges else { return }
        hasUnsavedChanges = false

        // Normalize to the canonical storage font (also strips display-only colors)
        let storageText = RichTextArchiver.normalizedForStorage(currentText)
        page.attributedText = storageText

        if let document = page.document {
            TextExportCacheService.updateEntry(
                pageNumber: page.pageNumber,
                attributedText: storageText,
                in: document
            )
        }
    }

    // MARK: - Content Access

    /// Plain text of the live editor content (for cleanup range computation).
    var plainText: String {
        currentText.string
    }

    /// Live content normalized for export (copy button, share).
    var attributedTextForExport: NSAttributedString {
        RichTextArchiver.normalizedForStorage(currentText)
    }

    // MARK: - Programmatic Editing Core

    /// Applies a mutation to the content with snapshot-based undo registration.
    /// The mutation receives a working copy; if it makes no change, nothing happens.
    func performEdit(actionName: String, _ mutate: (NSMutableAttributedString) -> Void) {
        let before = currentText
        let selectionBefore = textView?.selectedRange

        let working = NSMutableAttributedString(attributedString: before)
        mutate(working)
        guard !working.isEqual(to: before) else { return }

        apply(NSAttributedString(attributedString: working), selection: selectionBefore)
        registerUndo(previous: before, previousSelection: selectionBefore, actionName: actionName)
        markEdited()
    }

    /// Replaces view + snapshot content, restoring a clamped selection.
    private func apply(_ text: NSAttributedString, selection: NSRange?) {
        currentText = text
        guard let textView else { return }
        textView.contentStorage.setAttributedString(text)
        if let selection {
            let location = min(selection.location, text.length)
            let length = min(selection.length, text.length - location)
            textView.selectedRange = NSRange(location: location, length: length)
        }
    }

    private func registerUndo(previous: NSAttributedString, previousSelection: NSRange?, actionName: String) {
        guard let undoManager = textView?.undoManager else { return }
        #if os(macOS)
        textView?.breakUndoCoalescing()
        #endif
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                let redoText = target.currentText
                let redoSelection = target.textView?.selectedRange
                target.apply(previous, selection: previousSelection)
                target.registerUndo(previous: redoText, previousSelection: redoSelection, actionName: actionName)
                target.markEdited()
            }
        }
        undoManager.setActionName(actionName)
    }

    // MARK: - Formatting

    func toggleBold() {
        toggleFontTrait(actionName: String(localized: "Bold"), isBoldToggle: true)
    }

    func toggleItalic() {
        toggleFontTrait(actionName: String(localized: "Italic"), isBoldToggle: false)
    }

    func toggleUnderline() {
        toggleStyleAttribute(.underlineStyle, actionName: String(localized: "Underline"))
    }

    func toggleStrikethrough() {
        toggleStyleAttribute(.strikethroughStyle, actionName: String(localized: "Strikethrough"))
    }

    private func toggleFontTrait(actionName: String, isBoldToggle: Bool) {
        guard let textView else { return }
        let range = textView.selectedRange

        if range.length == 0 {
            // Caret only: flip the typing attributes so upcoming input is styled.
            var attributes = textView.typingAttributes
            let font = (attributes[.font] as? PlatformFont) ?? PageTextStyle.displayFont
            attributes[.font] = font.applyingTraits(
                bold: isBoldToggle ? !font.isBold : font.isBold,
                italic: isBoldToggle ? font.isItalic : !font.isItalic
            )
            textView.typingAttributes = attributes
            return
        }

        // Uniform target state decided by the first character in the selection.
        let firstFont = currentText.attribute(.font, at: range.location, effectiveRange: nil) as? PlatformFont
        let targetState = !(isBoldToggle ? (firstFont?.isBold ?? false) : (firstFont?.isItalic ?? false))

        performEdit(actionName: actionName) { text in
            text.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let font = (value as? PlatformFont) ?? PageTextStyle.displayFont
                let newFont = font.applyingTraits(
                    bold: isBoldToggle ? targetState : font.isBold,
                    italic: isBoldToggle ? font.isItalic : targetState
                )
                text.addAttribute(.font, value: newFont, range: subrange)
            }
        }
    }

    private func toggleStyleAttribute(_ key: NSAttributedString.Key, actionName: String) {
        guard let textView else { return }
        let range = textView.selectedRange

        if range.length == 0 {
            var attributes = textView.typingAttributes
            if attributes[key] != nil {
                attributes.removeValue(forKey: key)
            } else {
                attributes[key] = NSUnderlineStyle.single.rawValue
            }
            textView.typingAttributes = attributes
            return
        }

        let currentlyOn = currentText.attribute(key, at: range.location, effectiveRange: nil) != nil

        performEdit(actionName: actionName) { text in
            if currentlyOn {
                text.removeAttribute(key, range: range)
            } else {
                text.addAttribute(key, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
    }

    // MARK: - Text Manipulation (Remove Line Breaks, Smart Cleanup)

    func removeLineBreaks() {
        performEdit(actionName: String(localized: "Remove Line Breaks")) { text in
            TextManipulationService.replaceLineBreaks(in: text)
        }
        saveNow()
    }

    /// Removes page-number tokens from the live content (Smart Cleanup).
    func removePageNumberTokens(_ numberTexts: [String], actionName: String) {
        performEdit(actionName: actionName) { text in
            for numberText in numberTexts {
                TextManipulationService.removePageNumberToken(numberText, in: text)
            }
        }
        saveNow()
    }

    /// Removes a matching line from the live content (Smart Cleanup section headers).
    func removeLine(matching normalizedTarget: String, stripNumbers: Bool, actionName: String) {
        performEdit(actionName: actionName) { text in
            TextManipulationService.removeLine(matching: normalizedTarget, in: text, stripNumbers: stripNumbers)
        }
        saveNow()
    }

    // MARK: - Find

    /// Presents the platform find UI (find bar on macOS, find navigator on iOS).
    func presentFindNavigator() {
        guard let textView else { return }
        #if os(macOS)
        textView.window?.makeFirstResponder(textView)
        let sender = NSMenuItem()
        sender.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(sender)
        #else
        textView.findInteraction?.presentFindNavigator(showingReplace: false)
        #endif
    }
}

// MARK: - Text Statistics

/// Single source of truth for word/character counting across editor, cache, and export.
enum TextStatistics {
    static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
