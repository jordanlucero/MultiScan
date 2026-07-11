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
    @ObservedObject var navigationState: NavigationState
    @Binding var selectedPageNumber: Int?
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

    private var sortedPages: [Page] {
        document.unwrappedPages.sorted { $0.pageNumber < $1.pageNumber }
    }

    private var filteredPages: [Page] {
        guard !searchText.isEmpty else { return sortedPages }
        let query = searchText.lowercased()
        return sortedPages.filter { page in
            let numberMatch = String(localized: "Page \(page.pageNumber)").lowercased().contains(query)
                || "\(page.pageNumber)".contains(query)
            let fileMatch = page.originalFileName?.lowercased().contains(query) ?? false
            let textMatch = page.plainText.lowercased().contains(query)
            return numberMatch || fileMatch || textMatch
        }
    }

    private var hasAddCallbacks: Bool {
        onAddPhotos != nil || onAddFiles != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(filteredPages) { page in
                        Button {
                            navigationState.goToPage(pageNumber: page.pageNumber)
                            selectedPageNumber = page.pageNumber
                            dismiss()
                        } label: {
                            thumbnailCell(for: page)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { contextMenu(for: page) }
                    }
                }
                .padding()
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
            .confirmationDialog(
                "Delete Page \(pageToDelete?.pageNumber ?? 0)?",
                isPresented: Binding(
                    get: { pageToDelete != nil },
                    set: { if !$0 { pageToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let page = pageToDelete {
                        withAnimation {
                            deletePage(page)
                        }
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
        guard let adjacent = document.unwrappedPages.first(where: { $0.pageNumber == page.pageNumber - 1 }) else { return }

        let originalPageNumber = page.pageNumber
        let adjacentPageNumber = adjacent.pageNumber

        let temp = page.pageNumber
        page.pageNumber = adjacent.pageNumber
        adjacent.pageNumber = temp

        TextExportCacheService.swapPageNumbers(originalPageNumber, adjacentPageNumber, in: document)
        navigationState.refreshPageOrder()
    }

    private func movePageDown(_ page: Page) {
        guard let adjacent = document.unwrappedPages.first(where: { $0.pageNumber == page.pageNumber + 1 }) else { return }

        let originalPageNumber = page.pageNumber
        let adjacentPageNumber = adjacent.pageNumber

        let temp = page.pageNumber
        page.pageNumber = adjacent.pageNumber
        adjacent.pageNumber = temp

        TextExportCacheService.swapPageNumbers(originalPageNumber, adjacentPageNumber, in: document)
        navigationState.refreshPageOrder()
    }

    // MARK: - Page Deletion

    private func deletePage(_ page: Page) {
        let deletedPageNumber = page.pageNumber

        TextExportCacheService.removeEntry(pageNumber: deletedPageNumber, from: document)

        for otherPage in document.unwrappedPages where otherPage.pageNumber > deletedPageNumber {
            otherPage.pageNumber -= 1
        }

        document.pages?.removeAll { $0.persistentModelID == page.persistentModelID }
        document.totalPages -= 1
        document.recalculateStorageSize()

        modelContext.delete(page)

        navigationState.refreshPageOrder()

        if navigationState.currentPageNumber == deletedPageNumber {
            let newPageNumber = min(deletedPageNumber, document.totalPages)
            if newPageNumber > 0 {
                navigationState.goToPage(pageNumber: newPageNumber)
            }
        }

        selectedPageNumber = navigationState.currentPageNumber
    }

    // MARK: - Thumbnail Cell

    @ViewBuilder
    private func thumbnailCell(for page: Page) -> some View {
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
                    if selectedPageNumber == page.pageNumber {
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
                .foregroundStyle(selectedPageNumber == page.pageNumber ? .primary : .secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Page \(page.pageNumber)")
        .accessibilityAddTraits(selectedPageNumber == page.pageNumber ? .isSelected : [])
    }
}
#endif
