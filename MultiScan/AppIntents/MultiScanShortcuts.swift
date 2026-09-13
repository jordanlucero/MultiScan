//
//  MultiScanShortcuts.swift
//  MultiScan
//
//

import AppIntents

struct MultiScanShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchProjectsIntent(),
            // Note that near-duplicate wordings degrade Siri's match accuracy rather than widening coverage.
            phrases: [
                "Search \(.applicationName)",
                "Search my \(.applicationName) projects"
            ],
            shortTitle: "Search Projects",
            systemImageName: "magnifyingglass"
        )

        AppShortcut(
            intent: OpenProjectIntent(),
            phrases: [
                "Open \(\.$target) in \(.applicationName)",
                "Open a project in \(.applicationName)"
            ],
            shortTitle: "Open Project",
            systemImageName: "folder"
        )

        AppShortcut(
            intent: CreateProjectIntent(),
            phrases: [
                "Start a new project in \(.applicationName)",
                "Start a new \(.applicationName) project"
            ],
            shortTitle: "Start New Project",
            systemImageName: "document.viewfinder"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .teal
}
