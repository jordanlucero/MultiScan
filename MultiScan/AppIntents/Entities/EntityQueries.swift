//
//  EntityQueries.swift
//  MultiScan
//
//  Resolve entities by identifier or search string (Shortcuts, Siri), offer suggestions, answer the Shortcuts "Find…" action (`EntityPropertyQuery`), and re-donate to Spotlight when the system asks (`IndexedEntityQuery`).
//
//  The framework only *parses* a Find filter into `ComparatorMappingType` values — executing it is ours, so the filter/sort vocabulary below is handed to `ProjectStore`, which runs it against SwiftData. `EnumerableEntityQuery` is deliberately not used: the page store is unbounded.
//

import AppIntents
import CoreSpotlight
import Foundation

// MARK: - Parsed Find-action filters

/// One parsed comparator from a "Find Projects where…" filter. `Sendable` so it can cross into the
/// `ProjectStore` actor.
enum ProjectQueryFilter: Sendable {
    case nameEqualTo(String)
    case nameNotEqualTo(String)
    case nameContains(String)
    case nameHasPrefix(String)
    case pageCountEqualTo(Int)
    case pageCountGreaterThan(Int)
    case pageCountLessThan(Int)
    case createdAfter(Date)
    case createdBefore(Date)
    case modifiedAfter(Date)
    case modifiedBefore(Date)
}

/// One parsed comparator from a "Find Pages where…" filter.
enum PageQueryFilter: Sendable {
    case textContains(String)
    case projectNameEqualTo(String)
    case projectNameContains(String)
    case pageNumberEqualTo(Int)
    case pageNumberGreaterThan(Int)
    case pageNumberLessThan(Int)
    case reviewedIs(Bool)
    case modifiedAfter(Date)
    case modifiedBefore(Date)

    /// The text term, when this filter is a full-text match — the only one worth pushing down into the SwiftData fetch rather than evaluating in memory.
    var fullTextTerm: String? {
        if case .textContains(let term) = self { return term }
        return nil
    }
}

enum ProjectSortKey: Sendable { case name, pageCount, createdAt, lastModified }
enum PageSortKey: Sendable { case pageNumber, projectName, lastModified }

/// A `Sendable` stand-in for `EntityQuerySort`, which carries a non-`Sendable` `PartialKeyPath`.
struct QuerySortOrder<Key: Sendable>: Sendable {
    let key: Key
    let ascending: Bool

    /// `true`/`false` when the two values differ, `nil` when they tie so the next key can decide.
    fileprivate func resolve(_ isOrderedBefore: Bool, _ isEqual: Bool) -> Bool? {
        isEqual ? nil : (ascending ? isOrderedBefore : !isOrderedBefore)
    }
}

// MARK: - Filter / sort execution against the SwiftData models

extension ProjectQueryFilter {
    func matches(_ document: Document) -> Bool {
        switch self {
        case .nameEqualTo(let value): document.name.localizedCaseInsensitiveCompare(value) == .orderedSame
        case .nameNotEqualTo(let value): document.name.localizedCaseInsensitiveCompare(value) != .orderedSame
        case .nameContains(let value): document.name.localizedStandardContains(value)
        case .nameHasPrefix(let value): document.name.lowercased().hasPrefix(value.lowercased())
        case .pageCountEqualTo(let value): document.totalPages == value
        case .pageCountGreaterThan(let value): document.totalPages > value
        case .pageCountLessThan(let value): document.totalPages < value
        case .createdAfter(let value): document.createdAt > value
        case .createdBefore(let value): document.createdAt < value
        case .modifiedAfter(let value): document.lastModifiedDate > value
        case .modifiedBefore(let value): document.lastModifiedDate < value
        }
    }
}

extension PageQueryFilter {
    func matches(_ page: Page) -> Bool {
        switch self {
        case .textContains(let value): page.plainText.localizedStandardContains(value)
        case .projectNameEqualTo(let value):
            page.document?.name.localizedCaseInsensitiveCompare(value) == .orderedSame
        case .projectNameContains(let value):
            page.document?.name.localizedStandardContains(value) == true
        case .pageNumberEqualTo(let value): page.pageNumber == value
        case .pageNumberGreaterThan(let value): page.pageNumber > value
        case .pageNumberLessThan(let value): page.pageNumber < value
        case .reviewedIs(let value): page.isDone == value
        case .modifiedAfter(let value): page.lastModified > value
        case .modifiedBefore(let value): page.lastModified < value
        }
    }
}

extension QuerySortOrder where Key == ProjectSortKey {
    func compare(_ a: Document, _ b: Document) -> Bool? {
        switch key {
        case .name:
            let order = a.name.localizedStandardCompare(b.name)
            return resolve(order == .orderedAscending, order == .orderedSame)
        case .pageCount:
            return resolve(a.totalPages < b.totalPages, a.totalPages == b.totalPages)
        case .createdAt:
            return resolve(a.createdAt < b.createdAt, a.createdAt == b.createdAt)
        case .lastModified:
            return resolve(a.lastModifiedDate < b.lastModifiedDate, a.lastModifiedDate == b.lastModifiedDate)
        }
    }
}

extension QuerySortOrder where Key == PageSortKey {
    func compare(_ a: Page, _ b: Page) -> Bool? {
        switch key {
        case .pageNumber:
            return resolve(a.pageNumber < b.pageNumber, a.pageNumber == b.pageNumber)
        case .projectName:
            let lhs = a.document?.name ?? ""
            let rhs = b.document?.name ?? ""
            let order = lhs.localizedStandardCompare(rhs)
            return resolve(order == .orderedAscending, order == .orderedSame)
        case .lastModified:
            return resolve(a.lastModified < b.lastModified, a.lastModified == b.lastModified)
        }
    }
}

// MARK: - Project query

struct ProjectEntityQuery: EntityQuery, EntityStringQuery, IndexedEntityQuery, EntityPropertyQuery {
    typealias ComparatorMappingType = ProjectQueryFilter

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

    // MARK: EntityPropertyQuery

    // `let` + `nonisolated(unsafe)`: the App Intents metadata extractor requires the literal `= QueryProperties { … }` declaration shape (a computed getter fails extraction), and these framework builder types carry no `Sendable` conformance. They are immutable after init.
    nonisolated(unsafe) static let properties = QueryProperties {
        Property(\.$name) {
            EqualToComparator { ProjectQueryFilter.nameEqualTo($0) }
            NotEqualToComparator { ProjectQueryFilter.nameNotEqualTo($0) }
            ContainsComparator { ProjectQueryFilter.nameContains($0) }
            HasPrefixComparator { ProjectQueryFilter.nameHasPrefix($0) }
        }
        Property(\.$pageCount) {
            EqualToComparator { ProjectQueryFilter.pageCountEqualTo($0) }
            GreaterThanComparator { ProjectQueryFilter.pageCountGreaterThan($0) }
            LessThanComparator { ProjectQueryFilter.pageCountLessThan($0) }
        }
        Property(\.$createdAt) {
            GreaterThanComparator { ProjectQueryFilter.createdAfter($0) }
            LessThanComparator { ProjectQueryFilter.createdBefore($0) }
        }
        Property(\.$lastModified) {
            GreaterThanComparator { ProjectQueryFilter.modifiedAfter($0) }
            LessThanComparator { ProjectQueryFilter.modifiedBefore($0) }
        }
    }

    nonisolated(unsafe) static let sortingOptions = SortingOptions {
        SortableBy(\.$name)
        SortableBy(\.$pageCount)
        SortableBy(\.$createdAt)
        SortableBy(\.$lastModified)
    }

    func entities(
        matching comparators: [ProjectQueryFilter],
        mode: ComparatorMode,
        sortedBy: [Sort<ProjectEntity>],
        limit: Int?
    ) async throws -> [ProjectEntity] {
        await store.projectEntities(
            matching: comparators,
            matchAll: mode == .and,
            sortedBy: Self.sortOrders(sortedBy),
            limit: limit
        )
    }

    /// Maps the framework's key-path sorts onto the `Sendable` vocabulary the store understands.
    /// `SortableBy` takes the `$`-projected key path, so that is what comes back in `Sort.by`.
    private static func sortOrders(_ sorts: [Sort<ProjectEntity>]) -> [QuerySortOrder<ProjectSortKey>] {
        sorts.compactMap { sort in
            let key: ProjectSortKey?
            if sort.by == \ProjectEntity.$name { key = .name }
            else if sort.by == \ProjectEntity.$pageCount { key = .pageCount }
            else if sort.by == \ProjectEntity.$createdAt { key = .createdAt }
            else if sort.by == \ProjectEntity.$lastModified { key = .lastModified }
            else { key = nil }
            return key.map { QuerySortOrder(key: $0, ascending: sort.order == .ascending) }
        }
    }

    // MARK: IndexedEntityQuery

    func reindexEntities(for identifiers: [UUID], indexDescription: CSSearchableIndexDescription) async throws {
        await SpotlightIndexer.shared.reindex(projects: identifiers)
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        await SpotlightIndexer.shared.reindexAll()
    }
}

// MARK: - Page query

struct PageEntityQuery: EntityQuery, EntityStringQuery, IndexedEntityQuery, EntityPropertyQuery {
    typealias ComparatorMappingType = PageQueryFilter

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

    // MARK: EntityPropertyQuery

    nonisolated(unsafe) static let properties = QueryProperties {
        Property(\.$text) {
            ContainsComparator { PageQueryFilter.textContains($0) }
        }
        Property(\.$projectName) {
            EqualToComparator { PageQueryFilter.projectNameEqualTo($0) }
            ContainsComparator { PageQueryFilter.projectNameContains($0) }
        }
        Property(\.$pageNumber) {
            EqualToComparator { PageQueryFilter.pageNumberEqualTo($0) }
            GreaterThanComparator { PageQueryFilter.pageNumberGreaterThan($0) }
            LessThanComparator { PageQueryFilter.pageNumberLessThan($0) }
        }
        Property(\.$isReviewed) {
            EqualToComparator { PageQueryFilter.reviewedIs($0) }
        }
        Property(\.$lastModified) {
            GreaterThanComparator { PageQueryFilter.modifiedAfter($0) }
            LessThanComparator { PageQueryFilter.modifiedBefore($0) }
        }
    }

    nonisolated(unsafe) static let sortingOptions = SortingOptions {
        SortableBy(\.$pageNumber)
        SortableBy(\.$projectName)
        SortableBy(\.$lastModified)
    }

    func entities(
        matching comparators: [PageQueryFilter],
        mode: ComparatorMode,
        sortedBy: [Sort<PageEntity>],
        limit: Int?
    ) async throws -> [PageEntity] {
        await store.pageEntities(
            matching: comparators,
            matchAll: mode == .and,
            sortedBy: Self.sortOrders(sortedBy),
            limit: limit
        )
    }

    private static func sortOrders(_ sorts: [Sort<PageEntity>]) -> [QuerySortOrder<PageSortKey>] {
        sorts.compactMap { sort in
            let key: PageSortKey?
            if sort.by == \PageEntity.$pageNumber { key = .pageNumber }
            else if sort.by == \PageEntity.$projectName { key = .projectName }
            else if sort.by == \PageEntity.$lastModified { key = .lastModified }
            else { key = nil }
            return key.map { QuerySortOrder(key: $0, ascending: sort.order == .ascending) }
        }
    }

    // MARK: IndexedEntityQuery

    func reindexEntities(for identifiers: [UUID], indexDescription: CSSearchableIndexDescription) async throws {
        await SpotlightIndexer.shared.reindex(pages: identifiers)
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        await SpotlightIndexer.shared.reindexAll()
    }
}
