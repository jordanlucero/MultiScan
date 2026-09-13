//
//  AppRouter.swift
//  MultiScan
//
//  App-level navigation requests that originate outside the view hierarchy: Spotlight results, App Intents, and the app-wide search UI.
//
//  `ContentView` observes `openRequest` / `wantsHome`; the review views consume the page number; `HomeView` binds its `.searchable` field to `searchText` / `isSearchPresented`.
//
//  There is one router per process (registered with `AppDependencyManager`). On macOS with several windows, every window observes it and the one showing the target project navigates an accepted limitation.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    /// A request to show a project (and optionally a specific page). `id` makes repeated requests for the same target distinguishable so `onChange` fires each time.
    struct OpenRequest: Equatable, Sendable {
        let id: UUID
        let projectUUID: UUID
        let pageNumber: Int?
    }

    /// Pending open request; cleared by the view that fulfilled it (`consumeOpenRequest`).
    var openRequest: OpenRequest?

    /// Set when a system search should return to the Home screen before presenting results.
    var wantsHome = false

    /// App-wide search state (bound to HomeView's search field).
    var searchText = ""
    var isSearchPresented = false

    func open(project: UUID, page: Int? = nil) {
        openRequest = OpenRequest(id: UUID(), projectUUID: project, pageNumber: page)
    }

    /// Shows Home with the search field presented and populated (system `searchInApp` schema).
    func showSearch(_ term: String) {
        openRequest = nil
        wantsHome = true
        searchText = term
        isSearchPresented = true
    }

    func consumeOpenRequest() {
        openRequest = nil
    }

    /// Consumes a pending open request that targets `document`, navigating to the requested page. Requests for other projects are left alone for the view showing that project.
    func fulfillOpenRequest(for document: Document, navigationState: NavigationState) {
        guard let request = openRequest, request.projectUUID == document.uuid else { return }
        if let pageNumber = request.pageNumber, navigationState.currentPageNumber != pageNumber {
            navigationState.goToPage(pageNumber: pageNumber)
        }
        consumeOpenRequest()
    }
}
