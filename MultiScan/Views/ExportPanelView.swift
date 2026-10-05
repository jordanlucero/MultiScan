//
//  ExportPanelView.swift
//  MultiScan
//
//  Print-panel-style export view with preview and options.
//
//  Cache-based export. Three ways out (2.1):
//  - **Copy** puts RTF/RTFD + plain text on the pasteboard — the fastest path into a word processor.
//  - **Save As…** uses `fileExporter` with a real default filename (the project's name) and the richest format the content supports (RTFD when illustrations are embedded, RTF otherwise).
//  - **Share** hands the share sheet *data*, not a temp file, so Messages/Notes/Mail receive text (see `RichTextSupport.swift`).
//  The panel also surfaces draft-capture reminders so the user sees what still needs a better scan before the text leaves the app.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ExportPanelView: View {
    /// Document to export (enables cache-based export for performance)
    let document: Document

    @Environment(\.dismiss) private var dismiss

    @State private var settings = ExportSettings()
    @State private var exportResult: TextExportResult = .empty
    @State private var isLoading = false
    @State private var exportTask: Task<Void, Never>?
    @State private var debounceTask: Task<Void, Never>?
    @State private var isSaving = false
    @State private var showCopyConfirmation = false

    /// Convenience accessor for page count display
    private var pageCount: Int { document.unwrappedPages.count }

    var body: some View {
        panelContent
            .onAppear { schedulePreviewUpdate(immediate: true) }
            // The settings reads live in a modifier: reading them here would make every toggle invalidate the (expensive) preview pane as well.
            .modifier(ExportSettingsObserver(settings: settings) { schedulePreviewUpdate() })
            .onDisappear {
                exportTask?.cancel()
                debounceTask?.cancel()
            }
            .fileExporter(
                isPresented: $isSaving,
                document: RichTextFileDocument(richText: exportResult.richText, contentType: exportResult.richText.preferredFileType),
                contentType: exportResult.richText.preferredFileType,
                defaultFilename: exportResult.richText.fileBaseName
            ) { result in
                if case .failure(let error) = result { print("Export save failed: \(error)") }
            }
    }

    @ViewBuilder
    private var panelContent: some View {
        #if os(iOS)
        // Vertical sheet layout: preview on top, options below, actions in the toolbar
        NavigationStack {
            VStack(spacing: 0) {
                ExportPreviewPane(
                    attributedText: exportResult.attributedText,
                    hasContent: !exportResult.plainText.isEmpty,
                    isLoading: isLoading,
                    pageCount: pageCount
                )

                Divider()

                ExportOptionsPane(settings: settings, draftReminders: exportResult.draftReminders)
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        copyToPasteboard()
                    } label: {
                        Label(showCopyConfirmation ? "Copied" : "Copy", systemImage: showCopyConfirmation ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .disabled(exportResult.plainText.isEmpty)
                    .accessibilityLabel("Copy exported text")

                    Button {
                        isSaving = true
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                    .disabled(exportResult.plainText.isEmpty)
                    .accessibilityLabel("Save exported text to Files")

                    ShareLink(item: exportResult.richText, preview: SharePreview(exportResult.richText.suggestedName)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(exportResult.plainText.isEmpty)
                    .buttonStyle(.glassProminent)
                }
            }
        }
        #else
        // Print-panel-style layout: preview on the left, options on the right
        HStack(spacing: 0) {
            ExportPreviewPane(
                attributedText: exportResult.attributedText,
                hasContent: !exportResult.plainText.isEmpty,
                isLoading: isLoading,
                pageCount: pageCount
            )
            .frame(minWidth: 350, idealWidth: 450)

            Divider()

            ExportOptionsPane(
                settings: settings,
                draftReminders: exportResult.draftReminders,
                richText: exportResult.richText,
                isCopyConfirmed: showCopyConfirmation,
                onCopy: copyToPasteboard,
                onSave: { isSaving = true }
            )
            .frame(width: 300)
        }
        #endif
    }

    // MARK: - Logic

    /// Schedule a debounced preview update
    private func schedulePreviewUpdate(immediate: Bool = false) {
        debounceTask?.cancel()

        if immediate {
            runExport()
            return
        }

        // Debounce by 300ms to avoid rapid rebuilds
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            runExport()
        }
    }

    /// Run the async export using cache-based TextExporter
    private func runExport() {
        exportTask?.cancel()

        exportTask = Task {
            isLoading = true
            defer { isLoading = false }

            let result = await TextExporter.export(document, options: settings.options)

            guard !Task.isCancelled else { return }
            exportResult = result
        }
    }

    private func copyToPasteboard() {
        exportResult.richText.copyToPasteboard()
        showCopyConfirmation = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            showCopyConfirmation = false
        }
    }
}

// MARK: - Preview Pane

/// Takes the combined text as a class reference (cheap pointer comparison) plus three scalars, so flipping an export option doesn't re-run the TextKit preview.
struct ExportPreviewPane: View {
    let attributedText: NSAttributedString
    let hasContent: Bool
    let isLoading: Bool
    let pageCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Preview")
                    .font(.headline)
                Spacer()
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                }
                Text(pageCount == 1 ? "1 page" : "\(pageCount) pages", comment: "Page count in export panel")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            ZStack {
                RichTextPreview(text: attributedText)
                #if os(macOS)
                    .background(Color(nsColor: .textBackgroundColor))
                #else
                    .background(Color(.secondarySystemBackground))
                #endif

                if isLoading && !hasContent {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Preparing export…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    #if os(macOS)
                    .background(Color(nsColor: .textBackgroundColor))
                    #else
                    .background(Color(.secondarySystemBackground))
                    #endif
                }
            }
        }
    }
}

// MARK: - Options Pane

struct ExportOptionsPane: View {
    @Bindable var settings: ExportSettings
    let draftReminders: [String]
    #if os(macOS)
    let richText: RichText
    let isCopyConfirmed: Bool
    let onCopy: () -> Void
    let onSave: () -> Void
    #endif

    var body: some View {
        #if os(iOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DraftReminderNotice(reminders: draftReminders)
                ExportOptionControls(settings: settings)
            }
            .padding()
        }
        .frame(maxHeight: 360)
        #else
        VStack(alignment: .leading, spacing: 20) {
            Text("Export Options")
                .font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DraftReminderNotice(reminders: draftReminders)
                    ExportOptionControls(settings: settings)
                }
            }

            Spacer(minLength: 0)

            ExportActionButtons(richText: richText, isCopyConfirmed: isCopyConfirmed, onCopy: onCopy, onSave: onSave)
        }
        .padding()
        #endif
    }
}

/// "You flagged N illustrations as drafts" — shown above the options whenever the project has draft captures.
struct DraftReminderNotice: View {
    let reminders: [String]

    var body: some View {
        if !reminders.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    reminders.count == 1
                        ? String(localized: "1 illustration is still a draft", comment: "Export panel notice")
                        : String(localized: "\(reminders.count) illustrations are still drafts", comment: "Export panel notice"),
                    systemImage: "flag.fill"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)

                ForEach(reminders.prefix(6), id: \.self) { reminder in
                    Text(reminder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if reminders.count > 6 {
                    Text("and \(reminders.count - 6) more", comment: "Export panel: overflow count of draft reminders")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Revisit those pages for a higher-quality scan, then recapture the illustration. The exported text lists them at the end.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
        }
    }
}

/// The toggles and separator picker. Reads only `settings`, so it invalidates on option changes without dragging the preview or the share link along.
struct ExportOptionControls: View {
    @Bindable var settings: ExportSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Visual separation toggle
            Toggle("Add visual separation", isOn: $settings.createVisualSeparation)

            // Separator style picker (only shown when visual separation is enabled)
            VStack(alignment: .leading, spacing: 8) {
                Text("Separator Style")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("", selection: $settings.separatorStyle) {
                    ForEach(SeparatorStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
                #if os(iOS)
                .pickerStyle(.segmented)
                #else
                .pickerStyle(.radioGroup)
                #endif
                .labelsHidden()
            }
            .disabled(!settings.createVisualSeparation)
            .opacity(settings.createVisualSeparation ? 1.0 : 0.5)

            // Separator mods (metadata options)
            VStack(alignment: .leading, spacing: 8) {
                Text("Separator Mods")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Toggle("Page number", isOn: $settings.includePageNumber)
                Toggle("Filename", isOn: $settings.includeFilename)
                Toggle("Statistics", isOn: $settings.includeStatistics)
            }
            .disabled(!settings.createVisualSeparation)
            .opacity(settings.createVisualSeparation ? 1.0 : 0.5)

            // Content
            VStack(alignment: .leading, spacing: 8) {
                Text("Content")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Toggle("Chapter headings", isOn: $settings.includeChapterHeadings)
                Toggle("Embed illustrations", isOn: $settings.includeCaptures)
                Toggle("Draft reminders", isOn: $settings.includeDraftReminders)
            }
        }
    }
}

#if os(macOS)
/// Separate so toggling an export option doesn't rebuild the buttons.
struct ExportActionButtons: View {
    let richText: RichText
    let isCopyConfirmed: Bool
    let onCopy: () -> Void
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button {
                onCopy()
            } label: {
                Label(isCopyConfirmed ? "Copied" : "Copy", systemImage: isCopyConfirmed ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(richText.plainText.isEmpty)
            .keyboardShortcut("c", modifiers: [.command])
            .help("Copy the exported text to the clipboard")

            Button("Save As…") {
                onSave()
            }
            .disabled(richText.plainText.isEmpty)
            .keyboardShortcut("s", modifiers: [.command])
            .help("Save the exported text as a file")

            ShareLink(item: richText, preview: SharePreview(richText.suggestedName)) {
                Text("Share…")
            }
            .disabled(richText.plainText.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 8)
    }
}
#endif

// MARK: - Settings Side Effects

/// Owns the read of the export settings so the panel's body doesn't depend on them — otherwise each toggle invalidates the whole panel.
private struct ExportSettingsObserver: ViewModifier {
    let settings: ExportSettings
    let onChange: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: settings.options) { onChange() }
    }
}

// MARK: - Previews

private struct ExportPanelPreviewHelper: View {
    let documentName: String
    let locale: String
    let pageTextPrefix: String
    let boldText: String
    let italicText: String
    let regularText: String

    var body: some View {
        let container = previewContainer()

        let document = Document(name: documentName, totalPages: 3)

        (1...3).forEach { i in
            let baseFont = PageTextStyle.storageFont
            let richText = NSMutableAttributedString(
                string: "\(pageTextPrefix) \(i). It contains multiple sentences to demonstrate the export functionality. ",
                attributes: [.font: baseFont]
            )

            richText.append(NSAttributedString(
                string: boldText,
                attributes: [.font: baseFont.applyingTraits(bold: true, italic: false)]
            ))

            richText.append(NSAttributedString(
                string: italicText,
                attributes: [.font: baseFont.applyingTraits(bold: false, italic: true)]
            ))

            richText.append(NSAttributedString(string: regularText, attributes: [.font: baseFont]))

            let page = Page(pageNumber: i, text: "", imageData: nil)
            page.attributedText = richText
            page.originalFileName = locale == "en" ? "page-\(i).jpg" : "pagina-\(i).jpg"
            if i == 2 { page.sectionTitle = locale == "en" ? "Chapter Two" : "Capítulo dos" }
            document.pages?.append(page)
        }

        container.mainContext.insert(document)

        return ExportPanelView(document: document)
            .modelContainer(container)
            .environment(\.locale, Locale(identifier: locale))
    }
}

#Preview("English") {
    ExportPanelPreviewHelper(
        documentName: "Sample Export Document",
        locale: "en",
        pageTextPrefix: "This is sample text for page",
        boldText: "This text is bold. ",
        italicText: "This text is italic. ",
        regularText: "And this is regular text again."
    )
}

#Preview("es-419") {
    ExportPanelPreviewHelper(
        documentName: "Documento de Exportación de Ejemplo",
        locale: "es-419",
        pageTextPrefix: "Este es el texto de ejemplo para la página",
        boldText: "Este texto es negrita. ",
        italicText: "Este texto es cursiva. ",
        regularText: "Y este es texto regular de nuevo."
    )
}
