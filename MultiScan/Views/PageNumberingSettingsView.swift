//
//  PageNumberingSettingsView.swift
//  MultiScan
//
//  Where the physical book starts counting: a small sheet editing `Document.printedNumberingStartPage` / `printedNumberingStartValue` / `frontMatterNumberingStyle`, with a live preview of the resulting labels so the user can check "project page 9 → printed 1, page 8 → viii" before saving.
//

import SwiftUI
import SwiftData

struct PageNumberingSettingsView: View {
    @Bindable var document: Document
    @Environment(\.dismiss) private var dismiss

    /// Local draft so Cancel really cancels.
    @State private var isEnabled: Bool
    @State private var startPage: Int
    @State private var startValue: Int
    @State private var frontMatterStyle: FrontMatterNumberingStyle

    init(document: Document) {
        self.document = document
        _isEnabled = State(initialValue: document.printedNumberingStartPage != nil)
        _startPage = State(initialValue: document.printedNumberingStartPage ?? 1)
        _startValue = State(initialValue: document.printedNumberingStartValue)
        _frontMatterStyle = State(initialValue: document.frontMatterStyle)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Use printed page numbers", isOn: $isEnabled)
                    Text("Show the numbers printed in the physical book next to MultiScan's own page numbers — in the sidebar, the Digest, exports, and reminders to rescan illustrations.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isEnabled {
                    Section("Where counting starts") {
                        Stepper(value: $startPage, in: 1...max(document.totalPages, 1)) {
                            LabeledContent("Project page", value: "\(startPage)")
                        }
                        Stepper(value: $startValue, in: 1...9999) {
                            LabeledContent("…is printed page", value: "\(startValue)")
                        }
                        Picker("Pages before that", selection: $frontMatterStyle) {
                            ForEach(FrontMatterNumberingStyle.allCases, id: \.self) { style in
                                Text(style.label).tag(style)
                            }
                        }
                    }

                    Section("Preview") {
                        ForEach(previewPages, id: \.self) { page in
                            LabeledContent("Page \(page)") {
                                Text(PageNumbering.printedLabel(forProjectPage: page, startPage: startPage, startValue: startValue, frontMatterStyle: frontMatterStyle) ?? "—")
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Page Numbering")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }

    /// A handful of representative pages: the first, the ones around the start, and the last.
    private var previewPages: [Int] {
        let total = max(document.totalPages, 1)
        var pages: Set<Int> = [1, total]
        for page in (startPage - 2)...(startPage + 1) where page >= 1 && page <= total { pages.insert(page) }
        return pages.sorted()
    }

    private func save() {
        document.printedNumberingStartPage = isEnabled ? startPage : nil
        document.printedNumberingStartValue = startValue
        document.frontMatterStyle = frontMatterStyle
        document.lastModified = Date()
        try? document.modelContext?.save()
        dismiss()
    }
}
