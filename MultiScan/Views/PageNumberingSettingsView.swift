//
//  PageNumberingSettingsView.swift
//  MultiScan
//
//  Where the physical book starts counting: a small sheet editing the document's printed numbering, with a live preview of the resulting labels so the user can check "project page 9 → printed 1, page 8 → viii" before saving.
//
//  The sheet talks in project page numbers, so it edits the plan's *resolved* form (`ResolvedPrintedNumbering`, ranges placed at their current positions) and anchors it back to the pages on Save (`anchored(to:)`). After that the numbering follows those pages wherever they move.
//
//  The common case is two ranges — Roman (or unnumbered) front matter, then Arabic numbering from one page — and that is all the sheet shows by default. Documents with more structure (an appendix that restarts at 1, plates without numbers) can add ranges under **Additional numbering ranges**, a collapsed disclosure: real, but deliberately out of the way, because for most physical documents it is a confusing concept.
//

import SwiftUI
import SwiftData

struct PageNumberingSettingsView: View {
    @Bindable var document: Document
    @Environment(\.dismiss) private var dismiss

    // Local draft so Cancel really cancels.
    @State private var isEnabled: Bool
    @State private var startPage: Int
    @State private var startValue: Int
    @State private var frontMatterStyle: PrintedNumberingStyle
    @State private var additionalRanges: [ResolvedPrintedNumbering.Range]
    @State private var showAdditionalRanges = false

    init(document: Document) {
        self.document = document
        let plan = PageNumbering.resolvedPlan(for: document)
        _isEnabled = State(initialValue: plan != nil)
        _startPage = State(initialValue: plan?.mainRange?.startPage ?? 1)
        _startValue = State(initialValue: plan?.mainRange?.startValue ?? 1)
        let front = plan?.frontMatterStyle ?? .roman
        _frontMatterStyle = State(initialValue: front == .arabic ? .roman : front)
        _additionalRanges = State(initialValue: plan?.additionalRanges ?? [])
        _showAdditionalRanges = State(initialValue: !(plan?.additionalRanges.isEmpty ?? true))
    }

    private var totalPages: Int { max(document.totalPages, 1) }

    /// The plan the current draft describes.
    private var draftPlan: ResolvedPrintedNumbering {
        var plan = ResolvedPrintedNumbering.simple(startPage: startPage, startValue: startValue, frontMatter: frontMatterStyle)
        plan.ranges.append(contentsOf: additionalRanges.filter { $0.startPage > startPage })
        return ResolvedPrintedNumbering(ranges: plan.ranges)
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
                        Stepper(value: $startPage, in: 1...totalPages) {
                            LabeledContent("Project page", value: "\(startPage)")
                        }
                        Stepper(value: $startValue, in: 1...9999) {
                            LabeledContent("…is printed page", value: "\(startValue)")
                        }
                        Picker("Pages before that", selection: $frontMatterStyle) {
                            Text(PrintedNumberingStyle.roman.label).tag(PrintedNumberingStyle.roman)
                            Text(PrintedNumberingStyle.none.label).tag(PrintedNumberingStyle.none)
                        }
                        .disabled(startPage == 1)
                    }

                    Section("Preview") {
                        ForEach(previewPages, id: \.self) { page in
                            LabeledContent("Page \(page)") {
                                Text(draftPlan.label(forProjectPage: page) ?? "—")
                                    .monospacedDigit()
                            }
                        }
                    }

                    // Buried on purpose: most physical documents are numbered once, front to back.
                    Section {
                        DisclosureGroup("Additional numbering ranges", isExpanded: $showAdditionalRanges) {
                            Text("For documents whose numbering restarts — an appendix counted from 1 again, or plates without numbers. Each range applies from its start page until the next range begins.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            ForEach($additionalRanges) { $range in
                                AdditionalRangeRow(range: $range, minimumStartPage: startPage + 1, totalPages: totalPages) {
                                    additionalRanges.removeAll { $0.id == range.id }
                                }
                            }

                            Button {
                                let nextStart = min(totalPages, max(startPage + 1, (additionalRanges.map(\.startPage).max() ?? startPage) + 1))
                                additionalRanges.append(ResolvedPrintedNumbering.Range(startPage: nextStart, style: .arabic, startValue: 1))
                            } label: {
                                Label("Add Range", systemImage: "plus")
                            }
                            .disabled(startPage >= totalPages)
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
        .frame(minWidth: 460, minHeight: 480)
        #endif
    }

    /// A handful of representative pages: the first, the ones around each range start, and the last.
    private var previewPages: [Int] {
        var pages: Set<Int> = [1, totalPages]
        for start in [startPage] + additionalRanges.map(\.startPage) {
            for page in (start - 1)...(start + 1) where page >= 1 && page <= totalPages { pages.insert(page) }
        }
        return pages.sorted().prefix(10).map { $0 }
    }

    private func save() {
        // Anchor each range to the page it currently starts on; from here the numbering follows those pages.
        let plan = isEnabled ? draftPlan.anchored(to: document.sortedPages) : nil
        document.printedNumbering = (plan?.ranges.isEmpty ?? true) ? nil : plan
        document.lastModified = Date()
        try? document.modelContext?.save()
        dismiss()
    }
}

/// One editable additional range: start page, style, start value, delete.
private struct AdditionalRangeRow: View {
    @Binding var range: ResolvedPrintedNumbering.Range
    let minimumStartPage: Int
    let totalPages: Int
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Stepper(value: $range.startPage, in: minimumStartPage...max(minimumStartPage, totalPages)) {
                    LabeledContent("From project page", value: "\(range.startPage)")
                }
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove range")
            }
            Picker("Style", selection: $range.style) {
                ForEach(PrintedNumberingStyle.allCases, id: \.self) { style in
                    Text(style.label).tag(style)
                }
            }
            if range.style != .none {
                Stepper(value: $range.startValue, in: 1...9999) {
                    LabeledContent("Starting at", value: "\(range.startValue)")
                }
            }
        }
        .padding(.vertical, 4)
    }
}
