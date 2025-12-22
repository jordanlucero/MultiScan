import SwiftUI
import SwiftData

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

    private var filterOption: FilterOption {
        get {
            switch filterOptionString {
            case "all": return .all
            case "notDone": return .notDone
            case "done": return .done
            default: return .all
            }
        }
        set {
            switch newValue {
            case .all: filterOptionString = "all"
            case .notDone: filterOptionString = "notDone"
            case .done: filterOptionString = "done"
            }
        }
    }
    
    var filteredPages: [Page] {
        let sortedPages = document.pages.sorted(by: { $0.pageNumber < $1.pageNumber })
        
        switch filterOption {
        case .all:
            return sortedPages
        case .notDone:
            return sortedPages.filter { !$0.isDone }
        case .done:
            return sortedPages.filter { $0.isDone }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
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
            }

            Divider()

            // Bottom toolbar
            HStack(spacing: 8) {
                Menu {
                    ForEach(FilterOption.allCases, id: \.self) { option in
                        Button(action: {
                            switch option {
                            case .all: filterOptionString = "all"
                            case .notDone: filterOptionString = "notDone"
                            case .done: filterOptionString = "done"
                            }
                        }) {
                            HStack {
                                Text(option.label)
                                if filterOption == option {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .font(.title3)
                }
                .menuStyle(.borderlessButton)
                .padding(.leading, 12)
                .help("Filter pages")

                Spacer()

                if filterOption != .all {
                    Text(filterOption.label)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(8)
        }
    }
}

struct ThumbnailView: View {
    let page: Page
    let document: Document
    let isSelected: Bool
    let action: () -> Void
    
    var thumbnail: NSImage? {
        if let thumbnailData = page.thumbnailData,
           let image = NSImage(data: thumbnailData) {
            return image
        }
        return nil
    }
    
    var body: some View {
        VStack(spacing: 4) {
            Button(action: action) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.controlColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                        )
                    
                    if let thumbnail = thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(4)
                    } else {
                        // Placeholder for pages without thumbnails
                        VStack {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                            Text("No Preview")
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
            
            Text(page.imageFileName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(isSelected ? .accentColor : .secondary)
        }
    }
}

#Preview("English") {
    @Previewable @State var container = try! ModelContainer(
        for: Document.self, Page.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    @Previewable @State var selectedPageNumber: Int? = 1

    let document = Document(name: "Sample Document", folderPath: "/tmp", totalPages: 3)
    let page1 = Page(pageNumber: 1, text: "Here’s to the crazy ones.", imageFileName: "page1.jpg")
    let page2 = Page(pageNumber: 2, text: "The misfits. The rebels. The troublemakers. The round pegs in the square holes.", imageFileName: "page2.jpg")
    page2.isDone = true
    let page3 = Page(pageNumber: 3, text: "The ones who see things differently.", imageFileName: "page3.jpg")
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

    let document = Document(name: "Documento de Ejemplo", folderPath: "/tmp", totalPages: 3)
    let page1 = Page(pageNumber: 1, text: "Texto de ejemplo para la página 1", imageFileName: "pagina1.jpg")
    let page2 = Page(pageNumber: 2, text: "Texto de ejemplo para la página 2", imageFileName: "pagina2.jpg")
    page2.isDone = true
    let page3 = Page(pageNumber: 3, text: "Texto de ejemplo para la página 3", imageFileName: "pagina3.jpg")
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
