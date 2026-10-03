//
//  OpenPageIntent.swift
//  MultiScan
//
//  Opens a project at a specific page. Spotlight uses this to open a page search result.
//

import AppIntents

struct OpenPageIntent: OpenIntent {
    nonisolated static let title: LocalizedStringResource = "Open Page"
    nonisolated static let description = IntentDescription(
        "Opens a MultiScan project at a specific page.",
        categoryName: "Projects"
    )
    nonisolated static var supportedModes: IntentModes { .foreground }
    nonisolated static var allowedExecutionTargets: IntentExecutionTargets { .main }

    nonisolated init() {}

    @Parameter(title: "Page", requestValueDialog: "Which page?")
    var target: PageEntity

    @Dependency var router: AppRouter

    func perform() async throws -> some IntentResult {
        router.open(project: target.projectID, page: target.pageNumber)
        return .result()
    }
}
