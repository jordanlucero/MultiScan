//
//  RichTextSidebar.swift
//  MultiScan
//
//  A unified rich text viewing and editing sidebar using SwiftUI's
//  native AttributedString support in macOS 26+.
//

import SwiftUI

/// View model for managing editable rich text with selection tracking
@MainActor
@Observable
final class EditablePageText: Identifiable {
    let page: Page

    var text: AttributedString {
        get {
            // Handle conflicts between local edits and SwiftData updates
            if lastModified >= page.lastModified {
                editedText
            } else {
                page.richText
            }
        }
        set {
            page.richText = newValue
            editedText = newValue
        }
    }

    private var editedText: AttributedString {
        didSet {
            lastModified = .now
        }
    }
    private var lastModified: Date

    var selection: AttributedTextSelection

    init(page: Page) {
        self.page = page
        self.selection = AttributedTextSelection()
        self.editedText = page.richText
        self.lastModified = page.lastModified
    }
}

struct RichTextSidebar: View {
    let document: Document
    @ObservedObject var navigationState: NavigationState
    @AppStorage("showStatisticsPane") private var showStatisticsPane = true

    @State private var editableText: EditablePageText?

    var currentPage: Page? {
        navigationState.currentPage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                Text("OCR Text")
                    .font(.headline)

                if let page = currentPage {
                    Text("Page \(page.pageNumber) of \(document.totalPages)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Rich text editor - supports native formatting via Format menu (⌘B, ⌘I)
            if let editableText = editableText {
                TextEditor(
                    text: Bindable(editableText).text,
                    selection: Bindable(editableText).selection
                )
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding([.top, .leading, .trailing])
            } else {
                Text("No text detected on this page.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding()
            }

            // Statistics pane
            if showStatisticsPane, let page = currentPage {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Statistics")
                        .font(.caption)
                        .fontWeight(.semibold)

                    HStack {
                        let text = page.plainText
                        Label("\(text.split(separator: " ").count) words", systemImage: "textformat")
                            .font(.caption)
                        Spacer()
                        Label("\(text.count) characters", systemImage: "character")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .padding()
            }
        }
        .onChange(of: currentPage) { _, newPage in
            if let page = newPage {
                editableText = EditablePageText(page: page)
            } else {
                editableText = nil
            }
        }
        .onAppear {
            if let page = currentPage {
                editableText = EditablePageText(page: page)
            }
        }
    }
}
