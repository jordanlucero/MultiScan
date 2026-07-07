//
//  RichTextSidebar.swift
//  MultiScan
//
//  The page text panel: a TextKit 2 editor (PageTextEditor + PageTextController)
//  with the page header, formatting toolbar (macOS), Statistics pane, and Smart
//  Cleanup pane.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct RichTextSidebar: View {
    let document: Document
    @ObservedObject var navigationState: NavigationState

    /// Hides the Statistics and Smart Cleanup panes. Used by the compact (iPhone)
    /// layout, where this view is a bottom sheet and those features live in the More menu.
    var hideBottomPanels = false

    @AppStorage("showStatisticsPane") private var showStatisticsPane = false
    @AppStorage("showSmartCleanup") private var showSmartCleanup = false
    @Environment(\.modelContext) private var modelContext

    /// Editing controller for the current page - always initialized when a page exists
    @State private var textController: PageTextController?

    /// Smart Cleanup analysis results for the current page
    @State private var cleanupOptions: [TextManipulationService.CleanupOption] = []

    /// Whether Smart Cleanup analysis is in progress (including 3-second linger delay)
    @State private var isAnalyzingCleanup = false

    /// Debounce task for Smart Cleanup analysis (3-second linger requirement)
    @State private var cleanupAnalysisTask: Task<Void, Never>?

    /// Controls visibility of the find UI (find bar on macOS, find navigator on iOS)
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
                        copyCurrentPageText(page)
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

                // Formatting "toolbar" (macOS only — on iOS/iPadOS the system provides
                // formatting controls in UITextView's edit menu / keyboard)
                #if os(macOS)
                if let textController = textController {
                    HStack(spacing: 12) {
                        Group {
                            Button(action: { textController.toggleBold() }) {
                                Image(systemName: "bold")
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Bold")
                            .help("Bold (⌘B)")

                            Button(action: { textController.toggleItalic() }) {
                                Image(systemName: "italic")
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Italic")
                            .help("Italic (⌘I)")

                            Button(action: { textController.toggleUnderline() }) {
                                Image(systemName: "underline")
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Underline")
                            .help("Underline (⌘U)")

                            Button(action: { textController.toggleStrikethrough() }) {
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

                        Button(action: { textController.removeLineBreaks() }) {
                            Image(systemName: "line.3.horizontal")
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove Line Breaks")
                        .help("Replace line breaks with spaces")
                    }
                    .padding(.top, 4)
                }
                #endif
            }
            .padding(.horizontal)
            .padding(.top, headerTopPadding)
            .padding(.bottom, 8)

            Divider()

            // Content area - always editable (TextKit 2 text view)
            if let textController = textController {
                // ⚠️ VoiceOver — not yet verified on device since the TextKit 2 migration:
                // these SwiftUI accessibility labels/actions are attached to a representable,
                // and custom actions don't always surface on the wrapped text view's
                // accessibility element the way they did on TextEditor. If they're missing
                // from the VoiceOver rotor/actions menu, reattach them as
                // `accessibilityCustomActions` on PageTextView itself.
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
            if !hideBottomPanels, showStatisticsPane, let textController = textController {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Statistics")
                        .font(.caption)
                        .fontWeight(.semibold)

                    HStack {
                        Label("\(textController.wordCount) words", systemImage: "textformat")
                            .font(.caption)
                        Spacer()
                        Label("\(textController.charCount) characters", systemImage: "character")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .padding()
            }

            // Smart Cleanup pane
            if !hideBottomPanels, showSmartCleanup, currentPage != nil {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Smart Cleanup")
                        .font(.caption)
                        .fontWeight(.semibold)

                    #if os(iOS)
                    // On iOS the header has no formatting toolbar, so Remove Line Breaks lives here
                    if let textController = textController {
                        Button(action: { textController.removeLineBreaks() }) {
                            Label("Remove Line Breaks", systemImage: "line.3.horizontal")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                    #endif

                    Menu {
                        if !isAnalyzingCleanup {
                            ForEach(cleanupOptions) { option in
                                Button(option.label) {
                                    executeCleanupOption(option)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isAnalyzingCleanup {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Checking\u{2026}")
                                    .font(.caption)
                            } else if cleanupOptions.isEmpty {
                                Text("No suggestions")
                                    .font(.caption)
                            } else {
                                Text("\(cleanupOptions.count) \(cleanupOptions.count == 1 ? "suggestion" : "suggestions")")
                                    .font(.caption)
                            }
                        }
                    }
                    .disabled(isAnalyzingCleanup || cleanupOptions.isEmpty)
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel("Smart Cleanup suggestions")
                }
                .padding()
            }
        }
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
            initializeTextController()
            // Set VoiceOver focus to the header when view appears
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                isHeaderFocused = true
            }
        }
        .onDisappear {
            // Save any pending changes when view disappears
            textController?.detach()
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            // Emergency save on app quit - catches the case where user quits mid-debounce
            textController?.saveNow()
            // Force immediate disk write before termination
            try? modelContext.save()
        }
        #else
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
            // Emergency save on app termination - catches the case where the app exits mid-debounce
            textController?.saveNow()
            // Force immediate disk write before termination
            try? modelContext.save()
        }
        #endif
        .onChange(of: currentPage) { _, newPage in
            // Save the outgoing page and sever its view link so a late debounce
            // can never read the new page's storage
            textController?.detach()

            // Initialize the controller for the new page
            if let page = newPage {
                textController = PageTextController(page: page)
            } else {
                textController = nil
            }

            // Re-schedule Smart Cleanup analysis for the new page
            scheduleCleanupAnalysis()
        }
        .onChange(of: showSmartCleanup) { _, _ in
            scheduleCleanupAnalysis()
        }
    }

    // MARK: - Private Methods

    private func initializeTextController() {
        guard let page = currentPage else { return }
        textController = PageTextController(page: page)
    }

    /// Copies the current page's text (RTF + plain text) to the pasteboard.
    /// Uses the live editor content so unsaved edits are included.
    private func copyCurrentPageText(_ page: Page) {
        let exportText = textController?.attributedTextForExport ?? page.attributedText
        let rtfData = RichTextArchiver.rtfData(from: exportText)

        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Copy both RTF (for rich text apps) and plain text (as fallback)
        if let rtfData {
            pasteboard.setData(rtfData, forType: .rtf)
        }
        pasteboard.setString(exportText.string, forType: .string)
        #else
        let pasteboard = UIPasteboard.general
        // Copy both RTF (for rich text apps) and plain text (as fallback)
        if let rtfData {
            pasteboard.setData(rtfData, forPasteboardType: UTType.rtf.identifier)
        }
        pasteboard.string = exportText.string
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif

        showCopyConfirmation = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            showCopyConfirmation = false
        }
    }

    /// Padding above the header. The compact layout presents this view as a sheet,
    /// so extra clearance is needed for the drag indicator.
    private var headerTopPadding: CGFloat {
        hideBottomPanels ? 30 : 12
    }

    // MARK: - Smart Cleanup

    /// Schedules Smart Cleanup analysis after a 3-second linger on the current page.
    /// Cancels any pending analysis when the user navigates away quickly.
    private func scheduleCleanupAnalysis() {
        cleanupAnalysisTask?.cancel()
        cleanupOptions = []

        guard showSmartCleanup, !hideBottomPanels, currentPage != nil else {
            isAnalyzingCleanup = false
            return
        }

        isAnalyzingCleanup = true

        cleanupAnalysisTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return // Cancelled (user navigated away)
            }

            await runCleanupAnalysisAsync()
        }
    }

    /// Runs Smart Cleanup analysis immediately (no delay). Used after cleanup actions.
    private func runCleanupAnalysisImmediately() {
        cleanupAnalysisTask?.cancel()
        cleanupOptions = []
        isAnalyzingCleanup = true

        cleanupAnalysisTask = Task { @MainActor in
            // Save any pending edits so the cache reflects latest text
            textController?.saveNow()
            await runCleanupAnalysisAsync()
        }
    }

    /// Performs the analysis on a background thread, then updates UI on the MainActor.
    private func runCleanupAnalysisAsync() async {
        guard let cacheData = document.textExportCache,
              let pageNumber = currentPage?.pageNumber else {
            isAnalyzingCleanup = false
            return
        }

        // Run expensive analysis off the MainActor
        let options = await Task.detached(priority: .userInitiated) {
            guard let cache = TextExportCacheService.decodeCache(from: cacheData) else {
                return [TextManipulationService.CleanupOption]()
            }
            let result = TextManipulationService.analyzeForSmartCleanup(cache: cache)
            return TextManipulationService.buildOptions(from: result, forPageNumber: pageNumber)
        }.value

        guard !Task.isCancelled else { return }
        cleanupOptions = options
        isAnalyzingCleanup = false
    }

    /// Executes a cleanup option, modifying page text and re-analyzing.
    private func executeCleanupOption(_ option: TextManipulationService.CleanupOption) {
        switch option {
        case .removePageNumber(let detection):
            if detection.pageNumber == currentPage?.pageNumber, let textController {
                textController.removePageNumberTokens(
                    [detection.numberText],
                    actionName: String(localized: "Remove Page Number")
                )
            } else {
                applyEdit(toPage: detection.pageNumber) { text in
                    TextManipulationService.removePageNumberToken(detection.numberText, in: text)
                }
            }

        case .removeSectionHeaderFromPage(let header, let pageNumber):
            if pageNumber == currentPage?.pageNumber, let textController {
                textController.removeLine(
                    matching: header.headerText,
                    stripNumbers: true,
                    actionName: String(localized: "Remove Header")
                )
            } else {
                applyEdit(toPage: pageNumber) { text in
                    TextManipulationService.removeLine(matching: header.headerText, in: text, stripNumbers: true)
                }
            }

        case .removeSectionHeaderFromRange(let header):
            applyBatchEdit(toPages: header.affectedPages) { text, _ in
                TextManipulationService.removeLine(matching: header.headerText, in: text, stripNumbers: true)
            }

        case .removeConsecutiveNumbers(let group, let pageNumber):
            let numberTexts = group.pageMapping[pageNumber] ?? []
            guard !numberTexts.isEmpty else { break }
            if pageNumber == currentPage?.pageNumber, let textController {
                textController.removePageNumberTokens(
                    numberTexts,
                    actionName: String(localized: "Remove Numbers")
                )
            } else {
                applyEdit(toPage: pageNumber) { text in
                    for numberText in numberTexts {
                        TextManipulationService.removePageNumberToken(numberText, in: text)
                    }
                }
            }

        case .removeConsecutiveNumbersFromRange(let group):
            applyBatchEdit(toPages: group.pageMapping.keys.sorted()) { text, pageNumber in
                for numberText in group.pageMapping[pageNumber] ?? [] {
                    TextManipulationService.removePageNumberToken(numberText, in: text)
                }
            }

        case .removeAllPageNumbers(let detections, let consecutiveGroups):
            // Collect every token to remove, per page, then apply in one batch pass
            var tokensByPage: [Int: [String]] = [:]
            for detection in detections {
                tokensByPage[detection.pageNumber, default: []].append(detection.numberText)
            }
            for group in consecutiveGroups {
                for (pageNumber, numberTexts) in group.pageMapping {
                    tokensByPage[pageNumber, default: []].append(contentsOf: numberTexts)
                }
            }
            applyBatchEdit(toPages: tokensByPage.keys.sorted()) { text, pageNumber in
                for numberText in tokensByPage[pageNumber] ?? [] {
                    TextManipulationService.removePageNumberToken(numberText, in: text)
                }
            }
        }

        // Re-analyze immediately so removed options disappear
        runCleanupAnalysisImmediately()
    }

    // MARK: - Model-Side Edits (pages other than the one in the editor)

    /// Applies an edit to a single non-current page, reading from the cache entry
    /// (no page external-storage load) and writing back to both page and cache.
    private func applyEdit(toPage pageNumber: Int, _ transform: (NSMutableAttributedString) -> Void) {
        guard let cache = TextExportCacheService.loadCache(from: document),
              let entry = cache.pages.first(where: { $0.pageNumber == pageNumber }),
              let decoded = entry.decodedText() else { return }

        let working = NSMutableAttributedString(attributedString: decoded)
        transform(working)
        guard !working.isEqual(to: decoded) else { return }

        let cleaned = NSAttributedString(attributedString: working)
        if let page = document.unwrappedPages.first(where: { $0.pageNumber == pageNumber }) {
            page.attributedText = cleaned
            TextExportCacheService.updateEntry(pageNumber: pageNumber, attributedText: cleaned, in: document)
        }
    }

    /// Applies edits to multiple pages efficiently: loads the cache once, modifies all
    /// entries in memory, writes each page's text, and saves the cache once.
    /// Re-initializes the editor if the current page was modified.
    private func applyBatchEdit(
        toPages pageNumbers: [Int],
        _ transform: (NSMutableAttributedString, Int) -> Void
    ) {
        textController?.saveNow()

        guard var cache = TextExportCacheService.loadCache(from: document) else { return }

        var modifiedPages: Set<Int> = []

        for pageNumber in pageNumbers {
            guard let entryIndex = cache.pages.firstIndex(where: { $0.pageNumber == pageNumber }),
                  let decoded = cache.pages[entryIndex].decodedText() else { continue }

            let working = NSMutableAttributedString(attributedString: decoded)
            transform(working, pageNumber)
            guard !working.isEqual(to: decoded) else { continue }

            let cleaned = NSAttributedString(attributedString: working)
            if let page = document.unwrappedPages.first(where: { $0.pageNumber == pageNumber }) {
                page.attributedText = cleaned
            }

            cache.pages[entryIndex] = PageCacheEntry(
                pageNumber: pageNumber,
                fileName: cache.pages[entryIndex].fileName,
                attributedText: cleaned
            )
            modifiedPages.insert(pageNumber)
        }

        TextExportCacheService.saveCache(cache, to: document)

        if let currentPageNum = currentPage?.pageNumber,
           modifiedPages.contains(currentPageNum),
           let page = currentPage {
            textController?.detach()
            textController = PageTextController(page: page)
        }
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
