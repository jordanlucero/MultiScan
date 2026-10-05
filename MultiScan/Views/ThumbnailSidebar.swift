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

    /// Callbacks for inserting pages at a position. The Int is the page number to insert after (0 = insert at beginning). The context menu offers them on iOS only.
    var onInsertFromPhotos: ((Int) -> Void)?
    var onInsertFromFiles: ((Int) -> Void)?
    /// Opens the artwork capture overlay for a page.
    var onCaptureArtwork: ((Page) -> Void)?
    /// Opens the Digest reading view.
    var onOpenDigest: (() -> Void)?
    /// Opens the project's page-numbering settings.
    var onEditPageNumbering: (() -> Void)?

    @AppStorage(DefaultsKey.filterOption) private var filterOptionString = "all"
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
                ThumbnailPageList(
                    pages: pages,
                    document: document,
                    navigationState: navigationState,
                    isReorderEnabled: !isAnyFilterActive,
                    onInsertFromPhotos: onInsertFromPhotos,
                    onInsertFromFiles: onInsertFromFiles,
                    onCaptureArtwork: onCaptureArtwork
                )
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
            .safeAreaInset(edge: .top, spacing: 0) {
                // Project-level actions live above the list: Digest and page numbering.
                SidebarProjectActions(
                    document: document,
                    onOpenDigest: onOpenDigest,
                    onEditPageNumbering: onEditPageNumbering,
                    onDetectChapters: { ChapterDetector.apply(to: document); navigationState.refreshPageOrder() }
                )
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

// MARK: - Project actions

/// Digest / numbering / chapters, as a compact row at the top of the sidebar. A `Menu` keeps it to one row at the sidebar's minimum width.
struct SidebarProjectActions: View {
    let document: Document
    var onOpenDigest: (() -> Void)?
    var onEditPageNumbering: (() -> Void)?
    var onDetectChapters: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if let onOpenDigest {
                Button(action: onOpenDigest) {
                    Label("Digest", systemImage: "book.pages")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Read the whole project as one continuous text")
            }

            Spacer()

            Menu {
                if let onEditPageNumbering {
                    Button("Page Numbering…", systemImage: "number") { onEditPageNumbering() }
                }
                if let onDetectChapters {
                    Button("Detect Chapters", systemImage: "list.bullet.indent") { onDetectChapters() }
                }
                if !document.chapterStartPages.isEmpty {
                    Text("\(document.chapterStartPages.count) chapters", comment: "Sidebar project menu: chapter count")
                }
            } label: {
                Label("Project", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuIndicator(.hidden)
            #if os(macOS)
            .menuStyle(.borderlessButton)
            .fixedSize()
            #endif
            .accessibilityLabel("Project options")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Chapter grouping

/// Splits an ordered page list into chapter groups: a page with a `sectionTitle` starts a new group; pages before the first chapter form an untitled group.
enum ChapterGrouping {
    struct Group: Identifiable {
        /// Stable across filter changes: the first page's identity.
        let id: PersistentIdentifier
        let title: String?
        var pages: [Page]
    }

    static func groups(for pages: [Page]) -> [Group] {
        var groups: [Group] = []
        for page in pages {
            if let title = page.sectionTitle, !title.isEmpty {
                groups.append(Group(id: page.persistentModelID, title: title, pages: [page]))
            } else if groups.isEmpty {
                groups.append(Group(id: page.persistentModelID, title: nil, pages: [page]))
            } else {
                groups[groups.count - 1].pages.append(page)
            }
        }
        return groups
    }
}

/// Sticky chapter header in the sidebar / page grid.
struct ChapterSectionHeader: View {
    let title: String
    let startPage: Page?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bookmark.fill")
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
            Spacer()
            if let startPage, startPage.sectionTitleIsAutomatic {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Detected automatically")
                    .accessibilityLabel("Detected automatically")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Page List

/// The scrolling thumbnail column, grouped by chapter. Takes an already-filtered page array so the filter doesn't re-run here, and keeps the reorder plumbing out of the sidebar's own body.
struct ThumbnailPageList: View {
    let pages: [Page]
    let document: Document
    let navigationState: NavigationState
    let isReorderEnabled: Bool
    var onInsertFromPhotos: ((Int) -> Void)?
    var onInsertFromFiles: ((Int) -> Void)?
    var onCaptureArtwork: ((Page) -> Void)?

    var body: some View {
        let currentPageNumber = navigationState.currentPageNumber
        let groups = ChapterGrouping.groups(for: pages)

        LazyVStack(spacing: 10, pinnedViews: [.sectionHeaders]) {
            ForEach(groups) { group in
                Section {
                    ForEach(group.pages) { page in
                        ThumbnailView(page: page, isSelected: currentPageNumber == page.pageNumber) {
                            navigationState.goToPage(pageNumber: page.pageNumber)
                        }
                        .pageContextMenu(
                            for: page,
                            in: document,
                            navigationState: navigationState,
                            onInsertFromPhotos: onInsertFromPhotos,
                            onInsertFromFiles: onInsertFromFiles,
                            onCaptureArtwork: onCaptureArtwork
                        )
                        .id(page.persistentModelID)  // Use stable model ID for animation
                    }
                    .reorderable()
                } header: {
                    if let title = group.title {
                        ChapterSectionHeader(title: title, startPage: group.pages.first)
                    }
                }
            }
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

    var body: some View {
        HStack(spacing: 8) {
            PageStatusFilterMenu(
                filterOptionString: $filterOptionString,
                visiblePageCount: visiblePageCount,
                totalPageCount: totalPageCount
            )

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

// MARK: - Page label

/// "Page 5" plus the printed page number ("p. iv") when the project has printed numbering configured. Shared by the sidebar and the compact grid.
struct PageLabelText: View {
    let page: Page
    let isSelected: Bool
    var font: Font = .caption

    var body: some View {
        HStack(spacing: 4) {
            Text(page.title)
                .lineLimit(1)
                .truncationMode(.middle)
            if let printed = page.printedPageLabel {
                Text("· p. \(printed)", comment: "Printed page number next to the project page number")
                    .lineLimit(1)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(font)
        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        .accessibilityHidden(true)
    }
}

// MARK: - Thumbnail

/// One page thumbnail with its label. The context menu is attached by the list (`pageContextMenu`).
struct ThumbnailView: View {
    let page: Page
    let isSelected: Bool
    let action: () -> Void

    /// Cross-platform thumbnail using PlatformImage helper with user rotation applied
    private var thumbnail: Image? {
        guard let data = page.thumbnailData else { return nil }
        return PlatformImage.from(data: data, userRotation: page.rotation)
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

                    if let thumbnail {
                        thumbnail
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .contrast(page.increaseContrast ? 1.3 : 1.0)
                            .brightness(page.increaseBlackPoint ? -0.1 : 0.0)
                            .padding(4)
                    } else {
                        // Placeholder for pages without thumbnails
                        Image("custom.document.badge.questionmark")
                            .font(.largeTitle)
                            .foregroundStyle(Color.secondary)
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

                    // Draft illustrations on this page: the reviewer's cue that a rescan is pending.
                    if page.unwrappedCaptures.contains(where: \.isDraft) {
                        VStack {
                            Spacer()
                            HStack {
                                Image(systemName: "flag.fill")
                                    .font(.caption)
                                    .foregroundStyle(.white)
                                    .padding(4)
                                    .background(.orange, in: Circle())
                                    .padding(8)
                                Spacer()
                            }
                        }
                        .accessibilityLabel("Has draft illustrations")
                    }
                }
                .aspectRatio(8.5/11, contentMode: .fit)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(page.title)
            .accessibilityValue(page.isDone
                ? String(localized: "Reviewed", comment: "Accessibility value for reviewed page")
                : String(localized: "Not reviewed", comment: "Accessibility value for unreviewed page"))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityHint(String(localized: "Opens this page", comment: "Accessibility hint for page thumbnail button"))

            PageLabelText(page: page, isSelected: isSelected)
        }
    }
}

#Preview("English") {
    let container = previewContainer()
    let document = Document(name: "Sample Document", totalPages: 3)
    let page1 = Page(pageNumber: 1, text: "Here's to the crazy ones.", imageData: nil, originalFileName: "page1.jpg")
    let page2 = Page(pageNumber: 2, text: "The misfits. The rebels. The troublemakers. The round pegs in the square holes.", imageData: nil, originalFileName: "page2.jpg")
    page2.isDone = true
    page2.sectionTitle = "Chapter One"
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
