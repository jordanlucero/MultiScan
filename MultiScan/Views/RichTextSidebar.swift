import SwiftUI
import UniformTypeIdentifiers

/// View model for managing editable rich text with debounced auto-save
@MainActor
@Observable
final class EditablePageText: Identifiable {
    @ObservationIgnored private let page: Page

    /// Debounce interval for auto-save
    private static let saveDebounceInterval: UInt64 = 1_000_000_000 // 1 second in nanoseconds

    /// Current debounce task - weak self in Task handles cleanup on dealloc
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Tracks whether there are unsaved changes
    @ObservationIgnored private var hasUnsavedChanges = false

    /// The text being edited
    var text: AttributedString {
        didSet {
            hasUnsavedChanges = true
            scheduleDebouncedSave()
        }
    }

    /// Selection tracking for formatting operations
    var selection: AttributedTextSelection

    init(page: Page) {
        self.page = page
        // Apply primary color for proper dark/light mode display in editor
        var displayText = page.richText
        displayText.foregroundColor = Color.primary
        self.text = displayText
        self.selection = AttributedTextSelection()
    }

    /// Schedule a debounced save - cancels any pending save and schedules a new one
    private func scheduleDebouncedSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.saveDebounceInterval)
                self?.saveNow()
            } catch {
                // Task was cancelled, no action needed
            }
        }
    }

    /// Save changes back to the page immediately (only if there are unsaved changes)
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil

        guard hasUnsavedChanges else { return }
        hasUnsavedChanges = false

        // Strip any foreground color before saving (we apply it dynamically for display)
        var cleanText = text
        for run in cleanText.runs {
            let range = run.range
            cleanText[range].foregroundColor = nil
        }
        page.richText = cleanText

        // Update the export cache with the new text (using cleanText to avoid re-accessing page.richText)
        // This keeps the cache in sync for efficient export later
        if let document = page.document {
            TextExportCacheService.updateEntry(
                pageNumber: page.pageNumber,
                richText: cleanText,
                in: document
            )
        }
    }

    /// Apply bold formatting to the current selection
    func applyBold() {
        text.transformAttributes(in: &selection) { container in
            let currentFont = container.font
            let resolved = currentFont?.resolve(in: EnvironmentValues().fontResolutionContext)
            let isBold = resolved?.isBold ?? false
            let isItalic = resolved?.isItalic ?? false

            if isBold {
                container.font = isItalic ? .body.italic() : nil
            } else {
                container.font = isItalic ? .body.bold().italic() : .body.bold()
            }
        }
    }

    /// Apply italic formatting to the current selection
    func applyItalic() {
        text.transformAttributes(in: &selection) { container in
            let currentFont = container.font
            let resolved = currentFont?.resolve(in: EnvironmentValues().fontResolutionContext)
            let isBold = resolved?.isBold ?? false
            let isItalic = resolved?.isItalic ?? false

            if isItalic {
                container.font = isBold ? .body.bold() : nil
            } else {
                container.font = isBold ? .body.bold().italic() : .body.italic()
            }
        }
    }

    /// Apply underline formatting to the current selection
    func applyUnderline() {
        text.transformAttributes(in: &selection) { container in
            if container.underlineStyle != nil {
                container.underlineStyle = nil
            } else {
                container.underlineStyle = .single
            }
        }
    }

    /// Apply strikethrough formatting to the current selection
    func applyStrikethrough() {
        text.transformAttributes(in: &selection) { container in
            if container.strikethroughStyle != nil {
                container.strikethroughStyle = nil
            } else {
                container.strikethroughStyle = .single
            }
        }
    }

    /// Remove all line breaks from the text, replacing with spaces
    func removeLineBreaks() {
        text = TextManipulationService.removingLineBreaks(from: text)
    }

    /// Check if there's an active text selection
    var hasSelection: Bool {
        true // We can't easily check, so always enable formatting buttons
    }
}

struct RichTextSidebar: View {
    let document: Document
    @ObservedObject var navigationState: NavigationState
    @AppStorage("showStatisticsPane") private var showStatisticsPane = true
    @Environment(\.modelContext) private var modelContext

    /// Editable text for the current page - always initialized when page exists
    @State private var editableText: EditablePageText?

    /// Controls visibility of the find navigator
    @State private var isFindNavigatorPresented = false

    /// Accessibility focus state for VoiceOver navigation
    @AccessibilityFocusState private var isHeaderFocused: Bool

    /// Tracks hover state for the page header share button
    @State private var isPageHeaderHovered = false

    /// Shows a checkmark confirmation after copying page text
    @State private var showCopyConfirmation = false

    /// Tracks keyboard focus on the share button
    @FocusState private var isShareButtonFocused: Bool

    /// Whether the share button should be visible (hovered or focused)
    private var isShareButtonVisible: Bool {
        isPageHeaderHovered || isShareButtonFocused
    }

    var currentPage: Page? {
        navigationState.currentPage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with page info and formatting "toolbar"
            VStack(alignment: .leading, spacing: 6) {
                if let page = currentPage {
                    Button {
                        #if os(macOS)
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        // Copy both RTF (for rich text apps) and plain text (as fallback)
                        if let rtfData = try? RichText(page.richText).toRTFDataOrThrow() {
                            pasteboard.setData(rtfData, forType: .rtf)
                        }
                        pasteboard.setString(page.plainText, forType: .string)
                        #else
                        let pasteboard = UIPasteboard.general
                        // Copy both RTF (for rich text apps) and plain text (as fallback)
                        if let rtfData = try? RichText(page.richText).toRTFDataOrThrow() {
                            pasteboard.setData(rtfData, forPasteboardType: UTType.rtf.identifier)
                        }
                        pasteboard.string = page.plainText
                        #endif
                        #if os(iOS)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        #endif
                        showCopyConfirmation = true
                        Task {
                            try? await Task.sleep(for: .seconds(3))
                            showCopyConfirmation = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Page \(page.pageNumber) of \(document.totalPages)")
                                .font(.headline)
                                .foregroundStyle(.secondary)

                            Image(systemName: showCopyConfirmation ? "checkmark" : "doc.on.doc")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .contentTransition(.symbolEffect(.replace))
                                .opacity(showCopyConfirmation || isShareButtonVisible ? 1 : 0)
                                .animation(.easeInOut(duration: 0.15), value: isShareButtonVisible)
                        }
                    }
                    .buttonStyle(.plain)
                    .focusable()
                    .focused($isShareButtonFocused)
                    .onHover { hovering in
                        isPageHeaderHovered = hovering
                    }
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel("Text Editor, Page \(page.pageNumber) of \(document.totalPages). Select to copy the page text.")
                    .accessibilityFocused($isHeaderFocused)
                    .help("Copy the Current Page's Text")
                }

                // Formatting "toolbar"
                if let editableText = editableText {
                    HStack(spacing: 12) {
                        Group {
                            Button(action: { editableText.applyBold() }) {
                                Image(systemName: "bold")
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Bold")
                            .help("Bold (⌘B)")

                            Button(action: { editableText.applyItalic() }) {
                                Image(systemName: "italic")
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Italic")
                            .help("Italic (⌘I)")

                            Button(action: { editableText.applyUnderline() }) {
                                Image(systemName: "underline")
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Underline")
                            .help("Underline (⌘U)")

                            Button(action: { editableText.applyStrikethrough() }) {
                                Image(systemName: "strikethrough")
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Strikethrough")
                            .help("Strikethrough (⌘⇧X)")
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Text formatting: Bold, Italic, Underline, Strikethrough")

                        Spacer()

                        Button(action: { editableText.removeLineBreaks() }) {
                            Image(systemName: "line.3.horizontal")
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove Line Breaks")
                        .help("Replace line breaks with spaces")
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Content area - always editable
            if let editableText = editableText {
                TextEditor(
                    text: Bindable(editableText).text,
                    selection: Bindable(editableText).selection
                )
                .findNavigator(isPresented: $isFindNavigatorPresented)
                .safeAreaPadding()
                .accessibilityLabel("Page text editor")
                .accessibilityHint("Use Actions menu to exit editor")
                .accessibilityAction(named: "Exit text editor") {
                    // Move focus back to the header
                    isHeaderFocused = true
                }
                .accessibilityAction(named: "Go to next page") {
                    navigationState.nextPage()
                }
                .accessibilityAction(named: "Go to previous page") {
                    navigationState.previousPage()
                }
            } else {
                // No page selected placeholder
                ContentUnavailableView(
                    "No Page Selected",
                    systemImage: "doc.text",
                    description: Text("Select a page from the sidebar to view and edit its text.")
                )
            }

            // Statistics pane
            if showStatisticsPane, let page = currentPage {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Statistics")
                        .font(.caption)
                        .fontWeight(.semibold)

                    HStack {
                        let wordCount = page.plainText.split(separator: " ").count
                        let charCount = page.plainText.count
                        Label("\(wordCount) words", systemImage: "textformat")
                            .font(.caption)
                        Spacer()
                        Label("\(charCount) characters", systemImage: "character")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .padding()
            }
        }
        .focusedValue(\.editableText, editableText)
        .focusedValue(\.showFindNavigator, $isFindNavigatorPresented)
        .onAppear {
            initializeEditableText()
            // Set VoiceOver focus to the header when view appears
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                isHeaderFocused = true
            }
        }
        .onDisappear {
            // Save any pending changes when view disappears
            editableText?.saveNow()
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            // Emergency save on app quit - catches the case where user quits mid-debounce
            editableText?.saveNow()
            // Force immediate disk write before termination
            try? modelContext.save()
        }
        #endif
        .onChange(of: currentPage) { _, newPage in
            // Save current page before switching
            editableText?.saveNow()

            // Initialize editable text for new page
            if let page = newPage {
                editableText = EditablePageText(page: page)
            } else {
                editableText = nil
            }
        }
    }

    // MARK: - Private Methods

    private func initializeEditableText() {
        guard let page = currentPage else { return }
        editableText = EditablePageText(page: page)
    }
}

// MARK: - Previews

#Preview("RichTextSidebar (English)") {
    @Previewable @State var document = Document(name: "Sample Document", totalPages: 1)
    @Previewable @State var navigationState = NavigationState()

    RichTextSidebar(document: document, navigationState: navigationState)
        .frame(width: 300, height: 500)
        .environment(\.locale, Locale(identifier: "en"))
        .onAppear {
            let page = Page(
                pageNumber: 1,
                text: "Here's to the crazy ones. The misfits. The rebels. The troublemakers. The round pegs in the square holes. The ones who see things differently.",
                imageData: nil,
                originalFileName: "page1.jpg"
            )
            document.pages = [page]
            navigationState.setupNavigation(for: document)
        }
}

#Preview("RichTextSidebar (es-419)") {
    @Previewable @State var document = Document(name: "Documento de Ejemplo", totalPages: 1)
    @Previewable @State var navigationState = NavigationState()

    RichTextSidebar(document: document, navigationState: navigationState)
        .frame(width: 300, height: 500)
        .environment(\.locale, Locale(identifier: "es-419"))
        .onAppear {
            let page = Page(
                pageNumber: 1,
                text: "Este es un texto de ejemplo para vista previa.",
                imageData: nil,
                originalFileName: "pagina1.jpg"
            )
            document.pages = [page]
            navigationState.setupNavigation(for: document)
        }
}
