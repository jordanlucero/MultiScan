//
//  PageFilter.swift
//  MultiScan
//
//  Single source of truth for narrowing a project's pages by review status and free text. Shared by the thumbnail sidebar, the vertical size class' page grid, the View ▸ Filter By Status menu, and NavigationState's filter-aware page navigation.
//
//

import Foundation

/// Review-status filter for a project's pages.
///
/// Raw values are persisted in `@AppStorage("filterOption")` and mirrored into `NavigationState.activeStatusFilter` — don't rename the cases.
enum PageFilterOption: String, CaseIterable, Sendable {
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

    func matches(_ page: Page) -> Bool {
        switch self {
        case .all: true
        case .done: page.isDone
        case .notDone: !page.isDone
        }
    }
}

extension Page {
    /// Whether this page matches a free-text query. Matches the page number (either as a bare numeral or via the localized "Page N" label), the original filename, and the recognized text — all case-insensitively.
    ///
    /// `query` must already be lowercased; callers filtering a whole document lowercase once.
    func matches(lowercasedQuery query: String) -> Bool {
        guard !query.isEmpty else { return true }

        if String(pageNumber).contains(query) { return true }
        if String(localized: "Page \(pageNumber)").lowercased().contains(query) { return true }
        if let fileName = originalFileName?.lowercased(), fileName.contains(query) { return true }

        // `plainText` is a stored column, so this never touches external storage.
        return plainText.lowercased().contains(query)
    }
}

enum PageFilter {
    /// Sorts a project's pages by page number and applies the status filter and search text.
    static func apply(
        to pages: [Page],
        option: PageFilterOption = .all,
        searchText: String = ""
    ) -> [Page] {
        let sorted = pages.sorted { $0.pageNumber < $1.pageNumber }
        let byStatus = option == .all ? sorted : sorted.filter { option.matches($0) }

        let query = searchText.lowercased()
        guard !query.isEmpty else { return byStatus }
        return byStatus.filter { $0.matches(lowercasedQuery: query) }
    }
}
