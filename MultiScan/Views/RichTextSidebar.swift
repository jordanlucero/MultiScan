//
//  RichTextSidebar.swift
//  MultiScan
//
//  The page text panel: a TextKit 2 editor (PageTextEditor) for the current page's `PageTextController`, with the page header, formatting toolbar (macOS), Statistics pane, and Smart Cleanup pane. `ReviewView` owns the controller and the Smart Cleanup model; this view only displays them, so it can be the split view's inspector or the iPhone's bottom sheet interchangeably.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct RichTextSidebar: View {
    let document: Document
    let navigationState: NavigationState

    /// The current page's editing controller (nil when no page is selected).
    let textController: PageTextController?

    /// Smart Cleanup analysis for this project.
    let cleanup: SmartCleanupModel

    /// Hides the Statistics and Smart Cleanup panes. Used by the compact (iPhone) layout, where this view is a bottom sheet and those features live in the More menu.
    var hideBottomPanels = false

    let onApplyCleanup: (TextManipulationService.CleanupOption) -> Void

    @AppStorage(DefaultsKey.showStatisticsPane) private var showStatisticsPane = false
    @AppStorage(DefaultsKey.showSmartCleanup) private var showSmartCleanup = false

    /// Controls visibility of the find UI (find bar on macOS, find navigator on iOS)
    @State private var isFindNavigatorPresented = false

    /// Accessibility focus state for VoiceOver navigation
    @AccessibilityFocusState private var isHeaderFocused: Bool

    private var currentPage: Page? {
        navigationState.currentPage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with page info and formatting "toolbar"
            VStack(alignment: .leading, spacing: 6) {
                if let page = currentPage {
                    PageTextHeader(
                        pageNumber: page.pageNumber,
                        totalPages: document.totalPages,
                        isHeaderFocused: $isHeaderFocused,
                        onCopy: { copyCurrentPageText(page) }
                    )
                }

                // Formatting "toolbar" (macOS only — on iOS/iPadOS the system provides formatting controls in UITextView's edit menu / keyboard)
                #if os(macOS)
                if let textController {
                    TextFormattingToolbar(controller: textController)
                        .padding(.top, 4)
                }
                #endif
            }
            .padding(.horizontal)
            .padding(.top, headerTopPadding)
            .padding(.bottom, 8)

            Divider()

            // Content area - always editable (TextKit 2 text view)
            if let textController {
                // ⚠️ VoiceOver — not yet verified on device since the TextKit 2 migration: these SwiftUI accessibility labels/actions are attached to a representable, and custom actions don't always surface on the wrapped text view's accessibility element the way they did on TextEditor. If they're missing from the VoiceOver rotor/actions menu, reattach them as `accessibilityCustomActions` on PageTextView itself.
                PageTextEditor(controller: textController)
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
            if !hideBottomPanels, showStatisticsPane, let textController {
                Divider()

                TextStatisticsPane(controller: textController)
            }

            // Smart Cleanup pane
            if !hideBottomPanels, showSmartCleanup, currentPage != nil {
                Divider()

                SmartCleanupPane(
                    cleanup: cleanup,
                    textController: textController,
                    onApply: onApplyCleanup
                )
            }
        }
        // Focus-scoped (not scene-scoped) so the Format menu and Find… act on the editor only while this panel has focus.
        .focusedValue(\.pageTextController, textController)
        .focusedValue(\.showFindNavigator, $isFindNavigatorPresented)
        .onChange(of: isFindNavigatorPresented) { _, presented in
            // The Find menu command flips this binding; forward it to the text view.
            if presented {
                textController?.presentFindNavigator()
                isFindNavigatorPresented = false
            }
        }
        .onAppear {
            // Set VoiceOver focus to the header when view appears
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                isHeaderFocused = true
            }
        }
    }

    /// Copies the current page's text (RTFD/RTF + plain text) to the pasteboard.
    /// Uses the live editor content so unsaved edits are included. Capture references are swapped for real images first so a paste into Notes/Pages shows the illustration.
    private func copyCurrentPageText(_ page: Page) {
        let exportText = textController?.attributedTextForExport ?? page.attributedText
        var hasImages = false
        let captures = page.unwrappedCaptures.compactMap { capture -> TextExporter.CaptureSnapshot? in
            guard let id = capture.uuid else { return nil }
            return TextExporter.CaptureSnapshot(id: id, imageData: capture.imageData, isDraft: capture.isDraft, caption: capture.caption, reminder: capture.reminderDescription)
        }
        let resolved = TextExporter.resolveAttachments(in: exportText, captures: captures, options: ExportSettings.currentOptions, baseFont: PageTextStyle.storageFont, hasImages: &hasImages)
        RichText(resolved, suggestedName: "\(document.name) — \(page.title)").copyToPasteboard()
    }

    /// Padding above the header. The compact layout presents this view as a sheet, so extra clearance is needed for the drag indicator.
    private var headerTopPadding: CGFloat {
        hideBottomPanels ? 30 : 12
    }
}

// MARK: - Page Header

/// Owns the hover / focus / copy-confirmation state. Keeping it out of
/// RichTextSidebar means pointing at the header doesn't re-run the editor.
struct PageTextHeader: View {
    let pageNumber: Int
    let totalPages: Int
    @AccessibilityFocusState.Binding var isHeaderFocused: Bool
    let onCopy: () -> Void

    @State private var isHovered = false
    @State private var showCopyConfirmation = false
    @FocusState private var isFocused: Bool

    /// Whether the share button should be visible (hovered or focused)
    private var isShareButtonVisible: Bool {
        isHovered || isFocused
    }

    var body: some View {
        Button {
            onCopy()
            showCopyConfirmation = true
            Task {
                try? await Task.sleep(for: .seconds(3))
                showCopyConfirmation = false
            }
        } label: {
            HStack(spacing: 6) {
                Text("Page \(pageNumber) of \(totalPages)")
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
        .focused($isFocused)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("Text Editor, Page \(pageNumber) of \(totalPages). Select to copy the page text.")
        .accessibilityFocused($isHeaderFocused)
        .help("Copy the Current Page's Text")
    }
}

// MARK: - Formatting Toolbar

#if os(macOS)
struct TextFormattingToolbar: View {
    let controller: PageTextController

    var body: some View {
        HStack(spacing: 12) {
            Group {
                Button(action: { controller.toggleBold() }) {
                    Image(systemName: "bold")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Bold")
                .help("Bold (⌘B)")

                Button(action: { controller.toggleItalic() }) {
                    Image(systemName: "italic")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Italic")
                .help("Italic (⌘I)")

                Button(action: { controller.toggleUnderline() }) {
                    Image(systemName: "underline")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Underline")
                .help("Underline (⌘U)")

                Button(action: { controller.toggleStrikethrough() }) {
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

            Button(action: { controller.removeLineBreaks() }) {
                Image(systemName: "line.3.horizontal")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove Line Breaks")
            .help("Replace line breaks with spaces")
        }
    }
}
#endif

// MARK: - Statistics Pane

/// `wordCount`/`charCount` update on every keystroke. Reading them here instead
/// of in RichTextSidebar's body keeps typing from re-running PageTextEditor's
/// representable update on each character.
struct TextStatisticsPane: View {
    let controller: PageTextController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Statistics")
                .font(.caption)
                .fontWeight(.semibold)

            HStack {
                Label("\(controller.wordCount) words", systemImage: "textformat")
                    .font(.caption)
                Spacer()
                Label("\(controller.charCount) characters", systemImage: "character")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .padding()
    }
}

// MARK: - Smart Cleanup Pane

/// Reads the analysis state, so a cleanup pass finishing doesn't re-run the editor.
struct SmartCleanupPane: View {
    let cleanup: SmartCleanupModel
    let textController: PageTextController?
    let onApply: (TextManipulationService.CleanupOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Smart Cleanup")
                .font(.caption)
                .fontWeight(.semibold)

            #if os(iOS)
            // On iOS the header has no formatting toolbar, so Remove Line Breaks lives here
            if let textController {
                Button(action: { textController.removeLineBreaks() }) {
                    Label("Remove Line Breaks", systemImage: "line.3.horizontal")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            #endif

            let isAnalyzing = cleanup.isAnalyzing
            let options = cleanup.options

            Menu {
                if !isAnalyzing {
                    ForEach(options) { option in
                        Button(option.label) {
                            onApply(option)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    if isAnalyzing {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking\u{2026}")
                            .font(.caption)
                    } else if options.isEmpty {
                        Text("No suggestions")
                            .font(.caption)
                    } else {
                        Text("\(options.count) suggestions")
                            .font(.caption)
                    }
                }
            }
            .disabled(isAnalyzing || options.isEmpty)
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Smart Cleanup suggestions")
        }
        .padding()
    }
}

// MARK: - Previews

#Preview("RichTextSidebar (English)") {
    @Previewable @State var document = Document(name: "Sample Document", totalPages: 1)
    @Previewable @State var navigationState = NavigationState()
    @Previewable @State var textController: PageTextController?

    RichTextSidebar(
        document: document,
        navigationState: navigationState,
        textController: textController,
        cleanup: SmartCleanupModel(document: document),
        onApplyCleanup: { _ in }
    )
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
        textController = PageTextController(page: page)
    }
}

#Preview("RichTextSidebar (es-419)") {
    @Previewable @State var document = Document(name: "Documento de Ejemplo", totalPages: 1)
    @Previewable @State var navigationState = NavigationState()
    @Previewable @State var textController: PageTextController?

    RichTextSidebar(
        document: document,
        navigationState: navigationState,
        textController: textController,
        cleanup: SmartCleanupModel(document: document),
        onApplyCleanup: { _ in }
    )
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
        textController = PageTextController(page: page)
    }
}
