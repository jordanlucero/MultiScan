//
//  MultiScanApp.swift
//  MultiScan
//
//  Created by Jordan Lucero on 5/23/25.
//

import SwiftUI
import SwiftData
import AppIntents

// MARK: - Focused Values

/// Scene-scoped values the menu bar commands (`MultiScanCommands`) read from whichever review view has focus. `@Entry` synthesizes the key type and the `get`/`set` accessors — don't use `FocusedValueKey` conformances here.
///
/// A `FocusedValues` entry always defaults to `nil`, so every one of these must be declared with an `Optional` type and no initializer.
extension FocusedValues {
    /// The focused review view's navigation model (project, current page, page order, undo).
    @Entry var navigationState: NavigationState?

    /// The focused page's text editing controller (Format menu, save-before-export).
    @Entry var pageTextController: PageTextController?

    /// The focused view's zoom bridge (View menu, ⌘+/⌘−/⌘0).
    @Entry var imageZoomController: ImageZoomController?

    // Sheet/panel toggles driven by menu commands.
    @Entry var showExportPanel: Binding<Bool>?
    @Entry var showAddFromPhotos: Binding<Bool>?
    @Entry var showAddFromFiles: Binding<Bool>?
    @Entry var showFindNavigator: Binding<Bool>?
    @Entry var showDeletePageConfirmation: Binding<Bool>?
}

// MARK: - App Entry Point

@main
struct MultiScanApp: App {
    /// Set when the store can't be used: container creation failed, or the data was written by a newer app version. Shows `SchemaRecoveryView` instead of the app.
    @State private var recoveryState: RecoveryState?

    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Build the container first so the load-state check sees the real outcome.
        // The SwiftData + CloudKit setup, schema initialization, and versioning are documented in AppModelContainer / SchemaVersioning and CLAUDE.md.
        _ = AppModelContainer.shared
        _recoveryState = State(initialValue: Self.initialRecoveryState())

        // App Intents: entity queries and intents resolve these through `@Dependency`.
        // (`add(dependency:)` takes a Sendable autoclosure, so the main-actor singletons are read here first.)
        let router = AppRouter.shared
        let store = ProjectStore.shared
        AppDependencyManager.shared.add(dependency: router)
        AppDependencyManager.shared.add(dependency: store)

        // Spotlight: reconcile after saves / remote changes.
        SpotlightIndexer.installTriggers()
    }

    private static func initialRecoveryState() -> RecoveryState? {
        if let error = AppModelContainer.creationError {
            return .failed(error: error.localizedDescription)
        }
        if case .newerThanApp(let version) = AppModelContainer.preLoadCheckResult {
            return .incompatible(version: version)
        }
        return nil
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let recoveryState {
                    SchemaRecoveryView(state: recoveryState, onReset: AppModelContainer.resetStore)
                } else {
                    ContentView()
                }
            }
            #if os(macOS)
            .windowToolbarFullScreenVisibility(.onHover)
            #endif
            .task {
                // Post-load validation and self-healing. Skipped when already in recovery.
                guard recoveryState == nil else { return }
                if let newerVersion = await AppModelContainer.performPostLoadMaintenance() {
                    recoveryState = .incompatible(version: newerVersion)
                }
            }
            .environment(AppRouter.shared)
            .onChange(of: scenePhase) { _, phase in
                // Foregrounding is the reliable moment to pick up changes synced while inactive.
                if phase == .active {
                    Task { await SpotlightIndexer.shared.scheduleReconcile() }
                }
            }
        }
        .modelContainer(AppModelContainer.shared)
        .commands {
            MultiScanCommands()
        }

        #if os(macOS)
        // ⚠️ WORKAROUND: custom Window instead of the native `Settings` scene — see SettingsView.swift.
        Window("MultiScan Settings", id: "settings") {
            SettingsView()
                .frame(width: 650, height: 400)
        }
        .windowResizability(.contentSize)
        .commandsRemoved()
        #endif
    }
}
