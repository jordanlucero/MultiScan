//
//  SchemaValidationService.swift
//  MultiScan
//
//  Validates data integrity and performs self-healing for minor issues.
//
//
//  This service ensures data consistency and handles schema version checking:
//  1. Pre-load checks (before ModelContainer creation)
//  2. Post-load validation (after container loads successfully)
//  3. Integrity validation (document/page consistency)
//  4. Self-healing for minor fixable issues
//
//  Minor issues are automatically fixed without user intervention:
//  - totalPages mismatch → recalculate from actual page count
//  - pageNumber gaps → renumber sequentially
//  - Missing cachedStorageBytes → recalculate
//
//  Critical issues require user action:
//  - Data from newer app version (can't safely modify)
//  - Corrupted database file
//

import Foundation
import SwiftData

// MARK: - Validation Service

/// Service for schema version checking and data integrity validation.
@MainActor
enum SchemaValidationService {

    // MARK: - Pre-Load Checks

    /// Checks schema compatibility BEFORE attempting to load the ModelContainer.
    ///
    /// This check uses UserDefaults, which survives database corruption.
    /// Call this before creating the ModelContainer to catch incompatibilities early.
    ///
    /// - Returns: Result indicating compatibility status
    static func checkPreLoadCompatibility() -> PreLoadCheckResult {
        let defaults = UserDefaults.standard
        let storedVersion = defaults.integer(forKey: SchemaVersioning.userDefaultsKey)
        let hasLaunchedBefore = defaults.bool(forKey: SchemaVersioning.freshInstallKey)

        // If no stored version and never launched, it's a fresh install
        if storedVersion == 0 && !hasLaunchedBefore {
            return .compatible // Fresh install, no existing data
        }

        // If no stored version but has launched before, it's legacy data
        if storedVersion == 0 && hasLaunchedBefore {
            return .unknownLegacy // Pre-versioning data, run extra validation
        }

        // Check if data is from a newer app version
        if storedVersion > SchemaVersioning.currentVersion {
            return .newerThanApp(storedVersion: storedVersion)
        }

        // Check if data is too old
        if storedVersion < SchemaVersioning.minimumSupportedVersion {
            return .tooOld(storedVersion: storedVersion)
        }

        return .compatible
    }

    /// Records that the app has launched before (for fresh install detection).
    static func markHasLaunched() {
        UserDefaults.standard.set(true, forKey: SchemaVersioning.freshInstallKey)
    }

    /// Records the current schema version after successful container load.
    ///
    /// **Raises the stored version only, never lowers it.** This is the gate that's meant to survive database corruption, so it must not erase evidence that the store has seen a newer app.
    static func recordSuccessfulLoad() {
        let defaults = UserDefaults.standard
        let stored = defaults.integer(forKey: SchemaVersioning.userDefaultsKey)
        guard SchemaVersioning.currentVersion > stored else { return }
        defaults.set(SchemaVersioning.currentVersion, forKey: SchemaVersioning.userDefaultsKey)
    }

    // MARK: - Post-Load Validation

    /// Validates the container after successful load.
    ///
    /// Checks SchemaMetadata (if present) and runs integrity validation.
    /// Returns issues found; minor issues will be auto-fixed.
    ///
    /// - Parameter context: The model context to validate
    /// - Returns: Validation result with any issues found
    static func validatePostLoad(context: ModelContext) async -> ValidationResult {
        var issues: [IntegrityIssue] = []

        // Check SchemaMetadata for version info
        let metadataIssues = await checkSchemaMetadata(context: context)
        issues.append(contentsOf: metadataIssues)

        // Run integrity validation on all documents
        let integrityIssues = await validateAllDocuments(context: context)
        issues.append(contentsOf: integrityIssues)

        return ValidationResult(issues: issues)
    }

    /// Checks or creates SchemaMetadata for this device, returns any version-related issues.
    private static func checkSchemaMetadata(context: ModelContext) async -> [IntegrityIssue] {
        var issues: [IntegrityIssue] = []

        // Fetch all metadata records
        let descriptor = FetchDescriptor<SchemaMetadata>()
        let allMetadata = (try? context.fetch(descriptor)) ?? []

        // Find this device's metadata record
        let currentDeviceID = SchemaMetadata.currentDeviceID
        let thisDeviceMetadata = allMetadata.first { $0.deviceID == currentDeviceID }

        // Check ALL metadata records for newer schema versions as another device may have synced newer data
        for metadata in allMetadata {
            if metadata.schemaVersion > SchemaVersioning.currentVersion {
                issues.append(.newerSchemaVersion(
                    stored: metadata.schemaVersion,
                    current: SchemaVersioning.currentVersion
                ))
                break // Only need to report once
            }
        }

        if let metadata = thisDeviceMetadata {
            // Update this device's metadata
            metadata.recordSuccessfulLoad()
        } else {
            // No metadata for this device - create it
            // This happens on fresh install, new device, or pre-versioning data
            let newMetadata = SchemaMetadata()
            context.insert(newMetadata)
        }

        // Save metadata changes
        try? context.save()

        return issues
    }

    // MARK: - Integrity Validation

    /// Validates all documents in the database.
    private static func validateAllDocuments(context: ModelContext) async -> [IntegrityIssue] {
        var issues: [IntegrityIssue] = []

        let descriptor = FetchDescriptor<Document>()
        guard let documents = try? context.fetch(descriptor) else {
            return issues
        }

        for document in documents {
            let documentIssues = validateDocument(document)
            issues.append(contentsOf: documentIssues)
        }

        // Check for orphan pages (pages with no document)
        let orphanIssues = await checkForOrphanPages(context: context)
        issues.append(contentsOf: orphanIssues)

        return issues
    }

    /// Validates a single document's integrity.
    static func validateDocument(_ document: Document) -> [IntegrityIssue] {
        var issues: [IntegrityIssue] = []

        let pages = document.unwrappedPages
        let actualCount = pages.count

        // Check totalPages matches actual count
        if document.totalPages != actualCount {
            issues.append(.totalPagesMismatch(
                documentID: document.persistentModelID,
                documentName: document.name,
                stored: document.totalPages,
                actual: actualCount
            ))
        }

        // Check page numbering is sequential (1, 2, 3, ...)
        let pageNumbers = pages.map { $0.pageNumber }.sorted()
        let expectedNumbers = actualCount > 0 ? Array(1...actualCount) : []

        if pageNumbers != expectedNumbers {
            issues.append(.pageNumberingIssue(
                documentID: document.persistentModelID,
                documentName: document.name,
                found: pageNumbers,
                expected: expectedNumbers
            ))
        }

        return issues
    }

    /// Checks for pages that have no associated document.
    ///
    /// Reporting an orphan does **not** mean it's safe to delete — see `deleteQuarantinedOrphanPages(context:)` for why.
    private static func checkForOrphanPages(context: ModelContext) async -> [IntegrityIssue] {
        var issues: [IntegrityIssue] = []

        let descriptor = FetchDescriptor<Page>()
        guard let allPages = try? context.fetch(descriptor) else {
            return issues
        }

        let orphans = allPages.filter { $0.document == nil }
        if orphans.isEmpty {
            // Nothing orphaned right now, so drop every quarantine record. Without this, a page that was briefly orphaned during one launch's sync would keep its first-seen date and, if it ever looked orphaned again past the window, be deleted on sight — the exact accumulation the grace period exists to prevent. The heal pass below only runs when an orphan issue is reported, so this is the only place that can clear it.
            UserDefaults.standard.removeObject(forKey: orphanQuarantineKey)
        } else {
            issues.append(.orphanPages(count: orphans.count))
        }

        return issues
    }

    // MARK: - Self-Healing

    /// Attempts to fix minor integrity issues automatically.
    ///
    /// - Parameters:
    ///   - issues: The issues to attempt to fix
    ///   - context: The model context for making changes
    /// - Returns: Array of issues that could NOT be fixed (require user action)
    static func attemptSelfHeal(issues: [IntegrityIssue], context: ModelContext) -> [IntegrityIssue] {
        var unfixable: [IntegrityIssue] = []

        for issue in issues {
            switch issue {
            case .totalPagesMismatch(let documentID, let documentName, _, let actual):
                // Fix: Update totalPages to match actual count
                if let document = findDocument(id: documentID, context: context) {
                    document.totalPages = actual
                    print("SchemaValidation: Fixed totalPages for '\(documentName)' → \(actual)")
                }

            case .pageNumberingIssue(let documentID, let documentName, _, _):
                // Fix: Renumber pages sequentially
                if let document = findDocument(id: documentID, context: context) {
                    renumberPages(in: document)
                    print("SchemaValidation: Renumbered pages for '\(documentName)'")
                }

            case .orphanPages:
                // Fix: quarantine now, delete only after the grace period (see below).
                let deleted = deleteQuarantinedOrphanPages(context: context)
                if deleted > 0 {
                    print("SchemaValidation: Deleted \(deleted) orphan pages past the quarantine window")
                }

            case .newerSchemaVersion:
                // Cannot fix - this requires user action (update the app)
                unfixable.append(issue)
            }
        }

        // Save all fixes
        try? context.save()

        return unfixable
    }

    // MARK: - Helper Methods

    /// Resolves the exact document an issue was reported against.
    ///
    /// Deliberately by identifier, not by name
    private static func findDocument(id: PersistentIdentifier, context: ModelContext) -> Document? {
        context.model(for: id) as? Document
    }

    private static func renumberPages(in document: Document) {
        let sortedPages = document.unwrappedPages.sorted { $0.pageNumber < $1.pageNumber }
        for (index, page) in sortedPages.enumerated() {
            page.pageNumber = index + 1
        }
    }

    // MARK: - Orphan Page Quarantine

    /// UserDefaults key holding `[page uuid string: first seen orphaned]`.
    private static let orphanQuarantineKey = "multiScanOrphanPageQuarantine"

    /// How long a page must stay orphaned before deletion, when iCloud sync is on.
    ///
    /// Note that CloudKit mirrors `Page` and `Document` as separate record types and iCloud "doesn't guarantee atomic processing of relationship changes," hence this.
    private static let orphanQuarantineWindow: TimeInterval = 24 * 60 * 60

    /// Quarantines currently-orphaned pages and deletes only those that have been orphaned since before the grace window.
    ///
    /// - Returns: the number of pages actually deleted.
    @discardableResult
    private static func deleteQuarantinedOrphanPages(context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<Page>()
        guard let allPages = try? context.fetch(descriptor) else { return 0 }

        let orphans = allPages.filter { $0.document == nil }
        // With sync off there's no out-of-order delivery to wait for.
        let window = SchemaVersioning.isICloudSyncEnabled ? orphanQuarantineWindow : 0

        let defaults = UserDefaults.standard
        var quarantine = (defaults.dictionary(forKey: orphanQuarantineKey) as? [String: Date]) ?? [:]
        let now = Date()
        var stillOrphaned: Set<String> = []
        var deleted = 0

        for page in orphans {
            // The backfill that assigns uuids runs after this pass, so an orphan may not have one yet. Assign here — the quarantine needs a key that survives relaunch.
            let uuid = page.uuid ?? {
                let new = UUID()
                page.uuid = new
                return new
            }()
            let key = uuid.uuidString
            stillOrphaned.insert(key)

            let firstSeen = quarantine[key] ?? now
            quarantine[key] = firstSeen

            if now.timeIntervalSince(firstSeen) >= window {
                context.delete(page)
                quarantine.removeValue(forKey: key)
                stillOrphaned.remove(key)
                deleted += 1
            }
        }

        // Drop entries for pages that got reattached (or were deleted) — otherwise a page that is briefly orphaned on several separate launches would accumulate toward the deadline.
        quarantine = quarantine.filter { stillOrphaned.contains($0.key) }
        defaults.set(quarantine, forKey: orphanQuarantineKey)

        return deleted
    }

    // MARK: - Database Reset

    /// Deletes all data and resets the container.
    ///
    /// This is a destructive operation - use only as a last resort recovery option.
    ///
    /// - Parameter containerURL: URL to the SQLite database file
    /// - Returns: True if reset succeeded
    static func resetDatabase(containerURL: URL) -> Bool {
        let fileManager = FileManager.default

        // SwiftData/Core Data uses multiple files
        let extensions = ["", "-shm", "-wal"]
        var success = true

        for ext in extensions {
            let fileURL = containerURL.appendingPathExtension(ext.isEmpty ? "" : ext)
            if fileManager.fileExists(atPath: fileURL.path) {
                do {
                    try fileManager.removeItem(at: fileURL)
                } catch {
                    print("SchemaValidation: Failed to delete \(fileURL.lastPathComponent): \(error)")
                    success = false
                }
            }
        }

        // Also clear UserDefaults versioning
        UserDefaults.standard.removeObject(forKey: SchemaVersioning.userDefaultsKey)
        // Keep freshInstallKey set - this is no longer a fresh install

        return success
    }
}

// MARK: - Validation Result

/// Result of post-load validation.
struct ValidationResult {
    let issues: [IntegrityIssue]

    /// Whether there are issues that require user action.
    var hasCriticalIssues: Bool {
        issues.contains { $0.isCritical }
    }

    /// Whether there are minor issues that can be auto-fixed.
    var hasMinorIssues: Bool {
        issues.contains { !$0.isCritical }
    }

    /// Whether the data passed all validation checks.
    var isClean: Bool {
        issues.isEmpty
    }
}

// MARK: - Integrity Issues

/// Types of integrity issues that can be detected.
enum IntegrityIssue {
    /// Document's totalPages doesn't match actual page count.
    case totalPagesMismatch(documentID: PersistentIdentifier, documentName: String, stored: Int, actual: Int)

    /// Pages are not numbered sequentially (gaps or duplicates).
    case pageNumberingIssue(documentID: PersistentIdentifier, documentName: String, found: [Int], expected: [Int])

    /// Pages exist without an associated document.
    case orphanPages(count: Int)

    /// Data was written by a newer schema version.
    case newerSchemaVersion(stored: Int, current: Int)

    /// Whether this issue requires user action (cannot be auto-fixed).
    var isCritical: Bool {
        switch self {
        case .newerSchemaVersion:
            return true
        case .totalPagesMismatch, .pageNumberingIssue, .orphanPages:
            return false
        }
    }

    /// Human-readable description of the issue.
    var description: String {
        switch self {
        case .totalPagesMismatch(_, let name, let stored, let actual):
            return "Document '\(name)' has totalPages=\(stored) but actually has \(actual) pages"
        case .pageNumberingIssue(_, let name, let found, let expected):
            return "Document '\(name)' has page numbers \(found) but expected \(expected)"
        case .orphanPages(let count):
            return "\(count) pages found without a parent document"
        case .newerSchemaVersion(let stored, let current):
            return "Data was created by app version with schema \(stored), but this app only supports schema \(current)"
        }
    }
}
