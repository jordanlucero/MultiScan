//
//  PageTextController.swift
//  MultiScan
//
//  The editing controller between a Page model and the TextKit 2 text view.
//
//  One controller exists per selected page (created on page switch, like the old EditablePageText). It owns the authoritative text snapshot, debounces auto-save, routes formatting and Smart Cleanup edits into the text view's storage with undo support on both platforms, normalizes fonts at the storage boundary, and manages the page's inline artwork captures.
//
//  ## Ownership & Lifecycle
//  - `init` decodes the page's persisted text once (RTF or RTFD), normalizes it to the display font, and registers the page's captures with `CaptureImageStore` so their attachment views can draw.
//  - `attach(_:)` loads the snapshot into a platform text view (called by PageTextEditor).
//  - `textDidChange()` (from the view delegate) refreshes statistics and schedules a debounced save. While a view is attached, **the view's storage is the authoritative text** (`currentText` reads it); the stored snapshot is only refreshed when the view detaches, so a keystroke no longer copies the whole page.
//  - `detach()` performs a final save and severs the view link, so a debounce that fires after a page switch can never read another page's storage.
//
//  ## Undo
//  Typing undo is native to NSTextView/UITextView. On macOS the text view uses this controller's `editorUndoManager` (handed over by `PageTextEditor`'s delegate), so clearing it on page load leaves the window's page-reorder history intact. Programmatic edits (formatting, Remove Line Breaks, Smart Cleanup, inserting/removing captures) register snapshot-based undo actions on the same manager, so they participate in the same stack on both platforms.
//
//  ## Tables (macOS)
//  On the Mac, table reference attachments are expanded into `NSTextTable` paragraphs when the page loads (`TextTableRendering.expandingTableAttachments`) and collapsed back on save, so the stored page is the same cross-platform attachment form. iOS shows the attachment view read-only.
//
//  ## Captures
//  `insertCapture(_:)` places a reference attachment on its own paragraph at the caret; `removeCapture(_:)` deletes the attachment *and* the model; `toggleDraft(forCapture:)` flips the flag and refreshes the attachment view. The controller is the `CaptureImageStore.actionHandler` while attached, so the attachment views' menus reach it.
//

import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@Observable
final class PageTextController {

    // MARK: - State

    @ObservationIgnored let page: Page
    @ObservationIgnored private(set) weak var textView: PageTextView?

    /// Snapshot of the editor content (display-font normalized) used while **no view is attached**: programmatic edits from the compact "More" menu, Smart Cleanup on iPhone, and the final save after detach all read and write it. While a view is attached, `currentText` reads the view's storage instead.
    @ObservationIgnored private var snapshot: NSAttributedString

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private(set) var hasUnsavedChanges = false

    /// macOS: the editor's own undo manager (see the file comment). Unused on iOS, where the text view provides one.
    @ObservationIgnored let editorUndoManager = UndoManager()

    /// Host callback: the user asked to recapture (re-crop) an existing illustration. `ReviewView` opens the capture overlay seeded with the capture's rectangle.
    @ObservationIgnored var onRecaptureRequested: ((PageCapture) -> Void)?

    /// Live statistics for the Statistics pane.
    private(set) var wordCount: Int
    private(set) var charCount: Int

    private static let saveDebounceInterval: Duration = .seconds(1)

    // MARK: - Init

    init(page: Page) {
        self.page = page
        var display = RichTextArchiver.normalizedForDisplay(page.attributedText)
        #if os(macOS)
        // Tables become native NSTextTable paragraphs in the Mac editor (collapsed back to attachments on save).
        display = TextTableRendering.expandingTableAttachments(in: display, font: PageTextStyle.displayFont)
        #endif
        self.snapshot = display
        self.wordCount = TextStatistics.wordCount(of: display.string)
        self.charCount = TextStatistics.characterCount(of: display.string)
        // Attachment views look their pixels up here; register before any view can ask.
        CaptureImageStore.shared.register(page.unwrappedCaptures)
    }

    // MARK: - Authoritative text

    /// The current editor content: the live storage while a view is attached, the snapshot otherwise.
    private var currentText: NSAttributedString {
        if let textView { return NSAttributedString(attributedString: textView.contentStorage) }
        return snapshot
    }

    private var currentPlainString: String {
        textView?.contentStorage.string ?? snapshot.string
    }

    // MARK: - View Attachment

    /// Loads the controller's content into a platform text view. Idempotent for the same view; reloads when a new view instance appears (e.g., sheet reopened).
    func attach(_ textView: PageTextView) {
        if self.textView === textView { return }
        // A previous view's content is the latest text; keep it before switching views.
        if let previous = self.textView { snapshot = NSAttributedString(attributedString: previous.contentStorage) }
        self.textView = textView
        textView.contentStorage.setAttributedString(snapshot)
        // Fresh page, fresh history — but only *this editor's* history (macOS) or the view's own (iOS).
        #if os(macOS)
        editorUndoManager.removeAllActions()
        #else
        textView.undoManager?.removeAllActions()
        #endif
        textView.selectedRange = NSRange(location: 0, length: 0)
        #if os(macOS)
        textView.scrollToBeginningOfDocument(nil)
        #else
        textView.contentOffset = .zero
        textView.contentSizeCategoryDidChange = { [weak self] in
            self?.dynamicTypeDidChange()
        }
        #endif
        CaptureImageStore.shared.actionHandler = self
    }

    #if os(iOS)
    /// Re-normalizes the live content to the current Dynamic Type body size.
    /// Display-only: `normalizedForStorage` strips sizes on save, so this never dirties the document or triggers a save.
    private func dynamicTypeDidChange() {
        let renormalized = RichTextArchiver.normalizedForDisplay(RichTextArchiver.normalizedForStorage(currentText))
        snapshot = renormalized
        guard let textView else { return }
        let selection = textView.selectedRange
        textView.contentStorage.setAttributedString(renormalized)
        let location = min(selection.location, renormalized.length)
        let length = min(selection.length, renormalized.length - location)
        textView.selectedRange = NSRange(location: location, length: length)
        textView.typingAttributes = [
            .font: PageTextStyle.displayFont,
            .foregroundColor: UIColor.label
        ]
    }
    #endif

    /// Saves pending edits and severs the view link. Call before switching pages.
    func detach() {
        if let textView { snapshot = NSAttributedString(attributedString: textView.contentStorage) }
        saveNow()
        if CaptureImageStore.shared.actionHandler === self { CaptureImageStore.shared.actionHandler = nil }
        textView = nil
    }

    // MARK: - Text Change Handling

    /// Called by the view delegate on every user edit.
    func textDidChange() {
        guard textView != nil else { return }
        markEdited()
    }

    private func markEdited() {
        hasUnsavedChanges = true
        let plain = currentPlainString
        wordCount = TextStatistics.wordCount(of: plain)
        charCount = TextStatistics.characterCount(of: plain)
        scheduleDebouncedSave()
    }

    // MARK: - Saving

    private func scheduleDebouncedSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
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

        // Normalize to the canonical storage font (also strips display-only colors). Attachments pass through; the setter picks RTFD when they're present.
        var storageText = RichTextArchiver.normalizedForStorage(currentText)
        #if os(macOS)
        // Native tables go back to the portable attachment form so iOS reads the same page.
        storageText = TextTableRendering.collapsingTables(in: storageText)
        #endif
        page.attributedText = storageText

        if let document = page.document {
            // Read lastModified after the assignment above — the setter just bumped it, and that value is the cache entry's freshness fingerprint.
            TextExportCacheService.updateEntry(
                pageNumber: page.pageNumber,
                attributedText: storageText,
                pageLastModified: page.lastModified,
                in: document
            )
        }
    }

    // MARK: - Content Access

    /// Plain text of the live editor content (for cleanup range computation). Includes attachment placeholders so ranges line up with the attributed string.
    var plainText: String {
        currentPlainString
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
        snapshot = text
        guard let textView else { return }
        textView.contentStorage.setAttributedString(text)
        if let selection {
            let location = min(selection.location, text.length)
            let length = min(selection.length, text.length - location)
            textView.selectedRange = NSRange(location: location, length: length)
        }
    }

    private var activeUndoManager: UndoManager? {
        #if os(macOS)
        textView == nil ? nil : editorUndoManager
        #else
        textView?.undoManager
        #endif
    }

    private func registerUndo(previous: NSAttributedString, previousSelection: NSRange?, actionName: String) {
        guard let undoManager = activeUndoManager else { return }
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
        let text = currentText
        let firstFont = text.attribute(.font, at: range.location, effectiveRange: nil) as? PlatformFont
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

    // MARK: - Inline captures

    /// Inserts a reference attachment for `capture` on its own paragraph at the caret (or at the end when no view is attached), undoably, and saves.
    /// The capture must already be inserted in the model context and attached to `page`.
    func insertCapture(_ capture: PageCapture) {
        guard let id = capture.uuid else { return }
        CaptureImageStore.shared.register(capture)

        let insertion = textView?.selectedRange.location ?? currentText.length
        let font = PageTextStyle.displayFont
        let attachment = InlineAttachments.makeCaptureAttachment(captureID: id)
        let attachmentString = InlineAttachments.attributedString(for: attachment, font: font)

        performEdit(actionName: String(localized: "Insert Illustration")) { text in
            let location = min(insertion, text.length)
            // Put the image on its own line: newline before unless at a paragraph start, newline after unless one follows.
            let plain = text.string as NSString
            var prefix = ""
            var suffix = ""
            if location > 0, plain.character(at: location - 1) != 0x0A { prefix = "\n" }
            if location < plain.length, plain.character(at: location) != 0x0A { suffix = "\n" }
            let piece = NSMutableAttributedString()
            if !prefix.isEmpty { piece.append(NSAttributedString(string: prefix, attributes: [.font: font])) }
            piece.append(attachmentString)
            if !suffix.isEmpty { piece.append(NSAttributedString(string: suffix, attributes: [.font: font])) }
            text.insert(piece, at: location)
        }

        // Caret after the inserted paragraph.
        if let textView {
            let newLocation = min(insertion + 2, textView.contentStorage.length)
            textView.selectedRange = NSRange(location: newLocation, length: 0)
        }
        saveNow()
    }

    /// Replaces the pixels of an existing capture (recapture). The attachment stays in place; only the store entry is refreshed.
    func captureDidChange(_ capture: PageCapture) {
        CaptureImageStore.shared.register(capture)
    }

    private func capture(withID id: UUID) -> PageCapture? {
        page.unwrappedCaptures.first { $0.uuid == id }
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

// MARK: - Capture attachment actions

extension PageTextController: CaptureAttachmentActionHandling {
    func toggleDraft(forCapture id: UUID) {
        guard let capture = capture(withID: id) else { return }
        capture.isDraft.toggle()
        capture.lastModified = Date()
        page.document?.lastModified = Date()
        CaptureImageStore.shared.update(id, isDraft: capture.isDraft)
        try? page.modelContext?.save()
    }

    func recapture(_ id: UUID) {
        guard let capture = capture(withID: id) else { return }
        onRecaptureRequested?(capture)
    }

    /// Removes the attachment from the text (undoable as a text edit) and deletes the capture model. The model deletion is not undoable — the pixels are gone once the context saves — so the confirmation lives in the attachment menu wording.
    func removeCapture(_ id: UUID) {
        performEdit(actionName: String(localized: "Remove Illustration")) { text in
            guard let range = InlineAttachments.range(ofCapture: id, in: text) else { return }
            // Also eat one adjoining newline so the paragraph the image lived on collapses.
            var removal = range
            let plain = text.string as NSString
            if removal.upperBound < plain.length, plain.character(at: removal.upperBound) == 0x0A {
                removal.length += 1
            } else if removal.location > 0, plain.character(at: removal.location - 1) == 0x0A {
                removal.location -= 1
                removal.length += 1
            }
            text.deleteCharacters(in: removal)
        }
        if let capture = capture(withID: id) {
            page.captures?.removeAll { $0.uuid == id }
            page.modelContext?.delete(capture)
            page.document?.recalculateStorageSize()
        }
        CaptureImageStore.shared.remove(id)
        saveNow()
        try? page.modelContext?.save()
    }
}
