//
//  AppModelContainer.swift
//  MultiScan
//
//  Process-wide SwiftData container. Lives outside the SwiftUI environment so App Intents, entity queries, and the Spotlight indexer can reach the same store the UI uses.
//

import Foundation
import SwiftData
import CoreData

@MainActor
enum AppModelContainer {
    /// Error captured during container creation (if any). `MultiScanApp` shows recovery UI when set.
    static var creationError: ContainerLoadError?

    /// Result of the pre-load schema version check (UserDefaults-based, survives DB corruption).
    static var preLoadCheckResult: PreLoadCheckResult = .compatible

    /// The one container for the process. Created lazily on first access; `MultiScanApp.init` touches it first so the load-state check observes the real outcome.
    static let shared: ModelContainer = {
        // Pre-load version check — runs BEFORE the container so it survives database corruption.
        let preLoadResult = SchemaValidationService.checkPreLoadCompatibility()
        preLoadCheckResult = preLoadResult

        if case .newerThanApp(let version) = preLoadResult {
            print("⚠️ Schema Warning: Data was written by schema version \(version), " +
                  "but this app only supports version \(SchemaVersioning.currentVersion)")
        }

        // iCloud sync is opt-in (Settings > Import and Storage) and fixed for the process lifetime.
        let iCloudSyncEnabled = SchemaVersioning.isICloudSyncEnabled
        print(iCloudSyncEnabled ? "☁️ iCloud sync ENABLED" : "☁️ iCloud sync DISABLED")

        let modelConfiguration = ModelConfiguration(
            isStoredInMemoryOnly: false,
            cloudKitDatabase: iCloudSyncEnabled
                ? .private("iCloud.co.jservices.MultiScan")
                : .none
        )

        #if DEBUG
        if iCloudSyncEnabled {
            initializeCloudKitSchemaIfRequested(configuration: modelConfiguration)
        }
        #endif

        do {
            let container = try ModelContainer(
                for: Document.self, Page.self, SchemaMetadata.self,
                configurations: modelConfiguration
            )
            // Don't record a successful load when the store is ahead of this build — that would clear the pre-load gate and let the next launch past the update gate.
            if case .newerThanApp = preLoadResult {} else {
                SchemaValidationService.recordSuccessfulLoad()
            }
            return container
        } catch {
            // Don't crash: remember the error (recovery UI) and fall back to an in-memory container.
            creationError = .containerCreationFailed(error.localizedDescription)
            print("ModelContainer creation failed: \(error)")

            let fallbackConfig = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            do {
                return try ModelContainer(
                    for: Document.self, Page.self, SchemaMetadata.self,
                    configurations: fallbackConfig
                )
            } catch {
                fatalError("Could not create a fallback ModelContainer: \(error)")
            }
        }
    }()

    // MARK: - Post-load maintenance

    /// Runs once the UI is up: validates the store against `SchemaMetadata` (catching data CloudKit synced from a newer build), self-heals minor integrity issues, backfills identity/plain-text columns, refreshes App Shortcuts, and brings the Spotlight index up to date.
    /// - Returns: the newer schema version found in the store, if any — the caller shows the "Update Required" screen.
    static func performPostLoadMaintenance() async -> Int? {
        let context = shared.mainContext

        let result = await SchemaValidationService.validatePostLoad(context: context)

        for issue in result.issues {
            if case .newerSchemaVersion(let stored, _) = issue {
                return stored
            }
        }

        if result.hasMinorIssues {
            let unfixable = SchemaValidationService.attemptSelfHeal(issues: result.issues, context: context)
            if !unfixable.isEmpty {
                print("Some integrity issues could not be auto-fixed: \(unfixable.map { $0.description })")
            }
        }

        await ProjectMaintenance.backfillIdentityAndPlainText(context: context)
        MultiScanShortcuts.updateAppShortcutParameters()
        await SpotlightIndexer.shared.scheduleReconcile()
        return nil
    }

    /// Deletes the on-disk store and clears the version gate. The user must relaunch afterwards.
    static func resetStore() {
        if let url = shared.configurations.first?.url {
            _ = SchemaValidationService.resetDatabase(containerURL: url)
        }
        UserDefaults.standard.removeObject(forKey: SchemaVersioning.userDefaultsKey)
    }

    #if DEBUG
    /// Pushes the current model layer to the CloudKit **development** environment, and validates it for CloudKit compatibility along the way.
    ///
    /// **Opt-in via the `-initializeCloudKitSchema` launch argument.** It uploads a representative record for every type and field and then deletes them, which is slow and blocks other CloudKit operations; Apple's guidance is not to run it on ordinary launches. Run it after changing the model, then promote the development schema in the CloudKit Console.
    private static func initializeCloudKitSchemaIfRequested(configuration: ModelConfiguration) {
        guard ProcessInfo.processInfo.arguments.contains("-initializeCloudKitSchema") else { return }

        do {
            // The container must be deallocated before SwiftData opens the same store.
            try autoreleasepool {
                let description = NSPersistentStoreDescription(url: configuration.url)
                description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                    containerIdentifier: "iCloud.co.jservices.MultiScan"
                )
                // Synchronous load so the store is ready before initializing the schema.
                description.shouldAddStoreAsynchronously = false

                guard let model = NSManagedObjectModel.makeManagedObjectModel(
                    for: [Document.self, Page.self, SchemaMetadata.self]
                ) else {
                    print("⚠️ CloudKit schema init: could not build the managed object model")
                    return
                }

                let container = NSPersistentCloudKitContainer(name: "MultiScan", managedObjectModel: model)
                container.persistentStoreDescriptions = [description]

                var loadError: Error?
                container.loadPersistentStores { _, error in loadError = error }
                if let loadError { throw loadError }

                try container.initializeCloudKitSchema()

                if let store = container.persistentStoreCoordinator.persistentStores.first {
                    try container.persistentStoreCoordinator.remove(store)
                }
            }
            print("☁️ CloudKit development schema initialized — promote it in the CloudKit Console")
        } catch {
            // Never block launch on this: it's a development tool, and the model validation error it throws is exactly what we want to read in the console.
            print("⚠️ CloudKit schema init failed: \(error)")
        }
    }
    #endif
}
