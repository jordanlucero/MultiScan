//
//  DocumentCard.swift
//  MultiScan
//
//  Created by Claude Code on 12/27/25.
//

import SwiftUI
import SwiftData
import AppKit

struct DocumentCard: View {
    @Bindable var document: Document
    let isProcessing: Bool
    let ocrProgress: Double
    let onDelete: () -> Void
    let onOptimize: () -> Void

    @Environment(\.modelContext) private var modelContext

    // Inline rename state
    @State private var isEditingName = false
    @State private var editedName: String = ""
    @FocusState private var isNameFieldFocused: Bool

    // Emoji picker state
    @State private var isEditingEmoji = false
    @State private var emojiInput: String = ""
    @FocusState private var isEmojiFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnailSection
            titleSection
            metadataSection
        }
        .focusable()
        .contextMenu {
            contextMenuContent
        }
    }

    // MARK: - Context Menu Content

    @ViewBuilder
    private var contextMenuContent: some View {
        Button("Rename...", systemImage: "pencil") {
            startEditing()
        }
        .disabled(isProcessing)

        Divider()

        Text("Using \(document.formattedStorageSize)")

        Button("Optimize Images...", systemImage: "arrow.down.circle") {
            onOptimize()
        }
        .disabled(isProcessing)

        Divider()

        Button("Delete...", systemImage: "trash", role: .destructive) {
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
                   let nsImage = NSImage(data: thumbData) {
                    Image(nsImage: nsImage)
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

            // Ellipsis menu (top-right)
            menuButton
                .padding(8)

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
                .background(Circle().fill(.regularMaterial))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    // MARK: - Processing Overlay

    private var processingOverlay: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.black.opacity(0.5))
            .aspectRatio(8.5/11, contentMode: .fit)
            .overlay(
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("\(Int(ocrProgress * 100))%")
                        .font(.caption)
                        .foregroundColor(.white)
                }
            )
    }

    // MARK: - Title Section (with emoji to the left)

    private var titleSection: some View {
        HStack(alignment: .top, spacing: 8) {
            // Emoji/Icon button to the left of the title
            emojiIconButton

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
        }
    }

    // MARK: - Emoji/Icon Button

    private var emojiIconButton: some View {
        Button(action: { showEmojiPicker() }) {
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
        .overlay {
            // Hidden TextField to capture emoji input
            if isEditingEmoji {
                TextField("", text: $emojiInput)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .focused($isEmojiFocused)
                    .onChange(of: emojiInput) { _, newValue in
                        if let firstChar = newValue.first, firstChar.isEmoji {
                            document.emoji = String(firstChar)
                            saveDocument()
                            isEditingEmoji = false
                            emojiInput = ""
                        }
                    }
                    .onExitCommand {
                        isEditingEmoji = false
                        emojiInput = ""
                    }
            }
        }
    }

    private func showEmojiPicker() {
        isEditingEmoji = true
        emojiInput = ""

        // Small delay to ensure TextField is in view hierarchy
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isEmojiFocused = true
            NSApp.orderFrontCharacterPalette(nil)
        }
    }

    private func startEditing() {
        guard !isProcessing else { return }
        editedName = document.name
        isEditingName = true
        // Delay to ensure TextField is mounted
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
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

            // Completion percentage
            Text("\(document.completionPercentage)% pages reviewed")
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
