//
//  DeleteProjectIntent.swift
//  MultiScan
//
//  Deletes projects after an explicit confirmation. The Spotlight index catches up through the save notification (see `SpotlightIndexer`).
//

import AppIntents

struct DeleteProjectIntent: DeleteIntent {
    nonisolated static let title: LocalizedStringResource = "Delete Project"
    nonisolated static let description = IntentDescription(
        "Permanently deletes projects and all of their pages.",
        categoryName: "Projects"
    )
    nonisolated static var allowedExecutionTargets: IntentExecutionTargets { .main }

    nonisolated init() {}

    @Parameter(title: "Projects", requestValueDialog: "Which projects should be deleted?")
    var entities: [ProjectEntity]

    nonisolated static var parameterSummary: some ParameterSummary {
        Summary("Delete \(\.$entities)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard !entities.isEmpty else {
            return .result(dialog: IntentDialog("No projects were selected."))
        }
        let names = entities.map(\.displayTitle).joined(separator: ", ")
        try await requestConfirmation(
            actionName: .do,
            dialog: IntentDialog("Delete \(entities.count) projects (\(names))? This cannot be undone.")
        )
        let deleted = try ProjectMaintenance.deleteProjects(
            uuids: entities.map(\.id),
            context: AppModelContainer.shared.mainContext
        )
        MultiScanShortcuts.updateAppShortcutParameters()
        return .result(dialog: IntentDialog("Deleted \(deleted) projects."))
    }
}
