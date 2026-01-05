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
        case notDone
        case done

        var label: LocalizedStringResource {
            switch self {
            case .all: "All"
            case .notDone: "Not Reviewed"
            case .done: "Reviewed"
            }
        }
    }

    @AppStorage("filterOption") private var filterOptionString = "all"
    @State private var searchText = ""

    private var filterOption: FilterOption {
        get { FilterOption(rawValue: filterOptionString) ?? .all }
        set { filterOptionString = newValue.rawValue }
    }

    private var isFilterActive: Bool {
        filterOption != .all
    }

    var filteredPages: [Page] {
        let sortedPages = document.pages.sorted(by: { $0.pageNumber < $1.pageNumber })

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
                            isSelected: selectedPageNumber == page.pageNumber
                        ) {
                            navigationState.goToPage(pageNumber: page.pageNumber)
                            selectedPageNumber = page.pageNumber
                        }
                        .id(page.pageNumber)
                    }
                }
                .padding()
            }
            .onChange(of: selectedPageNumber) { _, newValue in
                if let pageNumber = newValue {
                    withAnimation {
                        proxy.scrollTo(pageNumber, anchor: .center)
                    }
                }
            }
            .safeAreaInset(edge: searchBarEdge, spacing: 0) {
                HStack(spacing: 8) {
                    Menu {
                        Picker(selection: $filterOptionString, label: Text("Filter by Status")) {
                            ForEach(FilterOption.allCases, id: \.self) { option in
                                Text(option.label).tag(option.rawValue)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease")
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .background {
                        Capsule()
                            .fill(isFilterActive ? Color.accentColor : .clear)
                            .stroke(.tertiary.opacity(isFilterActive ? 0 : 1), lineWidth: 1)
                    }
                    .fixedSize()
                    .help(isFilterActive ? "Filtering: \(String(localized: filterOption.label))" : "Filter pages")

                    TextField("Filter", text: $searchText)
                        .textFieldStyle(.plain)

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search filter")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .glassEffect()
                .padding(8)
                
            }
        }
    }
}

struct ThumbnailView: View {
    let page: Page
    let document: Document
    let isSelected: Bool
    let action: () -> Void

    /// Cross-platform thumbnail using PlatformImage helper
    var thumbnail: Image? {
        guard let data = page.thumbnailData else { return nil }
        return PlatformImage.from(data: data)
    }

    /// Formatted page label: "Page X (filename)" or "Page X" if no filename stored
    var pageLabel: String {
        let pageNumber = page.pageNumber
        if let fileName = page.originalFileName {
            return String(localized: "Page \(pageNumber) (\(fileName))",
                          comment: "Thumbnail label with page number and filename, e.g. 'Page 3 (IMG_0003.HEIC)'")
        }
        return String(localized: "Page \(pageNumber)",
                      comment: "Thumbnail label with page number only (no filename available)")
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
    @Previewable @State var container = try! ModelContainer(
        for: Document.self, Page.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    @Previewable @State var selectedPageNumber: Int? = 1

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
    @Previewable @State var container = try! ModelContainer(
        for: Document.self, Page.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    @Previewable @State var selectedPageNumber: Int? = 1

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

