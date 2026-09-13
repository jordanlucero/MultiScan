import SwiftUI
import SwiftData

#if os(macOS)
private let searchBarEdge: VerticalEdge = .bottom
#else
private let searchBarEdge: VerticalEdge = .top
#endif

struct ThumbnailSidebar: View {
    let document: Document
    let navigationState: NavigationState

    #if os(iOS)
    /// Callbacks for inserting pages at a position (iOS only).
    /// The Int is the page number to insert after (0 = insert at beginning).
    var onInsertFromPhotos: ((Int) -> Void)?
    var onInsertFromFiles: ((Int) -> Void)?
    #endif

    @AppStorage("filterOption") private var filterOptionString = "all"
    @State private var searchText = ""
    @State private var textFilterAnnounceTask: Task<Void, Never>?

    private var filterOption: PageFilterOption {
        PageFilterOption(rawValue: filterOptionString) ?? .all
    }

    private var isFilterActive: Bool {
        filterOption != .all
    }

    private var isAnyFilterActive: Bool {
        isFilterActive || !searchText.isEmpty
    }

    /// Total number of pages in the document
    private var totalPageCount: Int {
        document.unwrappedPages.count
    }

    /// Builds a descriptive string for the current filter state
    private var filterDescription: String {
        var parts: [String] = []

        if isFilterActive {
            parts.append(String(localized: "status: \(String(localized: filterOption.label))", comment: "Part of a VoiceOver filter announcement"))
        }

        if !searchText.isEmpty {
            parts.append(String(localized: "text: \"\(searchText)\"", comment: "Part of a VoiceOver filter announcement"))
        }

        if parts.isEmpty {
            return String(localized: "No filter active")
        }

        let separator = String(localized: " and ", comment: "Separator joining parts of the filter announcement")
        return String(localized: "Filtered by \(parts.joined(separator: separator))")
    }

    /// Announces filter changes to VoiceOver users
    private func announceFilterChange() {
        let visible = filteredPages.count
        let total = totalPageCount

        if !isAnyFilterActive {
            AccessibilityNotification.Announcement(String(localized: "Filter cleared. Showing all \(total) pages.")).post()
        } else {
            let description = filterDescription
            AccessibilityNotification.Announcement(String(localized: "\(description). Showing \(visible) of \(total) pages.")).post()
        }
    }

    var filteredPages: [Page] {
        // Reference pageOrderVersion to trigger re-computation when page order changes
        _ = navigationState.pageOrderVersion
        return PageFilter.apply(to: document.unwrappedPages, option: filterOption, searchText: searchText)
    }
    
    var body: some View {
        // Filter once per body evaluation. Reading `filteredPages` from the ForEach, the visible-page count, and the scroll-to handler ran the whole filter three times on every keystroke and page change.
        let pages = filteredPages

        ScrollViewReader { proxy in
            ScrollView {
                #if os(iOS)
                ThumbnailPageList(
                    pages: pages,
                    document: document,
                    navigationState: navigationState,
                    isReorderEnabled: !isAnyFilterActive,
                    onInsertFromPhotos: onInsertFromPhotos,
                    onInsertFromFiles: onInsertFromFiles
                )
                #else
                ThumbnailPageList(
                    pages: pages,
                    document: document,
                    navigationState: navigationState,
                    isReorderEnabled: !isAnyFilterActive
                )
                #endif
            }
            .onChange(of: navigationState.currentPageNumber) { _, newValue in
                // Scroll to page by finding its stable ID
                if let pageNumber = newValue,
                   let page = pages.first(where: { $0.pageNumber == pageNumber }) {
                    withAnimation {
                        proxy.scrollTo(page.persistentModelID, anchor: .center)
                    }
                }
            }
            .safeAreaInset(edge: searchBarEdge, spacing: 0) {
                ThumbnailFilterBar(
                    filterOptionString: $filterOptionString,
                    searchText: $searchText,
                    visiblePageCount: pages.count,
                    totalPageCount: totalPageCount
                )
            }
            .onChange(of: filterOptionString) { _, _ in
                // Announce immediately when status filter changes
                announceFilterChange()
                // Sync to NavigationState for filtered navigation
                navigationState.activeStatusFilter = filterOption
            }
            .onChange(of: searchText) { _, newValue in
                // Sync to NavigationState immediately for filtered navigation
                navigationState.activeSearchText = newValue
                // Debounce text filter announcements to avoid announcing on every keystroke
                textFilterAnnounceTask?.cancel()
                textFilterAnnounceTask = Task {
                    do {
                        // Wait for typing to stop (0.8 seconds)
                        try await Task.sleep(for: .milliseconds(800))
                        announceFilterChange()
                    } catch {
                        // Task was cancelled, no announcement needed
                    }
                }
            }
            .onAppear {
                // Initial sync of filter state to NavigationState
                navigationState.activeStatusFilter = filterOption
                navigationState.activeSearchText = searchText
            }
        }
    }
}

// MARK: - Page List

/// The scrolling thumbnail column. Takes an already-filtered page array so the filter doesn't re-run here, and keeps the reorder plumbing out of the sidebar's own body.
struct ThumbnailPageList: View {
    let pages: [Page]
    let document: Document
    let navigationState: NavigationState
    let isReorderEnabled: Bool

    #if os(iOS)
    var onInsertFromPhotos: ((Int) -> Void)?
    var onInsertFromFiles: ((Int) -> Void)?
    #endif

    var body: some View {
        let currentPageNumber = navigationState.currentPageNumber

        LazyVStack(spacing: 10) {
            ForEach(pages) { page in
                #if os(iOS)
                ThumbnailView(
                    page: page,
                    document: document,
                    isSelected: currentPageNumber == page.pageNumber,
                    navigationState: navigationState,
                    onInsertFromPhotos: onInsertFromPhotos,
                    onInsertFromFiles: onInsertFromFiles
                ) {
                    navigationState.goToPage(pageNumber: page.pageNumber)
                }
                .id(page.persistentModelID)  // Use stable model ID for animation
                #else
                ThumbnailView(
                    page: page,
                    document: document,
                    isSelected: currentPageNumber == page.pageNumber,
                    navigationState: navigationState
                ) {
                    navigationState.goToPage(pageNumber: page.pageNumber)
                }
                .id(page.persistentModelID)  // Use stable model ID for animation
                #endif
            }
            .reorderable()
        }
        .padding()
        .animation(.easeInOut(duration: 0.3), value: navigationState.pageOrderVersion)
        .reorderContainer(for: Page.self, isEnabled: isReorderEnabled) { difference in
            let targetID: PersistentIdentifier?
            switch difference.destination.position {
            case .before(let id): targetID = id
            case .end: targetID = nil
            }
            navigationState.applyReorder(of: difference.sources, before: targetID)
        }
    }
}

// MARK: - Filter Bar

/// Status filter + text search. Its inputs are just the filter state and the two counts, so page navigation and reordering don't rebuild its localized strings.
struct ThumbnailFilterBar: View {
    @Binding var filterOptionString: String
    @Binding var searchText: String
    let visiblePageCount: Int
    let totalPageCount: Int

    private var filterOption: PageFilterOption {
        PageFilterOption(rawValue: filterOptionString) ?? .all
    }

    private var isFilterActive: Bool {
        filterOption != .all
    }

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Picker(selection: $filterOptionString, label: Text("Filter by status")) {
                    ForEach(PageFilterOption.allCases, id: \.self) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
            }
            .menuStyle(.borderlessButton)
            .background {
                Capsule()
                    .fill(isFilterActive ? Color.accentColor : .clear)
                    .stroke(.tertiary.opacity(isFilterActive ? 0 : 1), lineWidth: 1)
            }
            .fixedSize()
            .accessibilityLabel("Filter by status")
            .accessibilityValue(isFilterActive
                ? "\(String(localized: filterOption.label)), \(visiblePageCount) of \(totalPageCount) pages visible"
                : "All \(totalPageCount) pages")
            .help(isFilterActive ? "Filtering: \(String(localized: filterOption.label))" : "Filter pages")

            TextField("Search project", text: $searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search project")
                .accessibilityHint("Search by page number, filename, or content")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear text filter")
                .help("Clear search filter")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassEffect()
        .padding(8)
    }
}

struct ThumbnailView: View {
    let page: Page
    let document: Document
    let isSelected: Bool
    var navigationState: NavigationState?
    #if os(iOS)
    /// Callbacks for inserting pages at a position (iOS only).
    var onInsertFromPhotos: ((Int) -> Void)?
    var onInsertFromFiles: ((Int) -> Void)?
    #endif
    let action: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var showDeleteConfirmation = false

    /// Cross-platform thumbnail using PlatformImage helper with user rotation applied
    var thumbnail: Image? {
        guard let data = page.thumbnailData else { return nil }
        return PlatformImage.from(data: data, userRotation: page.rotation)
    }

    // MARK: - Reordering Helpers

    /// Whether this page can be moved up (has an adjacent page with pageNumber - 1)
    private var canMoveUp: Bool {
        document.unwrappedPages.contains { $0.pageNumber == page.pageNumber - 1 }
    }

    /// Whether this page can be moved down (has an adjacent page with pageNumber + 1)
    private var canMoveDown: Bool {
        document.unwrappedPages.contains { $0.pageNumber == page.pageNumber + 1 }
    }

    /// Move this page up one slot (undoable, goes through NavigationState)
    private func movePageUp() {
        navigationState?.movePage(page, by: -1)
    }

    /// Move this page down one slot (undoable, goes through NavigationState)
    private func movePageDown() {
        navigationState?.movePage(page, by: 1)
    }

    /// Delete this page from the document
    private func deletePage() {
        navigationState?.deletePage(page, modelContext: modelContext)
    }

    /// Formatted page label: "Page X"
    var pageLabel: String {
        String(localized: "Page \(page.pageNumber)",
               comment: "Thumbnail label with page number")
    }

    var body: some View {
        VStack(spacing: 4) {
            Button(action: action) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                        )

                    if let thumbnail = thumbnail {
                        thumbnail
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .contrast(page.increaseContrast ? 1.3 : 1.0)
                            .brightness(page.increaseBlackPoint ? -0.1 : 0.0)
                            .padding(4)
                    } else {
                        // Placeholder for pages without thumbnails
                        VStack {
                            Image("custom.document.badge.questionmark")
                                .font(.largeTitle)
                                .foregroundStyle(Color.secondary)
                        }
                    }

                    if page.isDone {
                        VStack {
                            HStack {
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(Color.green)
                                    .background(Circle().fill(Color.white).padding(-2))
                                    .padding(8)
                            }
                            Spacer()
                        }
                    }
                }
                .aspectRatio(8.5/11, contentMode: .fit)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(pageLabel)
            .accessibilityValue(page.isDone
                ? String(localized: "Reviewed", comment: "Accessibility value for reviewed page")
                : String(localized: "Not reviewed", comment: "Accessibility value for unreviewed page"))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityHint(String(localized: "Opens this page", comment: "Accessibility hint for page thumbnail button"))
            .contextMenu {
                // MARK: - Page Info Header
                Section {
                    Text("Page \(page.pageNumber) of \(document.totalPages)")
                    if let filename = page.originalFileName {
                        Text(filename)
                            .foregroundStyle(.secondary)
                    }
                }

                // MARK: - Export Section
                Section {
                    ShareLink(item: RichText(page.attributedText),
                              preview: SharePreview(String(localized: "Page \(page.pageNumber) Text"))) {
                        Label("Export Page Text…", systemImage: "square.and.arrow.up")
                    }
                }

                // MARK: - Rotation Section
                Section {
                    PageRotationButtons(page: page)
                }

                // MARK: - Adjustments Section
                Section {
                    PageAdjustmentToggles(page: page)
                }

                // MARK: - Reordering Section
                Section {
                    Button {
                        movePageUp()
                    } label: {
                        Label("Move Page Up", systemImage: "arrow.up")
                    }
                    .disabled(!canMoveUp)

                    Button {
                        movePageDown()
                    } label: {
                        Label("Move Page Down", systemImage: "")
                    }
                    .disabled(!canMoveDown)
                }

                #if os(iOS)
                // MARK: - Insert Pages Section (iOS only)
                if onInsertFromPhotos != nil || onInsertFromFiles != nil {
                    Section {
                        Menu {
                            if let onInsertFromPhotos {
                                Button("From Photos…", systemImage: "photo.on.rectangle") {
                                    onInsertFromPhotos(page.pageNumber - 1)
                                }
                            }
                            if let onInsertFromFiles {
                                Button("From Files…", systemImage: "folder") {
                                    onInsertFromFiles(page.pageNumber - 1)
                                }
                            }
                        } label: {
                            Label("Insert Pages Before", systemImage: "doc.badge.plus")
                        }

                        Menu {
                            if let onInsertFromPhotos {
                                Button("From Photos…", systemImage: "photo.on.rectangle") {
                                    onInsertFromPhotos(page.pageNumber)
                                }
                            }
                            if let onInsertFromFiles {
                                Button("From Files…", systemImage: "folder") {
                                    onInsertFromFiles(page.pageNumber)
                                }
                            }
                        } label: {
                            Label("Insert Pages After", systemImage: "doc.badge.plus")
                        }
                    }
                }
                #endif

                // MARK: - Delete Section
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete Page…", systemImage: "trash")
                    }
                    .disabled(document.totalPages <= 1)
                }
            }
            .deletePageConfirmation(isPresented: $showDeleteConfirmation, pageNumber: page.pageNumber) {
                withAnimation {
                    deletePage()
                }
            }

            Text(pageLabel)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
        }
    }
}

#Preview("English") {
    let container = previewContainer()
    let document = Document(name: "Sample Document", totalPages: 3)
    let page1 = Page(pageNumber: 1, text: "Here's to the crazy ones.", imageData: nil, originalFileName: "page1.jpg")
    let page2 = Page(pageNumber: 2, text: "The misfits. The rebels. The troublemakers. The round pegs in the square holes.", imageData: nil, originalFileName: "page2.jpg")
    page2.isDone = true
    let page3 = Page(pageNumber: 3, text: "The ones who see things differently.", imageData: nil, originalFileName: "page3.jpg")
    document.pages = [page1, page2, page3]

    let navigationState = NavigationState()
    navigationState.setupNavigation(for: document)

    return ThumbnailSidebar(document: document, navigationState: navigationState)
    .modelContainer(container)
    .environment(\.locale, Locale(identifier: "en"))
    .frame(width: 200, height: 600)
}

#Preview("es-419") {
    let container = previewContainer()
    let document = Document(name: "Documento de Ejemplo", totalPages: 3)
    let page1 = Page(pageNumber: 1, text: "Texto de ejemplo para la página 1", imageData: nil, originalFileName: "pagina1.jpg")
    let page2 = Page(pageNumber: 2, text: "Texto de ejemplo para la página 2", imageData: nil, originalFileName: "pagina2.jpg")
    page2.isDone = true
    let page3 = Page(pageNumber: 3, text: "Texto de ejemplo para la página 3", imageData: nil, originalFileName: "pagina3.jpg")
    document.pages = [page1, page2, page3]

    let navigationState = NavigationState()
    navigationState.setupNavigation(for: document)

    return ThumbnailSidebar(document: document, navigationState: navigationState)
    .modelContainer(container)
    .environment(\.locale, Locale(identifier: "es-419"))
    .frame(width: 200, height: 600)
}

