//
//  OpenPageIntent.swift
//  MultiScan
//
//  Opens a project at a specific page. Spotlight uses this to open a page search result.
//

import AppIntents

struct OpenPageIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Page"
    static let description = IntentDescription(
        "Opens a MultiScan project at a specific page.",
        categoryName: "Projects"
    )
    static var supportedModes: IntentModes { .foreground }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Page", requestValueDialog: "Which page?")
    var target: PageEntity

    @Dependency var router: AppRouter

    @MainActor
    func perform() async throws -> some IntentResult {
        router.open(project: target.projectID, page: target.pageNumber)
        return .result()
    }
}
