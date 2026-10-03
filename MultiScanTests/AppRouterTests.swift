//
//  AppRouterTests.swift
//  MultiScanTests
//

import Foundation
import Testing
@testable import MultiScan

@Suite("App router")
struct AppRouterTests {
    let container = Fixtures.container()

    @Test func openRequestsAreDistinctEvenForTheSameTarget() {
        let router = AppRouter()
        let project = UUID()
        router.open(project: project, page: 3)
        let first = router.openRequest
        router.open(project: project, page: 3)
        #expect(first != router.openRequest)
        #expect(router.openRequest?.projectUUID == project)
        #expect(router.openRequest?.pageNumber == 3)

        router.consumeOpenRequest()
        #expect(router.openRequest == nil)
    }

    @Test func showSearchReturnsHomeWithTheTerm() {
        let router = AppRouter()
        router.open(project: UUID())
        router.showSearch("receipts")
        #expect(router.openRequest == nil)
        #expect(router.wantsHome)
        #expect(router.searchText == "receipts")
        #expect(router.isSearchPresented)
    }

    @Test func fulfillingARequestNavigatesAndConsumesOnlyMatchingProjects() throws {
        let document = Fixtures.makeProject(texts: ["A", "B", "C"], in: container.mainContext)
        let state = NavigationState(settings: NavigationSettings(defaults: Fixtures.defaults("router")))
        state.setupNavigation(for: document)
        let router = AppRouter()

        router.open(project: UUID(), page: 2)
        router.fulfillOpenRequest(for: document, navigationState: state)
        #expect(router.openRequest != nil) // someone else's project
        #expect(state.currentPageNumber == 1)

        router.open(project: try #require(document.uuid), page: 3)
        router.fulfillOpenRequest(for: document, navigationState: state)
        #expect(router.openRequest == nil)
        #expect(state.currentPageNumber == 3)
    }
}
