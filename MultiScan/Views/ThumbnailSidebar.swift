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

    /// What the page context menu can ask the review view to do (insert pages, capture artwork, separate / rejoin, read the text again).
    var actions = PageActions()

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
                    actions: actions
                )
            }
            .onChange(of: navigationState.currentPageNumber) { _, newValue in
                // The selection must never sit inside a folded chapter.
                navigationState.revealCurrentPage()
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

// MARK: - Chapter header

/// A chapter's header in the sidebar and the page grid: the title with a disclosure control that folds the chapter's pages away.
///
/// It is a `DisclosureGroup` used for its *label only* — the pages are not its content. They stay direct children of the enclosing lazy stack/grid `Section`, where they are created lazily and take part in drag reordering; putting them inside the disclosure group would make the whole chapter one eagerly-built child. What the group contributes is the platform's own disclosure control, its expand/collapse accessibility, and keyboard behavior.
///
/// Scrolls with the list (not pinned): a header that floats over the thumbnails is what this replaced.
struct ChapterDisclosureHeader: View {
    let title: String
    let pageCount: Int
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            EmptyView()
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                if !isExpanded {
                    // What is folded away, so a collapsed chapter still says how big it is.
                    Text("\(pageCount)", comment: "Number of pages in a collapsed chapter")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(pageCount == 1 ? "1 page" : "\(pageCount) pages")
                }
            }
            .contentShape(Rectangle())
        }
        // On iOS a disclosure group's label takes the accent tint, which makes a chapter title read like a link.
        .tint(.primary)
        .accessibilityAddTraits(.isHeader)
        .padding(.top, 6)
    }
}

// MARK: - Page List

/// The scrolling thumbnail column, in chapter sections. Takes an already-filtered page array so the filter doesn't re-run here, and keeps the reorder plumbing out of the sidebar's own body.
///
/// ## Reordering
/// The documented shape for a sectioned reorderable list: every section's `ForEach` is `.reorderable(collectionID:)` with the section's identity, inside one `.reorderContainer(for:in:isEnabled:move:)`. A drop therefore says which *chapter* it landed in as well as which page it landed before, and `NavigationState.applyReorder` moves the pages into that chapter (see `ChapterSections` for why chapters are containers). A folded chapter contributes no rows, so dragging past it is a short trip; drop on either side of its header to put a page before or after the chapter.
struct ThumbnailPageList: View {
    let pages: [Page]
    let document: Document
    let navigationState: NavigationState
    let isReorderEnabled: Bool
    var actions = PageActions()

    var body: some View {
        let currentPageNumber = navigationState.currentPageNumber
        let sections = ChapterSections.sections(for: pages)
        let collapsed = navigationState.collapsedChapters
        // One resolution of the numbering plan for the whole list (see `Document.printedPageLabels`).
        let printedLabels = document.printedPageLabels()

        LazyVStack(spacing: 10) {
            ForEach(sections) { section in
                Section {
                    if !collapsed.contains(section.id) {
                        ForEach(section.pages) { page in
                            ThumbnailView(
                                page: page,
                                isSelected: currentPageNumber == page.pageNumber,
                                printedLabel: printedLabels[page.pageNumber]
                            ) {
                                navigationState.goToPage(pageNumber: page.pageNumber)
                            }
                            .pageContextMenu(for: page, in: document, navigationState: navigationState, actions: actions)
                            .id(page.persistentModelID)  // Use stable model ID for animation
                        }
                        .reorderable(collectionID: section.id)
                    }
                } header: {
                    if let title = section.title {
                        ChapterDisclosureHeader(
                            title: title,
                            pageCount: section.pages.count,
                            isExpanded: Binding(
                                get: { !navigationState.isChapterCollapsed(section.id) },
                                set: { navigationState.setChapter(section.id, collapsed: !$0) }
                            )
                        )
                    }
                }
            }
        }
        .padding()
        .animation(.easeInOut(duration: 0.3), value: navigationState.pageOrderVersion)
        .animation(.snappy(duration: 0.25), value: collapsed)
        .reorderContainer(for: Page.self, in: PersistentIdentifier.self, isEnabled: isReorderEnabled) { difference in
            let targetID: PersistentIdentifier?
            switch difference.destination.position {
            case .before(let id): targetID = id
            case .end: targetID = nil
            }
            navigationState.applyReorder(of: difference.sources, toChapter: difference.destination.collectionID, before: targetID)
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
    /// The printed page number, resolved once for the whole list by the caller (`Document.printedPageLabels()`), not per cell.
    var printedLabel: String?
    var font: Font = .caption

    var body: some View {
        HStack(spacing: 4) {
            Text(page.title)
                .lineLimit(1)
                .truncationMode(.middle)
            if let printed = printedLabel {
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
    var printedLabel: String?
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

            PageLabelText(page: page, isSelected: isSelected, printedLabel: printedLabel)
        }
    }
}

#Preview("English") {
    let container = previewContainer()
    let document = Document(name: "Sample Document", totalPages: 5)
    let page1 = Page(pageNumber: 1, text: "Here's to the crazy ones.", imageData: nil, originalFileName: "page1.jpg")
    let page2 = Page(pageNumber: 2, text: "The misfits. The rebels. The troublemakers. The round pegs in the square holes.", imageData: nil, originalFileName: "page2.jpg")
    page2.isDone = true
    page2.sectionTitle = "Chapter One"
    let page3 = Page(pageNumber: 3, text: "The ones who see things differently.", imageData: nil, originalFileName: "page3.jpg")
    let page4 = Page(pageNumber: 4, text: "They're not fond of rules.", imageData: nil, originalFileName: "page4.jpg")
    page4.sectionTitle = "Chapter Two: A Longer Title That Wraps"
    let page5 = Page(pageNumber: 5, text: "And they have no respect for the status quo.", imageData: nil, originalFileName: "page5.jpg")
    document.pages = [page1, page2, page3, page4, page5]

    let navigationState = NavigationState()
    navigationState.setupNavigation(for: document)
    // The first chapter is folded, to show both states of the header.
    navigationState.setChapter(page2.persistentModelID, collapsed: true)

    return ThumbnailSidebar(document: document, navigationState: navigationState)
    .modelContainer(container)
    .environment(\.locale, Locale(identifier: "en"))
    .frame(width: 200, height: 760)
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
