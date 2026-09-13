//
//  SearchProjectsIntent.swift
//  MultiScan
//
//  `.system.searchInApp` schema: "Search for <term> in MultiScan". The schema requires the app to
//  open and show results in its own search UI, which is HomeView's app-wide search field.
//

import AppIntents

@AppIntent(schema: .system.searchInApp)
struct SearchProjectsIntent: ShowInAppSearchResultsIntent {
    static let searchScopes: [StringSearchScope] = [.general]

    var criteria: StringSearchCriteria

    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Dependency var router: AppRouter

    @MainActor
    func perform() async throws -> some IntentResult {
        router.showSearch(criteria.term)
        return .result()
    }
}
