//
//  GetProjectTextIntent.swift
//  MultiScan
//
//  Returns a project's recognized text as plain text for Shortcuts and Siri workflows. RTF output comes from `ProjectEntity`'s Transferable conformance.
//

import AppIntents

struct GetProjectTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Project Text"
    static let description = IntentDescription(
        "Returns the recognized text of a project, optionally separated by page.",
        categoryName: "Projects"
    )

    @Parameter(title: "Project", requestValueDialog: "Which project?")
    var project: ProjectEntity

    @Parameter(title: "Separate Pages", description: "Insert a “Page X of Y” line between pages.", default: true)
    var separatePages: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Get text of \(\.$project)") {
            \.$separatePages
        }
    }

    @Dependency var store: ProjectStore

    func perform() async throws -> some ReturnsValue<String> {
        let export = try await store.projectText(uuid: project.id, options: .simple(separatePages: separatePages))
        return .result(value: export.plainText)
    }
}
