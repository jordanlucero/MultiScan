import SwiftUI
import SwiftData

#if os(macOS)
private let searchBarEdge: VerticalEdge = .bottom
#else
private let searchBarEdge: VerticalEdge = .top
#endif

struct ThumbnailSidebar: View {
    let document: Document
    @ObservedObject var navigationState: NavigationState
    @Binding var selectedPageNumber: Int?

    enum FilterOption: String, CaseIterable {
        case all
        case done
        case notDone

        var label: LocalizedStringResource {
            switch self {
            case .all: "All"
            case .done: "Reviewed"
            case .notDone: "Not Reviewed"
            }
        }
    }

    @AppStorage("filterOption") private var filterOptionString = "all"
    @State private var searchText = ""
    @State private var textFilterAnnounceTask: Task<Void, Never>?

    private var filterOption: FilterOption {
        get { FilterOption(rawValue: filterOptionString) ?? .all }
        set { filterOptionString = newValue.rawValue }
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

    /// Number of pages currently visible after filtering
    private var visiblePageCount: Int {
        filteredPages.count
    }

    /// Builds a descriptive string for the current filter state
    private var filterDescription: String {
        var parts: [String] = []

        if isFilterActive {
            parts.append("status: \(String(localized: filterOption.label))")
        }

        if !searchText.isEmpty {
            parts.append("text: \"\(searchText)\"")
        }

        if parts.isEmpty {
            return "No filter active"
        }

        return "Filtered by \(parts.joined(separator: " and "))"
    }

    /// Announces filter changes to VoiceOver users
    private func announceFilterChange() {
        let visible = visiblePageCount
        let total = totalPageCount

        if !isAnyFilterActive {
            AccessibilityNotification.Announcement("Filter cleared. Showing all \(total) pages.").post()
        } else {
            let description = filterDescription
            AccessibilityNotification.Announcement("\(description). Showing \(visible) of \(total) pages.").post()
        }
    }

    var filteredPages: [Page] {
        // Reference pageOrderVersion to trigger re-computation when page order changes
        _ = navigationState.pageOrderVersion
        let sortedPages = document.unwrappedPages.sorted(by: { $0.pageNumber < $1.pageNumber })

        // Apply filter option first
        let filtered: [Page]
        switch filterOption {
        case .all:
            filtered = sortedPages
        case .notDone:
            filtered = sortedPages.filter { !$0.isDone }
        case .done:
            filtered = sortedPages.filter { $0.isDone }
        }

        // Apply search if searchText is not empty
        guard !searchText.isEmpty else { return filtered }

        let query = searchText.lowercased()
        return filtered.filter { page in
            // Match page number: "1", "Page 1", "page 1"
            let pageNum = String(page.pageNumber)
            if pageNum.contains(query) || "page \(pageNum)".contains(query) {
                return true
            }

            // Match filename (case-insensitive)
            if let filename = page.originalFileName?.lowercased(), filename.contains(query) {
                return true
            }

            // Match page content (case-insensitive)
            if page.plainText.lowercased().contains(query) {
                return true
            }

            return false
        }
    }
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(filteredPages) { page in
                        ThumbnailView(
                            page: page,
                            document: document,
                            isSelected: selectedPageNumber == page.pageNumber,
                            navigationState: navigationState
                        ) {
                            navigationState.goToPage(pageNumber: page.pageNumber)
                            selectedPageNumber = page.pageNumber
                        }
                        .id(page.persistentModelID)  // Use stable model ID for animation
                    }
                }
                .padding()
                .animation(.easeInOut(duration: 0.3), value: navigationState.pageOrderVersion)
            }
            .onChange(of: selectedPageNumber) { _, newValue in
                // Scroll to page by finding its stable ID
                if let pageNumber = newValue,
                   let page = filteredPages.first(where: { $0.pageNumber == pageNumber }) {
                    withAnimation {
                        proxy.scrollTo(page.persistentModelID, anchor: .center)
                    }
                }
            }
            .safeAreaInset(edge: searchBarEdge, spacing: 0) {
                HStack(spacing: 8) {
                    Menu {
                        Picker(selection: $filterOptionString, label: Text("Filter by status")) {
                            ForEach(FilterOption.allCases, id: \.self) { option in
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
            .onChange(of: filterOptionString) { _, newValue in
                // Announce immediately when status filter changes
                announceFilterChange()
                // Sync to NavigationState for filtered navigation
                navigationState.activeStatusFilter = newValue
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
                navigationState.activeStatusFilter = filterOptionString
                navigationState.activeSearchText = searchText
            }
        }
    }
}

struct ThumbnailView: View {
    let page: Page
    let document: Document
    let isSelected: Bool
    var navigationState: NavigationState?
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

    /// Move this page up by swapping pageNumbers with adjacent page
    private func movePageUp() {
        guard let adjacent = document.unwrappedPages.first(where: { $0.pageNumber == page.pageNumber - 1 }) else { return }

        // Capture original page numbers for cache update
        let originalPageNumber = page.pageNumber
        let adjacentPageNumber = adjacent.pageNumber

        let temp = page.pageNumber
        page.pageNumber = adjacent.pageNumber
        adjacent.pageNumber = temp

        // Update export cache with swapped page numbers
        TextExportCacheService.swapPageNumbers(originalPageNumber, adjacentPageNumber, in: document)

        navigationState?.refreshPageOrder()
    }

    /// Move this page down by swapping pageNumbers with adjacent page
    private func movePageDown() {
        guard let adjacent = document.unwrappedPages.first(where: { $0.pageNumber == page.pageNumber + 1 }) else { return }

        // Capture original page numbers for cache update
        let originalPageNumber = page.pageNumber
        let adjacentPageNumber = adjacent.pageNumber

        let temp = page.pageNumber
        page.pageNumber = adjacent.pageNumber
        adjacent.pageNumber = temp

        // Update export cache with swapped page numbers
        TextExportCacheService.swapPageNumbers(originalPageNumber, adjacentPageNumber, in: document)

        navigationState?.refreshPageOrder()
    }

    /// Delete this page from the document
    private func deletePage() {
        let deletedPageNumber = page.pageNumber

        // Remove page entry from export cache (also renumbers subsequent pages)
        TextExportCacheService.removeEntry(pageNumber: deletedPageNumber, from: document)

        // Decrement pageNumber for all pages after the deleted one
        for otherPage in document.unwrappedPages where otherPage.pageNumber > deletedPageNumber {
            otherPage.pageNumber -= 1
        }

        // Remove from document's pages array
        document.pages?.removeAll { $0.persistentModelID == page.persistentModelID }
        document.totalPages -= 1
        document.recalculateStorageSize()

        // Delete the page from the model context
        modelContext.delete(page)

        // Refresh navigation state
        navigationState?.refreshPageOrder()

        // If we deleted the current page, navigate to an adjacent page
        if navigationState?.currentPageNumber == deletedPageNumber {
            let newPageNumber = min(deletedPageNumber, document.totalPages)
            if newPageNumber > 0 {
                navigationState?.goToPage(pageNumber: newPageNumber)
            }
        }
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
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                            Text("Error generating preview")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if page.isDone {
                        VStack {
                            HStack {
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.green)
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
                    ShareLink(item: RichText(page.richText),
                              preview: SharePreview(String(localized: "Page \(page.pageNumber) Text"))) {
                        Label("Export Page Text…", systemImage: "square.and.arrow.up")
                    }
                }

                // MARK: - Rotation Section
                Section {
                    Button {
                        page.rotation = (page.rotation + 90) % 360
                    } label: {
                        Label("Rotate Clockwise", systemImage: "rotate.right")
                    }

                    Button {
                        page.rotation = (page.rotation + 270) % 360
                    } label: {
                        Label("Rotate Counterclockwise", systemImage: "rotate.left")
                    }
                }

                // MARK: - Adjustments Section
                Section {
                    Toggle(isOn: Binding(
                        get: { page.increaseContrast },
                        set: { page.increaseContrast = $0 }
                    )) {
                        Label("Increase Contrast", systemImage: "circle.lefthalf.filled")
                    }

                    Toggle(isOn: Binding(
                        get: { page.increaseBlackPoint },
                        set: { page.increaseBlackPoint = $0 }
                    )) {
                        Label("Increase Black Point", systemImage: "circle.bottomhalf.filled")
                    }
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
                        Label("Move Page Down", systemImage: "arrow.down")
                    }
                    .disabled(!canMoveDown)
                }

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
            .confirmationDialog(
                "Delete Page \(page.pageNumber)?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    withAnimation {
                        deletePage()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete the page from your project. This cannot be undone.")
            }

            Text(pageLabel)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .accessibilityHidden(true)
        }
    }
}

#Preview("English") {
    @Previewable @State var selectedPageNumber: Int? = 1

    let container = previewContainer()
    let document = Document(name: "Sample Document", totalPages: 3)
    let page1 = Page(pageNumber: 1, text: "Here's to the crazy ones.", imageData: nil, originalFileName: "page1.jpg")
    let page2 = Page(pageNumber: 2, text: "The misfits. The rebels. The troublemakers. The round pegs in the square holes.", imageData: nil, originalFileName: "page2.jpg")
    page2.isDone = true
    let page3 = Page(pageNumber: 3, text: "The ones who see things differently.", imageData: nil, originalFileName: "page3.jpg")
    document.pages = [page1, page2, page3]

    let navigationState = NavigationState()
    navigationState.setupNavigation(for: document)

    return ThumbnailSidebar(
        document: document,
        navigationState: navigationState,
        selectedPageNumber: $selectedPageNumber
    )
    .modelContainer(container)
    .environment(\.locale, Locale(identifier: "en"))
    .frame(width: 200, height: 600)
}

#Preview("es-419") {
    @Previewable @State var selectedPageNumber: Int? = 1

    let container = previewContainer()
    let document = Document(name: "Documento de Ejemplo", totalPages: 3)
    let page1 = Page(pageNumber: 1, text: "Texto de ejemplo para la página 1", imageData: nil, originalFileName: "pagina1.jpg")
    let page2 = Page(pageNumber: 2, text: "Texto de ejemplo para la página 2", imageData: nil, originalFileName: "pagina2.jpg")
    page2.isDone = true
    let page3 = Page(pageNumber: 3, text: "Texto de ejemplo para la página 3", imageData: nil, originalFileName: "pagina3.jpg")
    document.pages = [page1, page2, page3]

    let navigationState = NavigationState()
    navigationState.setupNavigation(for: document)

    return ThumbnailSidebar(
        document: document,
        navigationState: navigationState,
        selectedPageNumber: $selectedPageNumber
    )
    .modelContainer(container)
    .environment(\.locale, Locale(identifier: "es-419"))
    .frame(width: 200, height: 600)
}

