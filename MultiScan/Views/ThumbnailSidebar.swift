import SwiftUI

struct ThumbnailSidebar: View {
    let document: Document
    @ObservedObject var navigationState: NavigationState
    @Binding var selectedPageNumber: Int?
    
    enum FilterOption: String, CaseIterable {
        case all = "All"
        case notDone = "Not Reviewed"
        case done = "Reviewed"
    }
    
    @State private var filterOption: FilterOption = .all
    
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
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Bottom toolbar
            HStack(spacing: 8) {
                Menu {
                    ForEach(FilterOption.allCases, id: \.self) { option in
                        Button(action: { filterOption = option }) {
                            HStack {
                                Text(option.rawValue)
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
                .help("Filter pages")
                
                Spacer()
                
                if filterOption != .all {
                    Text(filterOption.rawValue)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
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
