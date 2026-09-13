//
//  MultiScanShortcuts.swift
//  MultiScan
//
//  App Shortcuts: pre-built phrases Siri and the Shortcuts app expose without any setup.
//  Phrases are localized through `AppShortcuts.xcstrings`. `updateAppShortcutParameters()` is
//  called whenever projects are created, renamed, or deleted so the "Open <project>" phrase
//  offers current names.
//

import AppIntents

struct MultiScanShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchProjectsIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Search in \(.applicationName)",
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
                "Scan a new project in \(.applicationName)",
                "Start a new \(.applicationName) project"
            ],
            shortTitle: "Scan New Project",
            systemImageName: "document.viewfinder"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .teal
}
