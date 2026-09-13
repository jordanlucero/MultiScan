//
//  OpenProjectIntent.swift
//  MultiScan
//
//  `.system.open` schema: opens a project. Spotlight uses this to open a project search result.
//

import AppIntents

@AppIntent(schema: .system.open)
struct OpenProjectIntent: OpenIntent {
    var target: ProjectEntity

    /// Declared explicitly rather than left to the derived default: this intent drives `AppRouter`, so it must bring the app forward.
    static var supportedModes: IntentModes { .foreground }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Dependency var router: AppRouter

    @MainActor
    func perform() async throws -> some IntentResult {
        router.open(project: target.id)
        return .result()
    }
}
