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
        .onAppear(perform: updatePreview)
        .onChange(of: settings.flowStyle) { updatePreview() }
        .onChange(of: settings.includePageNumber) { updatePreview() }
        .onChange(of: settings.includeFilename) { updatePreview() }
        .onChange(of: settings.includeStatistics) { updatePreview() }
        .onChange(of: settings.separatorStyle) { updatePreview() }
    }

    // MARK: - Preview Pane (Left)

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Preview")
                    .font(.headline)
                Spacer()
                Text("\(pages.count) pages", comment: "Page count in export panel")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            ScrollView {
                Text(displayPreviewText)
                    .font(.system(.body))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color(nsColor: .textBackgroundColor))
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

            // Flow style picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Page Separation")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("", selection: $settings.flowStyle) {
                    ForEach(ExportFlowStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            // Visual separation options
            VStack(alignment: .leading, spacing: 8) {
                Text("Include in Separator")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Toggle("Page number", isOn: $settings.includePageNumber)
                Toggle("Filename", isOn: $settings.includeFilename)
                Toggle("Statistics", isOn: $settings.includeStatistics)
            }
            .disabled(!settings.visualSeparationEnabled)
            .opacity(settings.visualSeparationEnabled ? 1.0 : 0.5)

            // Separator style picker
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
            .disabled(!settings.visualSeparationEnabled)
            .opacity(settings.visualSeparationEnabled ? 1.0 : 0.5)

            Spacer()

            Divider()

            // Action buttons
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                ShareLink(item: RichText(previewText), preview: SharePreview("Document Text")) {
                    Text("Share...")
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding()
    }

    // MARK: - Logic

    private func updatePreview() {
        let exporter = TextExporter(pages: pages, settings: settings)
        previewText = exporter.buildCombinedText()
    }
}

#Preview {
    ExportPanelView(pages: [])
}
