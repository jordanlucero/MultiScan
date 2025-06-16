import SwiftUI

struct TextSidebar: View {
    let document: Document
    @ObservedObject var navigationState: NavigationState
    @State private var editedText: String = ""
    @State private var isEditing: Bool = false
    @State private var showLineBreaks: Bool = false
    @State private var showFormattingHelp: Bool = false
    @AppStorage("showStatisticsPane") private var showStatisticsPane = true
    
    var currentPage: Page? {
        navigationState.currentPage
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("OCR Text")
                        .font(.headline)
                    
                    if let page = currentPage {
                        Text("Page \(page.pageNumber) of \(document.totalPages)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                Button(action: { showLineBreaks.toggle() }) {
                    Image(systemName: showLineBreaks ? "text.line.first.and.arrowtriangle.forward" : "text.alignleft")
                }
                .help(showLineBreaks ? "Hide Line Breaks" : "Show Line Breaks")
                
                if isEditing {
                    Button(action: { showFormattingHelp.toggle() }) {
                        Image(systemName: "questionmark.circle")
                    }
                    .popover(isPresented: $showFormattingHelp, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Formatting Syntax")
                                .font(.headline)
                            Divider()
                            HStack {
                                Text("Two Asterisks → **Bold**")
                            }
                            HStack {
                                Text("One Asterisk → *Italic*")
                            }
                        }
                        .padding()
                        .frame(width: 200)
                    }
                    .help("Formatting syntax")
                }
                
                Button(action: { isEditing.toggle() }) {
                    Image(systemName: isEditing ? "checkmark.circle.fill" : "pencil.circle")
                }
                .help(isEditing ? "Save Changes" : "Edit Text")
            }
            .padding()
            
            Divider()
            
            ScrollView {
                if isEditing {
                    TextEditor(text: $editedText)
                        .font(.system(.body, design: .default))
                        .scrollContentBackground(.hidden)
                        .padding()
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(8)
                        .padding()
                } else {
                    if showLineBreaks {
                        LineBreakVisibleText(text: currentPage?.text ?? "No text detected on this page.")
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(currentPage?.text ?? "No text detected on this page.")
                            .font(.system(.body, design: .default))
                            .textSelection(.enabled)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            
            if showStatisticsPane {
                Divider()
                
                VStack(spacing: 8) {
                    HStack {
                        Text("Statistics")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Spacer()
                    }
                    
                    if let page = currentPage {
                        HStack {
                            Label("\(page.text.split(separator: " ").count) words", systemImage: "textformat")
                                .font(.caption)
                            Spacer()
                            Label("\(page.text.count) characters", systemImage: "character")
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
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
