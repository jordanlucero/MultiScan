//
//  AppModelContainer.swift
//  MultiScan
//
//  Process-wide SwiftData container. Lives outside the SwiftUI environment so App Intents, entity queries, and the Spotlight indexer can reach the same store the UI uses.
//

import Foundation
import SwiftData

@MainActor
enum AppModelContainer {
    /// Error captured during container creation (if any). `MultiScanApp` shows recovery UI when set.
    static var creationError: ContainerLoadError?

    /// Result of the pre-load schema version check (UserDefaults-based, survives DB corruption).
    static var preLoadCheckResult: PreLoadCheckResult = .compatible

    /// The one container for the process. Created lazily on first access; `MultiScanApp.init`
    /// touches it first so the load-state check observes the real outcome.
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

        do {
            let container = try ModelContainer(
                for: Document.self, Page.self, SchemaMetadata.self,
                configurations: modelConfiguration
            )
            SchemaValidationService.markHasLaunched()
            SchemaValidationService.recordSuccessfulLoad()
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
}
