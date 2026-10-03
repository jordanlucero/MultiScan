//
//  TestSupport.swift
//  MultiScanTests
//
//  In-memory SwiftData fixtures. Every test builds its own container, so suites run in parallel without sharing state. The app itself opens an in-memory store under test (`AppModelContainer.isRunningTests`), so the user's real projects are never touched.
//

import Foundation
import SwiftData
import Testing
@testable import MultiScan

enum Fixtures {
    /// A fresh in-memory container (CloudKit off).
    static func container() -> ModelContainer {
        previewContainer()
    }

    /// A project with one page per entry of `texts`, inserted, cached, and saved.
    @discardableResult
    static func makeProject(named name: String = "Test Project", texts: [String], in context: ModelContext) -> Document {
        let document = Document(name: name, totalPages: texts.count)
        context.insert(document)
        for (index, text) in texts.enumerated() {
            let page = Page(pageNumber: index + 1, text: text, imageData: nil, originalFileName: "page-\(index + 1).jpg")
            page.document = document
            document.pages?.append(page)
        }
        TextExportCacheService.buildInitialCache(for: document, from: document.unwrappedPages)
        try? context.save()
        return document
    }

    /// Pages sorted by page number.
    static func sortedPages(of document: Document) -> [Page] {
        document.unwrappedPages.sorted { $0.pageNumber < $1.pageNumber }
    }

    /// A throwaway UserDefaults suite, cleared before use.
    static func defaults(_ name: String) -> UserDefaults {
        let suite = "co.jservices.MultiScanTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
