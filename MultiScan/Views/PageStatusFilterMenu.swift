//
//  PageStatusFilterMenu.swift
//  MultiScan
//
//  The one status-filter control (All / Reviewed / Not Reviewed), used beside the search field in the thumbnail sidebar (macOS, iPad) and in the compact page grid's bottom bar (iPhone).
//
//  ## Rendering (2.1 fix)
//  The 2.0 sidebar drew its own capsule behind a `Menu` and filled it with the accent color when active — which fought the system's menu button rendering and looked wrong inside the glass search bar. The platform convention for "a filter is applied" (Mail, Files, Photos) is simply the **filled symbol variant tinted with the accent color**, and the plain outline otherwise. So:
//  - `Menu` + inline `Picker` for the choices (a real radio group in the menu);
//  - the label is `line.3.horizontal.decrease.circle`, `.symbolVariant(.fill)` + `.tint(.accentColor)` when a filter is active;
//  - `.menuIndicator(.hidden)` and a borderless/plain style so it sits in a bar like any other bar button.
//  No custom backgrounds: the hosting bar (glass bar or bottom toolbar) supplies the chrome.
//

import SwiftUI

struct PageStatusFilterMenu: View {
    /// Raw `PageFilterOption` value — `@AppStorage(DefaultsKey.filterOption)` at the call site, so every surface shows the same filter.
    @Binding var filterOptionString: String
    let visiblePageCount: Int
    let totalPageCount: Int

    private var filterOption: PageFilterOption {
        PageFilterOption(rawValue: filterOptionString) ?? .all
    }

    private var isFilterActive: Bool {
        filterOption != .all
    }

    var body: some View {
        Menu {
            Picker(selection: $filterOptionString) {
                ForEach(PageFilterOption.allCases, id: \.self) { option in
                    Text(option.label).tag(option.rawValue)
                }
            } label: {
                Text("Filter by status")
            }
            .pickerStyle(.inline)
        } label: {
            Label("Filter by status", systemImage: "line.3.horizontal.decrease.circle")
                .labelStyle(.iconOnly)
                .symbolVariant(isFilterActive ? .fill : .none)
                .symbolRenderingMode(.hierarchical)
        }
        .menuIndicator(.hidden)
        .tint(isFilterActive ? Color.accentColor : nil)
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .fixedSize()
        #endif
        .accessibilityLabel("Filter by status")
        .accessibilityValue(isFilterActive
            ? "\(String(localized: filterOption.label)), \(visiblePageCount) of \(totalPageCount) pages visible"
            : "All \(totalPageCount) pages")
        .help(isFilterActive ? "Filtering: \(String(localized: filterOption.label))" : "Filter pages")
    }
}

#Preview("Inactive") {
    @Previewable @State var filter = PageFilterOption.all.rawValue
    PageStatusFilterMenu(filterOptionString: $filter, visiblePageCount: 12, totalPageCount: 12)
        .padding()
}

#Preview("Active") {
    @Previewable @State var filter = PageFilterOption.notDone.rawValue
    PageStatusFilterMenu(filterOptionString: $filter, visiblePageCount: 4, totalPageCount: 12)
        .padding()
}
