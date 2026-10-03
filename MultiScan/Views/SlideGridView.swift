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

    /// Position-aware callbacks for adding pages.
    /// `insertAfter` is the page number to insert after (0 = insert at beginning, nil = append to end).
    var onAddPhotos: ((_ insertAfter: Int?, _ items: [PhotosPickerItem]) -> Void)? = nil
    var onAddFiles: ((_ insertAfter: Int?, _ urls: [URL]) -> Void)? = nil

    @State private var searchText = ""
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false

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
                        // The pickers are presented from inside this sheet, so the insert callbacks stay local and hand the result up.
                        .pageContextMenu(
                            for: page,
                            in: document,
                            navigationState: navigationState,
                            onInsertFromPhotos: onAddPhotos == nil ? nil : { insertAfter in
                                insertTargetPageNumber = insertAfter
                                showPhotoPicker = true
                            },
                            onInsertFromFiles: onAddFiles == nil ? nil : { insertAfter in
                                insertTargetPageNumber = insertAfter
                                showFileImporter = true
                            }
                        )
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
            .searchable(text: $searchText, prompt: "Search")
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
        }
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
            Text(page.title)
                .font(.caption2)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(page.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif
