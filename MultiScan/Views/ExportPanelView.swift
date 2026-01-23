//
//  ExportPanelView.swift
//  MultiScan
//
//  Print-panel-style export view with preview and options.
//
//  ## Performance
//  Uses `TextExporter` with document-based initialization to enable cache-based export.
//  This loads page data from a single cached file instead of N external storage files,
//  dramatically improving performance for large documents.
//

import SwiftUI
import SwiftData

struct ExportPanelView: View {
    /// Document to export (enables cache-based export for performance)
    let document: Document

    @Environment(\.dismiss) private var dismiss

    @State private var settings = ExportSettings()
    @State private var previewText: AttributedString = AttributedString()
    @State private var isLoading = false
    @State private var exportTask: Task<Void, Never>?
    @State private var debounceTask: Task<Void, Never>?

    /// Convenience accessor for page count display
    private var pageCount: Int { document.pages.count }

    /// Maximum characters to display in preview (SwiftUI Text chokes on huge strings)
    private static let previewCharacterLimit = 50_000

    /// Truncated preview for display — full text is still used for export/share
    private var displayPreviewText: AttributedString {
        let fullCount = previewText.characters.count
        guard fullCount > Self.previewCharacterLimit else { return previewText }

        // Truncate while preserving attributes (use direct subscript, not .characters which strips formatting)
        let endIndex = previewText.characters.index(previewText.startIndex, offsetBy: Self.previewCharacterLimit)
        var truncated = AttributedString(previewText[previewText.startIndex..<endIndex])
        truncated.append(AttributedString("\n\n[Preview truncated — \(fullCount - Self.previewCharacterLimit) more characters]\n[Full text will be exported]"))
        return truncated
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left side: Preview
            previewPane
                .frame(minWidth: 350, idealWidth: 450)

            Divider()

            // Right side: Options
            optionsPane
                .frame(width: 280)
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear { schedulePreviewUpdate(immediate: true) }
        .onChange(of: settings.createVisualSeparation) { schedulePreviewUpdate() }
        .onChange(of: settings.separatorStyle) { schedulePreviewUpdate() }
        .onChange(of: settings.includePageNumber) { schedulePreviewUpdate() }
        .onChange(of: settings.includeFilename) { schedulePreviewUpdate() }
        .onChange(of: settings.includeStatistics) { schedulePreviewUpdate() }
        .onDisappear {
            exportTask?.cancel()
            debounceTask?.cancel()
        }
    }

    // MARK: - Preview Pane (Left)

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Preview")
                    .font(.headline)
                Spacer()
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                }
                Text(pageCount == 1 ? "1 page" : "\(pageCount) pages", comment: "Page count in export panel")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            ZStack {
                ScrollView {
                    Text(displayPreviewText)
                        .font(.body)
                        .textSelection(.disabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                #if os(macOS)
                .background(Color(nsColor: .textBackgroundColor))
                #else
                .background(Color(.secondarySystemBackground))
                #endif

                if isLoading && previewText.characters.isEmpty {
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

    // MARK: - Options Pane (Right)

    private var optionsPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Export Options")
                .font(.headline)

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
                #if os(macOS)
                .pickerStyle(.radioGroup)
                #else
                //idk
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

            Spacer()

            // Action buttons
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                // TODO: Dismiss panel after successful share. SwiftUI's ShareLink has no completion callback (?) — would need NSSharingServicePicker with delegate.
                ShareLink(item: RichText(previewText), preview: SharePreview("Project Text")) {
                    Text("Export…")
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding()
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
            await MainActor.run { runExport() }
        }
    }

    /// Run the async export using cache-based TextExporter
    private func runExport() {
        exportTask?.cancel()

        exportTask = Task {
            isLoading = true
            defer { isLoading = false }

            let exporter = TextExporter(document: document, settings: settings)
            let result = await exporter.buildCombinedTextAsync()

            guard !Task.isCancelled else { return }
            previewText = result
        }
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
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: Document.self, Page.self, configurations: config)

        let document = Document(name: documentName, totalPages: 3)

        (1...3).forEach { i in
            var richText = AttributedString("\(pageTextPrefix) \(i). It contains multiple sentences to demonstrate the export functionality. ")

            var bold = AttributedString(boldText)
            bold.inlinePresentationIntent = .stronglyEmphasized
            richText.append(bold)

            var italic = AttributedString(italicText)
            italic.inlinePresentationIntent = .emphasized
            richText.append(italic)

            richText.append(AttributedString(regularText))

            let page = Page(pageNumber: i, text: "", imageData: nil)
            page.richText = richText
            page.originalFileName = locale == "en" ? "page-\(i).jpg" : "pagina-\(i).jpg"
            document.pages.append(page)
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
