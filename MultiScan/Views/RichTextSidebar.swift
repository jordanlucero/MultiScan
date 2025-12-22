import SwiftUI

/// View model for managing editable rich text during edit mode
@MainActor
@Observable
final class EditablePageText: Identifiable {
    private let page: Page

    /// The text being edited - only modified during edit sessions
    var text: AttributedString

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

    /// Save changes back to the page
    func save() {
        // Strip any foreground color before saving (we apply it dynamically for display)
        var cleanText = text
        for run in cleanText.runs {
            let range = run.range
            cleanText[range].foregroundColor = nil
        }
        page.richText = cleanText
    }

    /// Discard changes and reload from page
    func revert() {
        text = page.richText
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

    /// Check if there's an active text selection
    var hasSelection: Bool {
        true // We can't easily check, so always enable formatting buttons
    }
}

struct RichTextSidebar: View {
    let document: Document
    @ObservedObject var navigationState: NavigationState
    @AppStorage("showStatisticsPane") private var showStatisticsPane = true
    @Environment(\.colorScheme) private var colorScheme

    @State private var isEditing: Bool = false
    @State private var editableText: EditablePageText?

    var currentPage: Page? {
        navigationState.currentPage
    }

    /// Display text with proper color for current color scheme
    private var displayText: AttributedString {
        guard let page = currentPage else {
            return AttributedString(localized: "No text detected on this page.")
        }
        var text = page.richText
        // Apply primary color for proper dark/light mode support
        text.foregroundColor = Color.primary
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 6) {

                if let page = currentPage {
                    Text("Page \(page.pageNumber) of \(document.totalPages)")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Content area - either viewing or editing
            if isEditing, let editableText = editableText {
                // Edit mode: TextEditor with formatting support
                VStack(spacing: 0) {
                    // Formatting toolbar
                    HStack(spacing: 12) {
                        Button(action: { editableText.applyBold() }) {
                            Image(systemName: "bold")
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderless)
                        .help("Bold (⌘B)")

                        Button(action: { editableText.applyItalic() }) {
                            Image(systemName: "italic")
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderless)
                        .help("Italic (⌘I)")

                        Button(action: { editableText.applyUnderline() }) {
                            Image(systemName: "underline")
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderless)
                        .help("Underline (⌘U)")

                        Button(action: { editableText.applyStrikethrough() }) {
                            Image(systemName: "strikethrough")
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderless)
                        .help("Strikethrough (⌘⇧X)")

                        Spacer()

                        Text("Editing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)

                    Divider()

                    TextEditor(
                        text: Bindable(editableText).text,
                        selection: Bindable(editableText).selection
                    )
                    .safeAreaPadding()
                }
            } else {
                // View mode: Read-only styled text
                ScrollView {
                    Text(displayText)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
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
        .focusedValue(\.editableText, isEditing ? editableText : nil)
        .toolbar {
            ToolbarItemGroup {
                if isEditing {
                    Button(action: cancelEditing) {
                        Label("Discard", systemImage: "xmark.circle")
                            .labelStyle(.iconOnly)
                    }
                    .help("Discard Changes")

                    Button(action: saveAndExitEditing) {
                        Label("Done", systemImage: "checkmark.circle")
                            .labelStyle(.iconOnly)
                    }
                    .help("Save Changes")
                } else {
                    Button(action: startEditing) {
                        Label("Edit Text", systemImage: "pencil.circle")
                            .labelStyle(.iconOnly)
                    }
                    .help("Edit OCR Text")
                    .disabled(currentPage == nil)
                }
            }
        }
        .onChange(of: currentPage) { _, newPage in
            // When page changes, exit edit mode and reset
            if isEditing {
                // Auto-save when switching pages
                editableText?.save()
                isEditing = false
            }
            editableText = nil
        }
    }

    // MARK: - Edit Mode Actions

    private func startEditing() {
        guard let page = currentPage else { return }
        editableText = EditablePageText(page: page)
        isEditing = true
    }

    private func saveAndExitEditing() {
        editableText?.save()
        isEditing = false
        editableText = nil
    }

    private func cancelEditing() {
        editableText?.revert()
        isEditing = false
        editableText = nil
    }
}
