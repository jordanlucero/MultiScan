import SwiftUI
import SwiftData
import AppIntents

struct DocumentCard: View {
    @Bindable var document: Document
    let isProcessing: Bool
    let ocrProgress: Double
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onOptimize: () -> Void

    // Inline rename state. `editedName` lives in DocumentCardName
    @State private var isEditingName = false
    @FocusState private var isNameFieldFocused: Bool

    // Emoji picker state. `emojiInput` lives in DocumentCardEmojiButton.
    @FocusState private var isEmojiFieldFocused: Bool
    @FocusState private var isMenuButtonFocused: Bool

    // Hover state for menu button visibility
    @State private var isHovered = false

    // Keyboard focus state
    @FocusState private var isCardFocused: Bool

    // Export panel state
    @State private var showingExportPanel = false

    /// The ellipsis menu shows while the card is hovered or keyboard-focused (or the menu itself has focus).
    private var menuButtonVisible: Bool {
        isHovered || isCardFocused || isMenuButtonFocused
    }

    var body: some View {
        // Encompassing container
        VStack(spacing: 12) {
            DocumentCardThumbnail(
                document: document,
                isProcessing: isProcessing,
                ocrProgress: ocrProgress
            )

            HStack(alignment: .top, spacing: 8) {
                DocumentCardEmojiButton(
                    document: document,
                    isProcessing: isProcessing,
                    isFieldFocused: $isEmojiFieldFocused
                )

                VStack(alignment: .leading, spacing: 4) {
                    DocumentCardName(
                        document: document,
                        isEditing: $isEditingName,
                        isFieldFocused: $isNameFieldFocused,
                        onBeginEditing: startEditing
                    )
                    DocumentCardMetadata(document: document)
                }

                DocumentCardMenuButton(
                    document: document,
                    isProcessing: isProcessing,
                    isVisible: menuButtonVisible,
                    isFocused: $isMenuButtonFocused,
                    onRename: startEditing,
                    onExport: { showingExportPanel = true },
                    onOptimize: onOptimize,
                    onDelete: onDelete
                )
                .padding(.vertical, 2)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        #if os(iOS)
        // Touch: single tap opens the project
        .onTapGesture {
            guard !isProcessing else { return }
            openProject()
        }
        #else
        // Mac: double-click opens (single click selects/focuses)
        .onTapGesture(count: 2) {
            guard !isProcessing else { return }
            openProject()
        }
        #endif
        .contextMenu {
            DocumentCardActions(
                document: document,
                isProcessing: isProcessing,
                onRename: startEditing,
                onExport: { showingExportPanel = true },
                onOptimize: onOptimize,
                onDelete: onDelete
            )
        }
        .focusable()
        .focused($isCardFocused)
        .onKeyPress(.return) {
            guard !isProcessing else { return .ignored }
            // Let focused child elements handle their own activation
            guard !isMenuButtonFocused && !isNameFieldFocused && !isEmojiFieldFocused else { return .ignored }
            openProject()
            return .handled
        }
        .onKeyPress(.space) {
            guard !isProcessing else { return .ignored }
            // Let focused child elements handle their own activation
            guard !isMenuButtonFocused && !isNameFieldFocused && !isEmojiFieldFocused else { return .ignored }
            openProject()
            return .handled
        }
        .sheet(isPresented: $showingExportPanel) {
            ExportPanelView(document: document)
        }
        // Onscreen awareness: lets Siri/Apple Intelligence refer to a visible project.
        .appEntityIdentifier(document.uuid.map { EntityIdentifier(for: ProjectEntity.self, identifier: $0) })
    }

    private func startEditing() {
        guard !isProcessing else { return }
        isEditingName = true
    }

    /// Opens the project and donates the matching intent for predicition learning.
    private func openProject() {
        onOpen()
        guard let uuid = document.uuid else { return }
        Task {
            guard let entity = await ProjectStore.shared.projectEntity(uuid: uuid) else { return }
            let intent = OpenProjectIntent()
            intent.target = entity
            _ = try? await IntentDonationManager.shared.donate(intent: intent)
        }
    }
}

/// Delay before focusing text fields to ensure they're in the view hierarchy
private let focusDelay: TimeInterval = 0.1

// MARK: - Actions (shared by the context menu and the ellipsis menu)

struct DocumentCardActions: View {
    let document: Document
    let isProcessing: Bool
    let onRename: () -> Void
    let onExport: () -> Void
    let onOptimize: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button("Rename…", systemImage: "pencil") {
            onRename()
        }
        .disabled(isProcessing)

        Button("Export Project Text…", systemImage: "square.and.arrow.up") {
            onExport()
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
}

// MARK: - Thumbnail Section

struct DocumentCardThumbnail: View {
    let document: Document
    let isProcessing: Bool
    let ocrProgress: Double

    var body: some View {
        // Main thumbnail with 8.5:11 aspect ratio (US Letter)
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.1))

            // Show processing indicator or thumbnail
            if isProcessing {
                DocumentCardProgressIndicator(ocrProgress: ocrProgress)
            } else {
                DocumentCardPreviewImage(document: document)
            }
        }
        .aspectRatio(8.5/11, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Isolated so OCR progress ticks don't invalidate anything else on the card.
struct DocumentCardProgressIndicator: View {
    let ocrProgress: Double

    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.regular)
            Text(Int(ocrProgress * 100), format: .percent)
                .font(.body)
                .foregroundStyle(Color.primary)
        }
    }
}

/// Owns the `lastModifiedPage` scan and the thumbnail decode, so neither runs when the card invalidates for hover, focus, or rename.
struct DocumentCardPreviewImage: View {
    let document: Document

    var body: some View {
        if let lastPage = document.lastModifiedPage,
           let thumbData = lastPage.thumbnailData,
           let thumbnail = PlatformImage.from(data: thumbData) {
            thumbnail
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }
}

// MARK: - Menu Button

struct DocumentCardMenuButton: View {
    let document: Document
    let isProcessing: Bool
    let isVisible: Bool
    @FocusState.Binding var isFocused: Bool
    let onRename: () -> Void
    let onExport: () -> Void
    let onOptimize: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Menu {
            DocumentCardActions(
                document: document,
                isProcessing: isProcessing,
                onRename: onRename,
                onExport: onExport,
                onOptimize: onOptimize,
                onDelete: onDelete
            )
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.title3)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .focused($isFocused)
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isVisible)
        .accessibilityLabel("Project options")
        .accessibilityHint("Opens menu with rename, optimize, and delete options")
    }
}

// MARK: - Title (inline editable)

struct DocumentCardName: View {
    let document: Document
    @Binding var isEditing: Bool
    @FocusState.Binding var isFieldFocused: Bool
    let onBeginEditing: () -> Void

    @Environment(\.modelContext) private var modelContext

    /// Local to this view so each keystroke invalidates only the name field.
    @State private var editedName: String = ""

    var body: some View {
        if isEditing {
            TextField("Project Name", text: $editedName)
                .textFieldStyle(.plain)
                .font(.headline)
                .focused($isFieldFocused)
                .onSubmit { commitRename() }
            #if os(macOS)
                .onExitCommand { isEditing = false }
            #endif
                .onAppear {
                    editedName = document.name
                    // Delay to ensure the TextField is mounted before focusing
                    Task {
                        try? await Task.sleep(for: .seconds(focusDelay))
                        isFieldFocused = true
                    }
                }
        } else {
            Text(document.name)
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    onBeginEditing()
                }
        }
    }

    private func commitRename() {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            document.name = trimmed
            document.lastModified = Date()
            saveDocument(modelContext)
            MultiScanShortcuts.updateAppShortcutParameters()
        }
        isEditing = false
    }
}

// MARK: - Emoji/Icon Button

struct DocumentCardEmojiButton: View {
    let document: Document
    let isProcessing: Bool
    @FocusState.Binding var isFieldFocused: Bool

    @State private var showingPopover = false

    var body: some View {
        Button(action: { showingPopover = true }) {
            Group {
                if let emoji = document.emoji, !emoji.isEmpty {
                    Text(emoji)
                        .font(.title2)
                } else {
                    Image(systemName: "doc.text.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(isProcessing)
        .accessibilityLabel("Project icon")
        .accessibilityValue(document.emoji ?? "Default document icon")
        .accessibilityHint("Activate to change the project emoji")
        .popover(isPresented: $showingPopover) {
            DocumentCardEmojiPicker(
                document: document,
                isPresented: $showingPopover,
                isFieldFocused: $isFieldFocused
            )
        }
    }
}

// MARK: - Emoji Picker Popover (Temporary Solution)
// Replace with system emoji picker when SwiftUI provides native API

struct DocumentCardEmojiPicker: View {
    let document: Document
    @Binding var isPresented: Bool
    @FocusState.Binding var isFieldFocused: Bool

    @Environment(\.modelContext) private var modelContext

    /// Local to this view so typing doesn't invalidate the card.
    @State private var emojiInput: String = ""

    var body: some View {
        VStack(spacing: 12) {
            Text("Add an emoji")
                .font(.headline)

            TextField("Emoji", text: $emojiInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                .multilineTextAlignment(.center)
                .focused($isFieldFocused)
                .accessibilityLabel("Enter emoji")
                .onChange(of: emojiInput) { _, newValue in
                    // Auto-accept when user types an emoji
                    if let firstChar = newValue.first, firstChar.isEmoji {
                        setEmoji(String(firstChar))
                    }
                }
                .onSubmit {
                    commitEmoji()
                }

            HStack(spacing: 8) {
                Button("Clear") {
                    setEmoji(nil)
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
            Task {
                try? await Task.sleep(for: .seconds(focusDelay))
                isFieldFocused = true
            }
        }
    }

    private func commitEmoji() {
        if let firstChar = emojiInput.first, firstChar.isEmoji {
            setEmoji(String(firstChar))
        } else {
            emojiInput = ""
            isPresented = false
        }
    }

    private func setEmoji(_ emoji: String?) {
        document.emoji = emoji
        document.lastModified = Date()
        saveDocument(modelContext)
        emojiInput = ""
        isPresented = false
    }
}

// MARK: - Metadata Section

struct DocumentCardMetadata: View {
    let document: Document

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Last edited date (absolute format with timezone support)
            Text(document.lastModifiedDate, format: .dateTime.month(.wide).day().year().hour().minute())
                .font(.caption)
                .foregroundStyle(Color.secondary)

            // Completion status
            Text("\(document.unwrappedPages.filter { $0.isDone }.count) of \(document.totalPages) pages reviewed (\(document.completionPercentage, format: .percent))")
                .font(.caption)
                .foregroundStyle(Color.secondary)
        }
    }
}

// MARK: - Helpers

private func saveDocument(_ modelContext: ModelContext) {
    do {
        try modelContext.save()
    } catch {
        print("Failed to save document: \(error)")
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
    let locale: String

    var body: some View {
        let container = previewContainer()

        let document = Document(name: documentName, totalPages: isProcessing ? 0 : 5)
        document.emoji = emoji
        if !isProcessing {
            document.cachedStorageBytes = 1_234_567
            (1...5).forEach { i in
                let page = Page(pageNumber: i, text: "Sample text for page \(i)", imageData: nil)
                page.isDone = i <= 2
                document.pages?.append(page)
            }
        }

        container.mainContext.insert(document)

        return DocumentCard(
            document: document,
            isProcessing: isProcessing,
            ocrProgress: 0.99,
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
        locale: "en"
    )
}

#Preview("es-419") {
    DocumentCardPreviewHelper(
        documentName: "Proyecto de ejemplo",
        emoji: "📄",
        isProcessing: false,
        locale: "es-419"
    )
}

#Preview("Processing - English") {
    DocumentCardPreviewHelper(
        documentName: "Processing Document",
        emoji: "⏳",
        isProcessing: true,
        locale: "en"
    )
}

#Preview("Processing - es-419") {
    DocumentCardPreviewHelper(
        documentName: "Procesando proyecto",
        emoji: "⏳",
        isProcessing: true,
        locale: "es-419"
    )
}
