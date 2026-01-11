import SwiftUI
import SwiftData

struct DocumentCard: View {
    @Bindable var document: Document
    let isProcessing: Bool
    let ocrProgress: Double
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onOptimize: () -> Void

    @Environment(\.modelContext) private var modelContext

    /// Delay before focusing text fields to ensure they're in the view hierarchy
    private static let focusDelay: TimeInterval = 0.1

    // Inline rename state
    @State private var isEditingName = false
    @State private var editedName: String = ""
    @FocusState private var isNameFieldFocused: Bool

    // Emoji picker state
    @State private var showingEmojiPopover = false
    @State private var emojiInput: String = ""
    @FocusState private var isEmojiFieldFocused: Bool
    @FocusState private var isMenuButtonFocused: Bool

    // Hover state for menu button visibility
    @State private var isHovered = false

    // Keyboard focus state
    @FocusState private var isCardFocused: Bool

    // Export panel state
    @State private var showingExportPanel = false
    private var menuButtonVisible: Bool {
          showEncompassingContainer || isMenuButtonFocused
      }

    /// Whether to show the encompassing container (when selected or hovered)
    private var showEncompassingContainer: Bool {
        isSelected || isHovered
    }

    var body: some View {
        // Encompassing container
        VStack(spacing: 12) {
            thumbnailSection
            titleSection
        }
        .background {
            if showEncompassingContainer {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.clear)
            }
        }
//        .animation(.easeInOut(duration: 0.15), value: showEncompassingContainer)
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture(count: 2) {
            guard !isProcessing else { return }
            onOpen()
        }
        .onTapGesture(count: 1) {
            onSelect()
            //change to just simple system focus, no need for extra complexity?
        }
        .contextMenu { contextMenuContent }
        .focusable()
        .focused($isCardFocused)
        .onChange(of: isCardFocused) { _, isFocused in
            if isFocused {
                onSelect()
            }
        }
        .onKeyPress(.return) {
            guard !isProcessing else { return .ignored }
            // Let focused child elements handle their own activation
            guard !isMenuButtonFocused && !isNameFieldFocused && !isEmojiFieldFocused else { return .ignored }
            onOpen()
            return .handled
        }
        .onKeyPress(.space) {
            guard !isProcessing else { return .ignored }
            // Let focused child elements handle their own activation
            guard !isMenuButtonFocused && !isNameFieldFocused && !isEmojiFieldFocused else { return .ignored }
            onOpen()
            return .handled
        }
        .sheet(isPresented: $showingExportPanel) {
            ExportPanelView(document: document)
        }
    }

    // MARK: - Context Menu Content

    @ViewBuilder
    private var contextMenuContent: some View {
        Button("Rename…", systemImage: "pencil") {
            startEditing()
        }
        .disabled(isProcessing)

        Button("Export Project Text…", systemImage: "square.and.arrow.up") {
            showingExportPanel = true
        }
        .disabled(isProcessing)

        Divider()

        Text("Using \(document.formattedStorageSize)")

        Button("Optimize Images…", systemImage: "arrow.down.circle") {
            onOptimize()
        }
        .disabled(isProcessing)

        Divider()

        Button("Delete…", systemImage: "trash", role: .destructive) {
            onDelete()
        }
        .disabled(isProcessing)
    }

    // MARK: - Thumbnail Section

    private var thumbnailSection: some View {
        ZStack(alignment: .topTrailing) {
            // Main thumbnail with 8.5:11 aspect ratio (US Letter)
            ZStack {
                // Background
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.1))

                // Show processing indicator or thumbnail
                if isProcessing {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.regular)
                        Text("\(Int(ocrProgress * 100))%")
                            .font(.body)
                            .foregroundColor(.primary)
                    }
                } else if let lastPage = document.lastModifiedPage,
                          let thumbData = lastPage.thumbnailData,
                          let thumbnail = PlatformImage.from(data: thumbData) {
                    thumbnail
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .aspectRatio(8.5/11, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Menu Button

    private var menuButton: some View {
        Menu {
            contextMenuContent
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.title3)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .focused($isMenuButtonFocused)
        .accessibilityLabel("Project options")
        .accessibilityHint("Opens menu with rename, optimize, and delete options")
    }

    // MARK: - Title Section (with emoji to the left)

    private var titleSection: some View {
        HStack(alignment: .top, spacing: 8) {
            // Emoji/Icon button to the left of the title
            emojiIconButton

            // Title and metadata in a VStack, aligned with the title
            VStack(alignment: .leading, spacing: 4) {
                // Title (inline editable)
                Group {
                    if isEditingName {
                        TextField("Project Name", text: $editedName)
                            .textFieldStyle(.plain)
                            .font(.headline)
                            .focused($isNameFieldFocused)
                            .onSubmit { commitRename() }
                            .onExitCommand { cancelRename() }
                    } else {
                        Text(document.name)
                            .font(.headline)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                startEditing()
                            }
                    }
                }

                // Metadata below title
                metadataSection
            }
            // Project context menu on trailing
            menuButton
                .padding(.vertical, 2)
                .opacity(menuButtonVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: menuButtonVisible)
        }
    }

    // MARK: - Emoji/Icon Button

    private var emojiIconButton: some View {
        Button(action: { showingEmojiPopover = true }) {
            Group {
                if let emoji = document.emoji, !emoji.isEmpty {
                    Text(emoji)
                        .font(.title2)
                } else {
                    Image(systemName: "doc.text.fill")
                        .font(.title3)
                        .foregroundColor(.accentColor)
                }
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(isProcessing)
        .accessibilityLabel("Project icon")
        .accessibilityValue(document.emoji ?? "Default document icon")
        .accessibilityHint("Activate to change the project emoji")
        .popover(isPresented: $showingEmojiPopover) {
            emojiPickerPopover
        }
    }

    // MARK: - Emoji Picker Popover (Temporary Solution)
    // TODO: Replace with system emoji picker when SwiftUI provides native API

    private var emojiPickerPopover: some View {
        VStack(spacing: 12) {
            Text("Enter an emoji")
                .font(.headline)

            TextField("Emoji", text: $emojiInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                .multilineTextAlignment(.center)
                .focused($isEmojiFieldFocused)
                .accessibilityLabel("Enter emoji")
                .onChange(of: emojiInput) { _, newValue in
                    // Auto-accept when user types an emoji
                    if let firstChar = newValue.first, firstChar.isEmoji {
                        document.emoji = String(firstChar)
                        saveDocument()
                        emojiInput = ""
                        showingEmojiPopover = false
                    }
                }
                .onSubmit {
                    commitEmoji()
                }

            HStack(spacing: 8) {
                Button("Clear") {
                    document.emoji = nil
                    saveDocument()
                    emojiInput = ""
                    showingEmojiPopover = false
                }
                .buttonStyle(.bordered)

                Button("Done") {
                    commitEmoji()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(minWidth: 150)
        .onAppear {
            emojiInput = ""
            // Small delay to ensure popover is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusDelay) {
                isEmojiFieldFocused = true
            }
        }
    }

    private func commitEmoji() {
        if let firstChar = emojiInput.first, firstChar.isEmoji {
            document.emoji = String(firstChar)
            saveDocument()
        }
        emojiInput = ""
        showingEmojiPopover = false
    }

    private func startEditing() {
        guard !isProcessing else { return }
        editedName = document.name
        isEditingName = true
        // Delay to ensure TextField is mounted
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusDelay) {
            isNameFieldFocused = true
        }
    }

    private func commitRename() {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            document.name = trimmed
            saveDocument()
        }
        isEditingName = false
    }

    private func cancelRename() {
        isEditingName = false
        editedName = document.name
    }

    // MARK: - Metadata Section

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Last edited date (absolute format with timezone support)
            Text(document.lastModifiedDate, format: .dateTime.month(.wide).day().year().hour().minute())
                .font(.caption)
                .foregroundColor(.secondary)

            // Completion status
            Text("\(document.pages.filter { $0.isDone }.count) of \(document.totalPages) pages reviewed (\(document.completionPercentage)%)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Helpers

    private func saveDocument() {
        do {
            try modelContext.save()
        } catch {
            print("Failed to save document: \(error)")
        }
    }
}

// MARK: - Character Extension for Emoji Detection

extension Character {
    var isEmoji: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return scalar.properties.isEmoji && (scalar.value > 0x238C || unicodeScalars.count > 1)
    }
}

// MARK: - Previews

private struct DocumentCardPreviewHelper: View {
    let documentName: String
    let emoji: String
    let isProcessing: Bool
    let isSelected: Bool
    let locale: String

    var body: some View {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: Document.self, Page.self, configurations: config)

        let document = Document(name: documentName, totalPages: isProcessing ? 0 : 5)
        document.emoji = emoji
        if !isProcessing {
            document.cachedStorageBytes = 1_234_567
            (1...5).forEach { i in
                let page = Page(pageNumber: i, text: "Sample text for page \(i)", imageData: nil)
                page.isDone = i <= 2
                document.pages.append(page)
            }
        }

        container.mainContext.insert(document)

        return DocumentCard(
            document: document,
            isProcessing: isProcessing,
            ocrProgress: 0.99,
            isSelected: isSelected,
            onSelect: {},
            onOpen: {},
            onDelete: {},
            onOptimize: {}
        )
        .modelContainer(container)
        .environment(\.locale, Locale(identifier: locale))
        .padding()
        .frame(width: 250, height: 380)
    }
}

#Preview("English") {
    DocumentCardPreviewHelper(
        documentName: "Sample Project",
        emoji: "📄",
        isProcessing: false,
        isSelected: false,
        locale: "en"
    )
}

#Preview("es-419") {
    DocumentCardPreviewHelper(
        documentName: "Proyecto de ejemplo",
        emoji: "📄",
        isProcessing: false,
        isSelected: false,
        locale: "es-419"
    )
}

#Preview("Processing - English") {
    DocumentCardPreviewHelper(
        documentName: "Processing Document",
        emoji: "⏳",
        isProcessing: true,
        isSelected: false,
        locale: "en"
    )
}

#Preview("Processing - es-419") {
    DocumentCardPreviewHelper(
        documentName: "Procesando proyecto",
        emoji: "⏳",
        isProcessing: true,
        isSelected: false,
        locale: "es-419"
    )
}
