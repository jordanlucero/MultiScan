//
//  ExportPanelView.swift
//  MultiScan
//
//  Print-panel-style export view with preview and options.
//

import SwiftUI

struct ExportPanelView: View {
    let pages: [Page]
    @Environment(\.dismiss) private var dismiss

    @State private var settings = ExportSettings()
    @State private var previewText: AttributedString = AttributedString()
    @State private var isLoading = false
    @State private var exportTask: Task<Void, Never>?
    @State private var debounceTask: Task<Void, Never>?

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
                Text(pages.count == 1 ? "1 page" : "\(pages.count) pages", comment: "Page count in export panel")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            ZStack {
                ScrollView {
                    Text(displayPreviewText)
                        .font(.system(.body))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .background(Color(nsColor: .textBackgroundColor))

                if isLoading && previewText.characters.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Preparing export…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var displayPreviewText: AttributedString {
        var text = previewText
        text.foregroundColor = .primary
        return text
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

                ShareLink(item: RichText(previewText), preview: SharePreview("Document Text")) {
                    Text("Share…")
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

    /// Run the async export
    private func runExport() {
        exportTask?.cancel()

        exportTask = Task {
            isLoading = true
            defer { isLoading = false }

            let exporter = TextExporter(pages: pages, settings: settings)
            let result = await exporter.buildCombinedTextAsync()

            guard !Task.isCancelled else { return }
            previewText = result
        }
    }
}

#Preview {
    ExportPanelView(pages: [])
}
