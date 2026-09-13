//
//  SearchResultsView.swift
//  MultiScan
//
//  App-wide search results (projects by name, pages by recognized text) shown in place of the Home grid while the search field has a query. Queries run on `ProjectStore` (off the main actor, SQLite `#Predicate` over the stored `Page.plainText` column) and are debounced per keystroke.
//

import SwiftUI

struct SearchResultsView: View {
    let term: String

    @Environment(AppRouter.self) private var router
    @State private var results: SearchResults = .empty
    @State private var isSearching = false

    var body: some View {
        Group {
            if results.isEmpty && results.term == term && !isSearching {
                ContentUnavailableView.search(text: term)
            } else {
                resultsList
            }
        }
        .task(id: term) {
            isSearching = true
            // Let typing settle before hitting the database.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let hits = await ProjectStore.shared.search(term: term)
            guard !Task.isCancelled else { return }
            results = hits
            isSearching = false
        }
    }

    private var resultsList: some View {
        List {
            if !results.projects.isEmpty {
                Section("Projects") {
                    ForEach(results.projects) { hit in
                        Button {
                            router.open(project: hit.id)
                        } label: {
                            projectRow(hit)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !results.pages.isEmpty {
                Section("Pages") {
                    ForEach(results.pages) { hit in
                        Button {
                            router.open(project: hit.projectID, page: hit.pageNumber)
                        } label: {
                            pageRow(hit)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .overlay {
            if isSearching && results.isEmpty {
                ProgressView()
            }
        }
    }

    private func projectRow(_ hit: ProjectSearchHit) -> some View {
        HStack(spacing: 12) {
            Text(hit.emoji ?? "📄")
                .font(.title2)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(highlighted(hit.name))
                    .font(.headline)
                    .lineLimit(1)
                Text(hit.pageCount == 1 ? "1 page" : "\(hit.pageCount) pages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the project")
    }

    private func pageRow(_ hit: PageSearchHit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Page \(hit.pageNumber)")
                    .font(.headline)
                Text("·")
                    .foregroundStyle(.secondary)
                Text(projectTitle(hit))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(highlighted(hit.snippet))
                .font(.callout)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the project at this page")
    }

    private func projectTitle(_ hit: PageSearchHit) -> String {
        let emoji = hit.projectEmoji ?? ""
        return emoji.isEmpty ? hit.projectName : "\(emoji) \(hit.projectName)"
    }

    /// Bolds every case/diacritic-insensitive occurrence of the search term.
    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: term, options: options, range: searchStart..<text.endIndex) {
            if let lower = AttributedString.Index(range.lowerBound, within: attributed),
               let upper = AttributedString.Index(range.upperBound, within: attributed) {
                attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            }
            searchStart = range.upperBound
        }
        return attributed
    }
}
