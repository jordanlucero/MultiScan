import SwiftUI

struct TextSidebar: View {
    let document: Document
    @ObservedObject var navigationState: NavigationState
    @State private var editedText: String = ""
    @State private var isEditing: Bool = false
    @State private var showLineBreaks: Bool = false
    @State private var showFormattingHelp: Bool = false
    @AppStorage("showStatisticsPane") private var showStatisticsPane = true
    @AppStorage("useSmartParagraphs") private var useSmartParagraphs = false

    var currentPage: Page? {
        navigationState.currentPage
    }

    /// Returns formatted text based on smart paragraphs setting
    var displayText: String {
        guard let page = currentPage else {
            return "No text detected on this page."
        }

        // If smart paragraphs is enabled and we have bounding box data, use it
        if useSmartParagraphs && !page.boundingBoxes.isEmpty {
            return TextPostProcessor.applySmartParagraphs(
                rawText: page.text,
                boundingBoxes: page.boundingBoxes
            )
        }

        // Otherwise return raw text
        return page.text
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

            // Text content area
            ScrollView {
                if isEditing {
                    TextEditor(text: $editedText)
                        .font(.system(.body, design: .default))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 200)
                } else {
                    if showLineBreaks {
                        LineBreakVisibleText(text: displayText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(displayText)
                            .font(.system(.body, design: .default))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding()

            // Statistics pane
            if showStatisticsPane {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Statistics")
                        .font(.caption)
                        .fontWeight(.semibold)

                    if let page = currentPage {
                        HStack {
                            Label("\(page.text.split(separator: " ").count) words", systemImage: "textformat")
                                .font(.caption)
                            Spacer()
                            Label("\(page.text.count) characters", systemImage: "character")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: { showLineBreaks.toggle() }) {
                    Label(showLineBreaks ? "Hide Line Breaks" : "Show Line Breaks",
                          systemImage: showLineBreaks ? "text.line.first.and.arrowtriangle.forward" : "text.alignleft")
                        .labelStyle(.iconOnly)
                }
                .help(showLineBreaks ? "Hide Line Breaks" : "Show Line Breaks")

                if isEditing {
                    Button(action: { showFormattingHelp.toggle() }) {
                        Label("Formatting Help", systemImage: "questionmark.circle")
                            .labelStyle(.iconOnly)
                    }
                    .popover(isPresented: $showFormattingHelp, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Formatting Syntax")
                                .font(.headline)
                            Divider()
                            Text("**Bold** → Two Asterisks")
                            Text("*Italic* → One Asterisk")
                        }
                        .padding()
                        .frame(width: 220)
                    }
                    .help("Formatting syntax")
                }

                Button(action: { isEditing.toggle() }) {
                    Label(isEditing ? "Save" : "Edit",
                          systemImage: isEditing ? "checkmark.circle" : "pencil.circle")
                        .labelStyle(.iconOnly)
                }
                .help(isEditing ? "Save Changes" : "Edit Text")
            }
        }
        .onChange(of: currentPage) { _, newPage in
            if let page = newPage {
                editedText = page.text
                isEditing = false
            }
        }
        .onChange(of: isEditing) { oldValue, newValue in
            if oldValue && !newValue {
                saveChanges()
            }
        }
        .onAppear {
            if let page = currentPage {
                editedText = page.text
            }
        }
    }
    
    private func saveChanges() {
        guard let page = currentPage else { return }
        page.text = editedText
    }
}

struct LineBreakVisibleText: View {
    let text: String
    
    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(spacing: 4) {
                    Text(String(line))
                        .font(.system(.body, design: .default))
                        .textSelection(.enabled)
                    
                    if index < lines.count - 1 {
                        Image(systemName: "arrow.turn.down.left")
                            .font(.caption)
                            .foregroundColor(.accentColor.opacity(0.6))
                            .help("Line break")
                    }
                    
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
