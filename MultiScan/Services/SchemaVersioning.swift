//
//  SchemaVersioning.swift
//  MultiScan
//
//  Schema versioning system for safe data evolution and CloudKit compatibility.
//
//  ## Purpose
//
//  This system tracks what schema version wrote the data, enabling:
//  1. Detection of data from newer app versions (CloudKit sync from updated device)
//  2. Graceful handling of incompatible data instead of crashes
//  3. Documentation of schema evolution for future changes
//
//  ## How It Works
//
//  Version is stored in two places:
//  - **UserDefaults**: Checked BEFORE container loads. Survives database corruption.
//  - **SchemaMetadata model**: Checked AFTER load. Detects CloudKit sync from newer app.
//
//  ## Version Bump Rules
//
//  | Change Type              | Safe? | Bump Version? |
//  |--------------------------|-------|---------------|
//  | Add property with default| Yes   | No            |
//  | Add new @Model class     | Yes   | No            |
//  | Remove property          | NO    | Yes           |
//  | Rename property          | NO    | Yes           |
//  | Change property type     | NO    | Yes           |
//
//  ## Version History
//
//  See CLAUDE.md for detailed version history.
//
//  | Version | Notes                                    |
//  |---------|------------------------------------------|
//  | 1       | Initial tracked version with CloudKit    |
//

import Foundation
import SwiftData

// MARK: - Schema Version Constants

/// Constants for schema version tracking
enum SchemaVersioning {
    // ────────────────────────────────────────────────────────────────────────
    // MARK: Version Numbers
    // ────────────────────────────────────────────────────────────────────────

    /// Current schema version.
    ///
    /// **When to bump:**
    /// - Removing a property from Document or Page
    /// - Renaming a property
    /// - Changing a property's type
    ///
    /// **When NOT to bump:**
    /// - Adding a new property with a default value
    /// - Adding a new @Model class
    ///
    /// After bumping, update the version history in CLAUDE.md and add handling
    /// in SchemaValidationService for the migration path.
    static let currentVersion = 1

    /// Minimum schema version this app can read.
    ///
    /// Data from versions below this cannot be loaded and requires reset.
    /// In practice, this should rarely change - prefer self-healing over rejection.
    static let minimumSupportedVersion = 1

    // ────────────────────────────────────────────────────────────────────────
    // MARK: Storage Keys
    // ────────────────────────────────────────────────────────────────────────

    /// UserDefaults key for storing the last successfully loaded schema version.
    ///
    /// This is checked BEFORE attempting to load the ModelContainer, allowing
    /// us to warn the user before potentially crashing on incompatible data.
    static let userDefaultsKey = "multiScanSchemaVersion"

    /// UserDefaults key for tracking if this is a fresh install.
    ///
    /// Fresh installs don't need version warnings even if UserDefaults has no version.
    static let freshInstallKey = "multiScanHasLaunchedBefore"

    // ────────────────────────────────────────────────────────────────────────
    // MARK: iCloud Sync Setting
    // ────────────────────────────────────────────────────────────────────────

    /// UserDefaults key for iCloud sync preference.
    ///
    /// **Default: false (off)**
    ///
    /// Reasoning for defaulting to OFF:
    /// - Some users have limited iCloud storage
    /// - Large projects (1000+ pages with images) can use significant space
    /// - Users who want sync can opt-in
    /// - If user isn't signed into iCloud, enabling this has no effect (data stays local)
    ///
    /// **Important**: Changing this setting requires an app restart because
    /// SwiftData's `cloudKitDatabase` is configured at container creation time.
    static let iCloudSyncEnabledKey = "multiScanICloudSyncEnabled"

    /// Returns the current iCloud sync setting.
    /// Use this during container creation to decide whether to enable CloudKit.
    static var isICloudSyncEnabled: Bool {
        UserDefaults.standard.bool(forKey: iCloudSyncEnabledKey)
    }
}

// MARK: - Schema Metadata Model

/// Tracks schema metadata within the database itself.
///
/// This single-row model stores version information that persists with the data.
/// It's particularly important for CloudKit sync scenarios where another device
/// might sync data written by a newer app version.
///
/// ## Usage
///
/// On app launch, after successfully loading the container:
/// 1. Query for existing SchemaMetadata (should be 0 or 1 records)
/// 2. If none exists, create one (fresh install or pre-versioning data)
/// 3. If exists, check if `schemaVersion` > app's `currentVersion`
/// 4. Update `lastSuccessfulLoad` timestamp
///
/// ## CloudKit Sync Scenario
///
/// Device A (v1.5.2) creates data with schemaVersion = 2
/// Device B (v1.5.1) syncs and sees schemaVersion = 2 > currentVersion = 1
/// Device B shows "Please update the app" warning instead of corrupting data
///
@Model
final class SchemaMetadata {
    // MARK: - CloudKit Compatibility
    // All properties must have default values for CloudKit sync.

    /// Unique identifier for the device that created this metadata record.
    ///
    /// Each device creates its own SchemaMetadata record. When syncing via CloudKit,
    /// this prevents devices from overwriting each other's records and allows each
    /// device to track its own last successful load independently.
    var deviceID: String = ""

    /// The schema version that last wrote to this database.
    ///
    /// If this is higher than the app's `currentVersion`, the data was written
    /// by a newer app version and may contain fields this version doesn't understand.
    var schemaVersion: Int = SchemaVersioning.currentVersion

    /// Timestamp of the last successful app launch that loaded this container.
    ///
    /// Useful for debugging sync issues - shows when data was last accessed on this device.
    var lastSuccessfulLoad: Date = Date()

    /// The app build number that last wrote to this database.
    ///
    /// Useful for debugging - helps identify which specific build created/modified data.
    var lastAppBuild: String = ""

    // MARK: - Initialization

    init() {
        self.deviceID = SchemaMetadata.currentDeviceID
        self.schemaVersion = SchemaVersioning.currentVersion
        self.lastSuccessfulLoad = Date()
        self.lastAppBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    // MARK: - Device Identification

    /// Returns a stable identifier for this device.
    ///
    /// Uses a generated UUID stored in UserDefaults. This persists across app launches
    /// but is reset if the user deletes the app or clears app data.
    static var currentDeviceID: String {
        let key = "multiScanDeviceUUID"
        if let stored = UserDefaults.standard.string(forKey: key) {
            return stored
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: key)
        return newID
    }

    // MARK: - Update Methods

    /// Updates metadata after a successful container load.
    ///
    /// Call this on every successful app launch to keep metadata current.
    func recordSuccessfulLoad() {
        self.lastSuccessfulLoad = Date()
        self.lastAppBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        // Note: Don't update schemaVersion here - it should only change when
        // we deliberately bump it for breaking changes
    }
}

// MARK: - Pre-Load Check Result

/// Result of checking schema compatibility before loading the container.
enum PreLoadCheckResult {
    /// Data is compatible with this app version.
    case compatible

    /// No version information found - either fresh install or legacy data.
    /// Proceed with caution and run integrity validation after load.
    case unknownLegacy

    /// Data was written by a newer app version.
    /// User should be warned and offered options.
    case newerThanApp(storedVersion: Int)

    /// Data is too old to be supported by this app version.
    /// This should be rare - we prefer self-healing over rejection.
    case tooOld(storedVersion: Int)
}

// MARK: - Container State

/// Represents the state of the ModelContainer during app initialization.
///
/// Used by MultiScanApp to manage the loading flow and show appropriate UI.
enum ContainerState: Sendable {
    /// Container is being created. Show loading indicator.
    case loading

    /// Container loaded successfully. Proceed to normal app UI.
    case ready(ModelContainer)

    /// Container failed to load. Show recovery UI with options.
    case failed(ContainerLoadError)

    /// Data is incompatible with this app version. Show warning.
    case incompatible(IncompatibilityReason)
}

/// Reasons why data might be incompatible with the current app version.
enum IncompatibilityReason: Sendable {
    /// Data was written by a newer app version (CloudKit sync from updated device).
    case newerData(version: Int)

    /// Data is too old to be supported.
    case legacyData(version: Int)
}

/// Errors that can occur during container loading.
enum ContainerLoadError: Error, Sendable {
    /// The ModelContainer failed to initialize.
    case containerCreationFailed(String)

    /// Critical data integrity issues were found that couldn't be auto-fixed.
    case criticalIntegrityIssues([String])

    /// The database file is corrupted or unreadable.
    case databaseCorrupted(String)
}

extension ContainerLoadError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .containerCreationFailed(let message):
            return "Failed to load data: \(message)"
        case .criticalIntegrityIssues(let issues):
            return "Data integrity issues: \(issues.joined(separator: ", "))"
        case .databaseCorrupted(let message):
            return "Database corrupted: \(message)"
        }
    }
}

// MARK: - Preview Support

/// Creates an in-memory ModelContainer for SwiftUI previews.
/// Explicitly disables CloudKit to avoid schema validation crashes in preview context.
@MainActor
func previewContainer() -> ModelContainer {
    let config = ModelConfiguration(
        isStoredInMemoryOnly: true,
        cloudKitDatabase: .none
    )
    return try! ModelContainer(
        for: Document.self, Page.self, SchemaMetadata.self,
        configurations: config
    )
}
