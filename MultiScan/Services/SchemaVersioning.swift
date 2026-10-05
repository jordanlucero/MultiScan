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
//  | Version | Notes                                                        |
//  |---------|--------------------------------------------------------------|
//  | 1       | Initial tracked version with CloudKit                        |
//  | 2       | 2.0 preview: Page.richTextData format changed from JSON-     |
//  |         | encoded AttributedString to RTF (TextKit 2 engine). Same     |
//  |         | property/type, so the SwiftData schema is unchanged — but v1 |
//  |         | apps cannot decode RTF text and must not write over it.      |
//  | 3       | 2.0 (shipping): Page.richTextData may now be *RTFD*          |
//  |         | (flattened package) when a page carries inline attachments   |
//  |         | (artwork captures, tables). Text-only pages stay RTF. A 2.0  |
//  |         | preview build (schema 2) decodes RTFD as RTF → empty text → |
//  |         | could save it back, so schema-2 builds are gated. New        |
//  |         | PageCapture model + additive fields.                         |
//

import Foundation
import SwiftData

// MARK: - Schema Version Constants

/// Constants for schema version tracking. Pure constants, read from every isolation domain (including the nonisolated `SchemaMetadata` model).
nonisolated enum SchemaVersioning {
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
    ///
    /// Version 2 (2.0 preview builds): rich text data format changed to RTF. Older app
    /// builds decode `richTextData` as JSON and would see empty text (and could
    /// overwrite it), so they must be gated behind the "Update Required" flow.
    ///
    /// Version 3 (2.0 as shipped): `richTextData` may be RTFD (a flattened `FileWrapper`
    /// package) for pages with inline attachments. 2.0 preview builds call the RTF
    /// decoder on it, get an empty string, and would write that back — the same hazard
    /// v2 guarded against, so the gate moves up. Pages without attachments are still
    /// plain RTF, and the SwiftData/CloudKit schema change (new `PageCapture` record
    /// type, new optional/defaulted fields) is additive and needs no gate of its own.
    /// The CloudKit schema was never promoted for v2, so v3 is the first promotion.
    static let currentVersion = 3

    // ────────────────────────────────────────────────────────────────────────
    // MARK: Storage Keys
    // ────────────────────────────────────────────────────────────────────────

    /// UserDefaults key for storing the last successfully loaded schema version.
    ///
    /// This is checked BEFORE attempting to load the ModelContainer, allowing
    /// us to warn the user before potentially crashing on incompatible data.
    static let userDefaultsKey = "multiScanSchemaVersion"

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
    /// **Important**: Changing this setting requires an app restart because SwiftData's `cloudKitDatabase` is configured at container creation time.
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
/// It's particularly important for CloudKit sync scenarios where another device might sync data written by a newer app version.
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
/// Device A (v2.0) creates data with schemaVersion = 2
/// Device B (v1.6) syncs and sees schemaVersion = 2 > currentVersion = 1
/// Device B shows "Please update the app" warning instead of corrupting data
///
@Model
nonisolated final class SchemaMetadata {
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
        // Raise (never lower) the stored version: once this app version runs it writes
        // current-format data, and older devices syncing via CloudKit must see the bump
        // so their version gate fires.
        if schemaVersion < SchemaVersioning.currentVersion {
            schemaVersion = SchemaVersioning.currentVersion
        }
    }
}

// MARK: - Pre-Load Check Result

/// Result of checking schema compatibility before loading the container.
enum PreLoadCheckResult {
    /// Data is compatible with this app version (including fresh installs and pre-versioning data, which the post-load integrity pass covers).
    case compatible

    /// Data was written by a newer app version. The user is shown the "Update Required" screen.
    case newerThanApp(storedVersion: Int)
}

// MARK: - Preview Support

/// Creates an in-memory ModelContainer for SwiftUI previews (and unit tests).
/// Explicitly disables CloudKit to avoid schema validation crashes in preview context.
func previewContainer() -> ModelContainer {
    let config = ModelConfiguration(
        isStoredInMemoryOnly: true,
        cloudKitDatabase: .none
    )
    return try! ModelContainer(
        for: Document.self, Page.self, PageCapture.self, SchemaMetadata.self,
        configurations: config
    )
}
