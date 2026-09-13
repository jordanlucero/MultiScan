//
//  EntityQueries.swift
//  MultiScan
//
//  Resolve entities by identifier or search string (Shortcuts, Siri), offer suggestions, and
//  re-donate to Spotlight when the system asks (`IndexedEntityQuery`).
//

import AppIntents
import CoreSpotlight
import Foundation

struct ProjectEntityQuery: EntityQuery, EntityStringQuery, IndexedEntityQuery {
    @Dependency var store: ProjectStore

    init() {}

    func entities(for identifiers: [UUID]) async throws -> [ProjectEntity] {
        await store.projectEntities(uuids: identifiers)
    }

    func suggestedEntities() async throws -> [ProjectEntity] {
        await store.recentProjectEntities(limit: 8)
    }

    func entities(matching string: String) async throws -> [ProjectEntity] {
        await store.projectEntities(matching: string)
    }

    // MARK: IndexedEntityQuery

    func reindexEntities(for identifiers: [UUID], indexDescription: CSSearchableIndexDescription) async throws {
        await SpotlightIndexer.shared.reindex(projects: identifiers)
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        await SpotlightIndexer.shared.reindexAll()
    }
}

struct PageEntityQuery: EntityQuery, EntityStringQuery, IndexedEntityQuery {
    @Dependency var store: ProjectStore

    init() {}

    func entities(for identifiers: [UUID]) async throws -> [PageEntity] {
        await store.pageEntities(uuids: identifiers)
    }

    func suggestedEntities() async throws -> [PageEntity] {
        await store.suggestedPageEntities(limit: 20)
    }

    func entities(matching string: String) async throws -> [PageEntity] {
        await store.pageEntities(matching: string)
    }

    // MARK: IndexedEntityQuery

    func reindexEntities(for identifiers: [UUID], indexDescription: CSSearchableIndexDescription) async throws {
        await SpotlightIndexer.shared.reindex(pages: identifiers)
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        await SpotlightIndexer.shared.reindexAll()
    }
}
