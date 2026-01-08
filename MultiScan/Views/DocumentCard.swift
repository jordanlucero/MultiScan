//
//  DocumentCard.swift
//  MultiScan
//
//  Created by Claude Code on 12/27/25.
//

import SwiftUI
import SwiftData

struct DocumentCard: View {
    @Bindable var document: Document
    let isProcessing: Bool
    let ocrProgress: Double
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

    // Hover and focus state for menu button visibility
    @State private var isHovered = false
    @FocusState private var isCardFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnailSection
            titleSection
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .focusable()
        .focused($isCardFocused)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {contextMenuContent}
    }

    // MARK: - Context Menu Content

    @ViewBuilder
    private var contextMenuContent: some View {
        Button("Rename…", systemImage: "pencil") {
            startEditing()
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

                // Thumbnail image or placeholder
                if let lastPage = document.lastModifiedPage,
                   let thumbData = lastPage.thumbnailData,
                   let thumbnail = PlatformImage.from(data: thumbData) {
                    thumbnail
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                } else {
                    Image(systemName: "doc.text.fill")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                }
            }
            .aspectRatio(8.5/11, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Ellipsis menu (top-right) - only visible on hover or keyboard focus
            menuButton
                .padding(8)
                .opacity(isHovered || isCardFocused ? 1 : 0)
                .shadow(color: .primary.opacity(0.8), radius: 2)

            // Processing overlay
            if isProcessing {
                processingOverlay
            }
        }
    }

    // MARK: - Menu Button

    private var menuButton: some View {
        Menu {
            contextMenuContent
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("Project options")
        .accessibilityHint("Opens menu with rename, optimize, and delete options")
    }

    // MARK: - Processing Overlay

    private var processingOverlay: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.black.opacity(0.75))
            .aspectRatio(8.5/11, contentMode: .fit)
            .overlay(
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("\(Int(ocrProgress * 100))%")
                        .font(.body)
                        .foregroundColor(.white)
                }
            )
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
