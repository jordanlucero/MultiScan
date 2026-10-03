//
//  SchemaValidationTests.swift
//  MultiScanTests
//

import Foundation
import SwiftData
import Testing
@testable import MultiScan

@Suite("Schema validation", .serialized)
struct SchemaValidationTests {
    let container = Fixtures.container()

    @Test func detectsAndHealsIntegrityIssues() {
        let document = Fixtures.makeProject(texts: ["A", "B", "C"], in: container.mainContext)
        let pages = Fixtures.sortedPages(of: document)
        document.totalPages = 5
        pages[2].pageNumber = 7 // 1, 2, 7 — a gap

        let issues = SchemaValidationService.validateDocument(document)
        #expect(issues.count == 2)
        #expect(issues.contains { if case .totalPagesMismatch(_, _, let stored, let actual) = $0 { return stored == 5 && actual == 3 } else { return false } })
        #expect(issues.contains { if case .pageNumberingIssue(_, _, let found, let expected) = $0 { return found == [1, 2, 7] && expected == [1, 2, 3] } else { return false } })
        #expect(issues.allSatisfy { !$0.isCritical })

        let unfixable = SchemaValidationService.attemptSelfHeal(issues: issues, context: container.mainContext)
        #expect(unfixable.isEmpty)
        #expect(document.totalPages == 3)
        #expect(Fixtures.sortedPages(of: document).map(\.pageNumber) == [1, 2, 3])
        #expect(SchemaValidationService.validateDocument(document).isEmpty)
    }

    @Test func newerSchemaVersionIsCriticalAndNotHealed() {
        let issue = IntegrityIssue.newerSchemaVersion(stored: 99, current: SchemaVersioning.currentVersion)
        #expect(issue.isCritical)
        #expect(SchemaValidationService.attemptSelfHeal(issues: [issue], context: container.mainContext).count == 1)
    }

    @Test func postLoadValidationCreatesMetadataForThisDevice() async throws {
        let issues = await SchemaValidationService.validatePostLoad(context: container.mainContext)
        #expect(issues.isEmpty)
        let metadata = try container.mainContext.fetch(FetchDescriptor<SchemaMetadata>())
        #expect(metadata.count == 1)
        #expect(metadata.first?.deviceID == SchemaMetadata.currentDeviceID)
        #expect(metadata.first?.schemaVersion == SchemaVersioning.currentVersion)
    }

    @Test func preLoadGateOnlyEverRises() {
        let defaults = UserDefaults.standard
        let key = SchemaVersioning.userDefaultsKey
        let original = defaults.object(forKey: key)
        defer {
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        defaults.removeObject(forKey: key)
        if case .newerThanApp = SchemaValidationService.checkPreLoadCompatibility() { Issue.record("fresh install must be compatible") }
        SchemaValidationService.recordSuccessfulLoad()
        #expect(defaults.integer(forKey: key) == SchemaVersioning.currentVersion)

        defaults.set(SchemaVersioning.currentVersion + 1, forKey: key)
        guard case .newerThanApp(let stored) = SchemaValidationService.checkPreLoadCompatibility() else {
            Issue.record("a newer stored version must gate the launch")
            return
        }
        #expect(stored == SchemaVersioning.currentVersion + 1)

        // Recording a load must never lower the gate
        SchemaValidationService.recordSuccessfulLoad()
        #expect(defaults.integer(forKey: key) == SchemaVersioning.currentVersion + 1)
    }
}
