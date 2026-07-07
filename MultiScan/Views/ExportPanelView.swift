//
//  ExportPanelView.swift
//  MultiScan
//
//  Print-panel-style export view with preview and options.
//
//  Uses `TextExporter` with document-based initialization to enable cache-based export.
//  The preview is a read-only TextKit 2 view (`RichTextPreview`), so the full combined
//  document is displayed without truncation — viewport-based layout keeps even very
//  large exports responsive.
//

import SwiftUI
import SwiftData

struct ExportPanelView: View {
    /// Document to export (enables cache-based export for performance)
    let document: Document

    @Environment(\.dismiss) private var dismiss

    @State private var settings = ExportSettings()
    @State private var exportResult: TextExportResult = .empty
    @State private var isLoading = false
    @State private var exportTask: Task<Void, Never>?
    @State private var debounceTask: Task<Void, Never>?

    /// Convenience accessor for page count display
    private var pageCount: Int { document.unwrappedPages.count }

    var body: some View {
        panelContent
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

    @ViewBuilder
    private var panelContent: some View {
        #if os(iOS)
        // Vertical sheet layout: preview on top, options below, actions in the toolbar
        NavigationStack {
            VStack(spacing: 0) {
                previewPane

                Divider()

                optionsPane
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
                ToolbarItem(placement: .confirmationAction) {
                    ShareLink(item: exportResult.richText, preview: SharePreview("Project Text")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        }
        #else
        // Print-panel-style layout: preview on the left, options on the right
        HStack(spacing: 0) {
            previewPane
                .frame(minWidth: 350, idealWidth: 450)

            Divider()

            optionsPane
                .frame(width: 280)
        }
        #endif
    }

    // MARK: - Preview Pane

    private var previewPane: some View {
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
                RichTextPreview(text: exportResult.attributedText)
                #if os(macOS)
                    .background(Color(nsColor: .textBackgroundColor))
                #else
                    .background(Color(.secondarySystemBackground))
                #endif

                if isLoading && exportResult.plainText.isEmpty {
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

    // MARK: - Options Pane

    #if os(iOS)
    private var optionsPane: some View {
        ScrollView {
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
                    .pickerStyle(.segmented)
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
            }
            .padding()
        }
        .frame(maxHeight: 320)
    }
    #else
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
                .pickerStyle(.radioGroup)
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

                // TODO: Dismiss panel after successful share. SwiftUI's ShareLink has no completion callback as of now (double-check)
                ShareLink(item: exportResult.richText, preview: SharePreview("Project Text")) {
                    Text("Export…")
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding()
    }
    #endif

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
            exportResult = result
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
