//
//  ProjectStoreTests.swift
//  MultiScanTests
//

import Foundation
import SwiftData
import Testing
@testable import MultiScan

@Suite("Project store")
struct ProjectStoreTests {
    let container = Fixtures.container()

    @Test func snippetWindowsAroundTheMatch() {
        #expect(ProjectStore.snippet(in: "The quick brown fox jumps", matching: "brown", radius: 4) == "…ick brown fox…")
        #expect(ProjectStore.snippet(in: "brown fox", matching: "brown", radius: 4) == "brown fox")
        #expect(ProjectStore.snippet(in: "brown fox jumps", matching: "brown", radius: 2) == "brown f…")
        #expect(ProjectStore.snippet(in: "abc def", matching: "zzz", radius: 2) == "abc")
        #expect(ProjectStore.snippet(in: "Línea con acento", matching: "linea", radius: 50) == "Línea con acento")
    }

    @Test func summaryCollapsesWhitespace() {
        #expect(ProjectStore.summary(of: "a  b\n\nc") == "a b c")
        #expect(ProjectStore.summary(of: String(repeating: "x", count: 300)).count == 200)
    }

    @Test func searchFindsProjectsByNameAndPagesByText() async throws {
        let document = Fixtures.makeProject(named: "Alpha Project", texts: ["Alpha text", "Beta", "Gamma alpha"], in: container.mainContext)
        let store = ProjectStore(modelContainer: container)

        let results = await store.search(term: "alpha")
        #expect(results.term == "alpha")
        #expect(results.projects.map(\.name) == ["Alpha Project"])
        #expect(results.pages.map(\.pageNumber) == [1, 3])
        #expect(results.pages.allSatisfy { $0.projectID == document.uuid })
        #expect(results.pages[0].snippet.localizedCaseInsensitiveContains("alpha"))

        #expect(await store.search(term: "   ").isEmpty)
        #expect(await store.search(term: "nothing here").isEmpty)
    }

    @Test func entitiesAndFingerprintsDescribeTheProject() async throws {
        let document = Fixtures.makeProject(named: "Entity Project", texts: ["First page text", "Second"], in: container.mainContext)
        let uuid = try #require(document.uuid)
        let store = ProjectStore(modelContainer: container)

        let entity = try #require(await store.projectEntity(uuid: uuid))
        #expect(entity.id == uuid)
        #expect(entity.name == "Entity Project")
        #expect(entity.pageCount == 2)
        #expect(entity.summary == "First page text")

        let batch = await store.projectEntities(uuids: [uuid, UUID()])
        #expect(batch.map(\.id) == [uuid])

        let pageIDs = Fixtures.sortedPages(of: document).compactMap(\.uuid)
        let pages = await store.pageEntities(uuids: pageIDs)
        #expect(pages.map(\.pageNumber) == [1, 2])
        #expect(pages.map(\.text) == ["First page text", "Second"])

        let fingerprints = await store.fingerprints()
        #expect(fingerprints.projects[uuid] != nil)
        #expect(fingerprints.pages.count == 2)
        #expect(fingerprints.pageProject.values.allSatisfy { $0 == uuid })

        let export = try await store.projectText(uuid: uuid, options: .simple(separatePages: false))
        #expect(export.plainText == "First page text Second")
        await #expect(throws: ProjectStoreError.self) { try await store.projectText(uuid: UUID(), options: .simple(separatePages: false)) }
    }

    @Test func backfillAssignsIdentityAndRefreshesPlainText() async throws {
        let document = Fixtures.makeProject(texts: ["Real text"], in: container.mainContext)
        let page = Fixtures.sortedPages(of: document)[0]
        page.uuid = nil
        page.plainText = "stale"
        page.plainTextUpdatedAt = nil
        document.uuid = nil
        try container.mainContext.save()

        let updated = await ProjectMaintenance.backfillIdentityAndPlainText(context: container.mainContext)

        #expect(updated == 1)
        #expect(page.uuid != nil)
        #expect(document.uuid != nil)
        #expect(page.plainText == "Real text")
        #expect(page.plainTextUpdatedAt == page.lastModified)

        // Idempotent
        #expect(await ProjectMaintenance.backfillIdentityAndPlainText(context: container.mainContext) == 0)
    }

    @Test func deleteProjectsRemovesByIdentity() throws {
        let keep = Fixtures.makeProject(named: "Keep", texts: ["a"], in: container.mainContext)
        let remove = Fixtures.makeProject(named: "Remove", texts: ["b", "c"], in: container.mainContext)
        let removeID = try #require(remove.uuid)

        let deleted = try ProjectMaintenance.deleteProjects(uuids: [removeID, UUID()], context: container.mainContext)
        #expect(deleted == 1)

        let remaining = try container.mainContext.fetch(FetchDescriptor<Document>())
        #expect(remaining.map(\.name) == ["Keep"])
        #expect(ProjectMaintenance.document(uuid: keep.uuid!, context: container.mainContext) === keep)
        #expect(ProjectMaintenance.document(uuid: removeID, context: container.mainContext) == nil)
        // Cascade: the removed project's pages are gone too
        #expect(try container.mainContext.fetch(FetchDescriptor<Page>()).count == 1)
    }
}
