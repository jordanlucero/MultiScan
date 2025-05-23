import SwiftUI

struct TextSidebar: View {
    let document: Document
    @ObservedObject var navigationState: NavigationState
    @State private var editedText: String = ""
    @State private var isEditing: Bool = false
    
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
                        .padding()
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(8)
                        .padding()
                } else {
                    Text(currentPage?.text ?? "No text detected on this page.")
                        .font(.system(.body, design: .default))
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            
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