//
//  SlideGridView.swift
//  MultiScan
//
//  Searchable page grid presented as a sheet in the compact (iPhone) layout.

#if os(iOS)
import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

struct SlideGridView: View {
    let document: Document
    let navigationState: NavigationState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    /// Position-aware callbacks for adding pages.
    /// `insertAfter` is the page number to insert after (0 = insert at beginning, nil = append to end).
    var onAddPhotos: ((_ insertAfter: Int?, _ items: [PhotosPickerItem]) -> Void)? = nil
    var onAddFiles: ((_ insertAfter: Int?, _ urls: [URL]) -> Void)? = nil

    @State private var searchText = ""
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var pageToDelete: Page?

    /// Tracks where new pages should be inserted (nil = append to end)
    @State private var insertTargetPageNumber: Int?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var filteredPages: [Page] {
        PageFilter.apply(to: document.unwrappedPages, searchText: searchText)
    }

    private var hasAddCallbacks: Bool {
        onAddPhotos != nil || onAddFiles != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                let currentPageNumber = navigationState.currentPageNumber

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(filteredPages) { page in
                        Button {
                            navigationState.goToPage(pageNumber: page.pageNumber)
                            dismiss()
                        } label: {
                            SlideGridCell(page: page, isSelected: currentPageNumber == page.pageNumber)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { contextMenu(for: page) }
                    }
                    .reorderable()
                }
                .padding()
                .reorderContainer(for: Page.self, isEnabled: searchText.isEmpty) { difference in
                    let targetID: PersistentIdentifier?
                    switch difference.destination.position {
                    case .before(let id): targetID = id
                    case .end: targetID = nil
                    }
                    navigationState.applyReorder(of: difference.sources, before: targetID)
                }
            }
            .searchable(text: $searchText, prompt: "Search pages")
            .navigationTitle("Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if hasAddCallbacks {
                    ToolbarItem(placement: .navigation) {
                        Menu {
                            if onAddPhotos != nil {
                                Button {
                                    insertTargetPageNumber = nil
                                    showPhotoPicker = true
                                } label: {
                                    Label("From Photos…", systemImage: "photo.on.rectangle")
                                }
                            }
                            if onAddFiles != nil {
                                Button {
                                    insertTargetPageNumber = nil
                                    showFileImporter = true
                                } label: {
                                    Label("From Files…", systemImage: "folder")
                                }
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(.glassProminent)
                }
            }
            .presentationDetents([.medium, .large])
            .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotos, matching: .images)
            .onChange(of: selectedPhotos) { _, items in
                guard !items.isEmpty else { return }
                onAddPhotos?(insertTargetPageNumber, items)
                selectedPhotos = []
                insertTargetPageNumber = nil
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.image, .pdf, .folder],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    onAddFiles?(insertTargetPageNumber, urls)
                }
                insertTargetPageNumber = nil
            }
            .deletePageConfirmation(
                isPresented: Binding(
                    get: { pageToDelete != nil },
                    set: { if !$0 { pageToDelete = nil } }
                ),
                pageNumber: pageToDelete?.pageNumber ?? 0
            ) {
                if let page = pageToDelete {
                    withAnimation {
                        navigationState.deletePage(page, modelContext: modelContext)
                    }
                }
            }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenu(for page: Page) -> some View {
        let canMoveUp = document.unwrappedPages.contains { $0.pageNumber == page.pageNumber - 1 }
        let canMoveDown = document.unwrappedPages.contains { $0.pageNumber == page.pageNumber + 1 }

        // Add before/after (only when add callbacks are provided)
        if hasAddCallbacks {
            Menu("Add Page Before…") {
                if onAddPhotos != nil {
                    Button("Import from Photos…", systemImage: "photo.on.rectangle") {
                        insertTargetPageNumber = page.pageNumber - 1
                        showPhotoPicker = true
                    }
                }
                if onAddFiles != nil {
                    Button("Import from Files…", systemImage: "folder") {
                        insertTargetPageNumber = page.pageNumber - 1
                        showFileImporter = true
                    }
                }
            }

            Menu("Add Page After…") {
                if onAddPhotos != nil {
                    Button("Import from Photos…", systemImage: "photo.on.rectangle") {
                        insertTargetPageNumber = page.pageNumber
                        showPhotoPicker = true
                    }
                }
                if onAddFiles != nil {
                    Button("Import from Files…", systemImage: "folder") {
                        insertTargetPageNumber = page.pageNumber
                        showFileImporter = true
                    }
                }
            }

            Divider()
        }

        Section {
            Button {
                movePageUp(page)
            } label: {
                Label("Move Before", systemImage: "arrow.up")
            }
            .disabled(!canMoveUp)

            Button {
                movePageDown(page)
            } label: {
                Label("Move After", systemImage: "arrow.down")
            }
            .disabled(!canMoveDown)
        }

        Section {
            Button(role: .destructive) {
                pageToDelete = page
            } label: {
                Label("Delete Page…", systemImage: "trash")
            }
            .disabled(document.totalPages <= 1)
        }
    }

    // MARK: - Page Reordering

    private func movePageUp(_ page: Page) {
        navigationState.movePage(page, by: -1)
    }

    private func movePageDown(_ page: Page) {
        navigationState.movePage(page, by: 1)
    }

}

// MARK: - Thumbnail Cell

/// Its own View type so a grid cell re-decodes its thumbnail only when that page or its selection changes — not on every search keystroke or reorder.
struct SlideGridCell: View {
    let page: Page
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                // Thumbnail image
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(0.1))

                    if let thumbData = page.thumbnailData,
                       let thumbnail = PlatformImage.from(data: thumbData) {
                        thumbnail
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                }
                .aspectRatio(8.5/11, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.accentColor, lineWidth: 2)
                    }
                }

                // Done indicator
                if page.isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .padding(4)
                }
            }

            // Label
            Text("Page \(page.pageNumber)")
                .font(.caption2)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Page \(page.pageNumber)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif
