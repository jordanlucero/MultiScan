//
//  ChapterDetectorTests.swift
//  MultiScanTests
//

import Foundation
import Testing
@testable import MultiScan

@Suite("Chapter detection")
struct ChapterDetectorTests {
    let container = Fixtures.container()

    @Test func explicitChapterLines() {
        #expect(ChapterDetector.explicitChapterTitle(fromLine: "Chapter 7", nextLine: "The Return") == "Chapter 7: The Return")
        #expect(ChapterDetector.explicitChapterTitle(fromLine: "CHAPTER SEVEN", nextLine: "It was late.") == "CHAPTER SEVEN")
        #expect(ChapterDetector.explicitChapterTitle(fromLine: "Part II — Winter", nextLine: nil) == "Part II — Winter")
        #expect(ChapterDetector.explicitChapterTitle(fromLine: "XIV", nextLine: "A New Hope") == "XIV: A New Hope")
        #expect(ChapterDetector.explicitChapterTitle(fromLine: "Chapter books are great", nextLine: nil) == nil)
        #expect(ChapterDetector.explicitChapterTitle(fromLine: "He opened the part of the box", nextLine: nil) == nil)
    }

    @Test func detectsFromLinesAndHeaderRuns() {
        var pages: [ChapterDetector.PageInput] = []
        for number in 1...12 {
            var text = "Running Title\nBody of page \(number)\n\(number)"
            if number == 2 { text = "CHAPTER ONE\nThe Beginning\nBody\n2" }
            if number == 8 { text = "Chapter 2\nBody\n8" }
            pages.append(ChapterDetector.PageInput(pageNumber: number, plainText: text, visionTitle: number == 5 ? "Running Title" : nil))
        }
        let candidates = ChapterDetector.detect(pages: pages, cache: nil)
        #expect(candidates.map(\.pageNumber) == [2, 8])
        #expect(candidates[0].title == "CHAPTER ONE: The Beginning")
        #expect(candidates[0].source == .explicitLine)
    }

    @Test func headerRunsBecomeChaptersButBookTitlesDoNot() {
        // "The Book" is on every page (a running book title); "Part A" on pages 1–5, "Part B" on 6–10.
        let texts = (1...10).map { n in
            "The Book\n\(n <= 5 ? "Part A" : "Part B")\nBody line that is different on page \(n)\n\(n)"
        }
        let document = Fixtures.makeProject(texts: texts, in: container.mainContext)
        let cache = TextExportCacheService.loadFreshCache(from: document)
        let inputs = Fixtures.sortedPages(of: document).map { ChapterDetector.PageInput(pageNumber: $0.pageNumber, plainText: $0.plainText, visionTitle: nil) }
        let candidates = ChapterDetector.detect(pages: inputs, cache: cache)
        #expect(candidates.map(\.pageNumber) == [1, 6])
        #expect(candidates.map(\.title) == ["Part A", "Part B"])
        #expect(!candidates.contains { $0.title == "The Book" })

        let changed = ChapterDetector.apply(to: document)
        #expect(changed == 2)
        let pages = Fixtures.sortedPages(of: document)
        #expect(pages[0].sectionTitle == "Part A" && pages[0].sectionTitleIsAutomatic)
        #expect(pages[5].sectionTitle == "Part B")

        // A manual title survives re-detection.
        pages[5].sectionTitle = "My Part"
        pages[5].sectionTitleIsAutomatic = false
        ChapterDetector.apply(to: document)
        #expect(pages[5].sectionTitle == "My Part")
    }

    @Test func mergeCollapsesNeighborsAndPrefersStrongerSources() {
        let candidates = [
            ChapterDetector.Candidate(pageNumber: 3, title: "Header", source: .headerRun),
            ChapterDetector.Candidate(pageNumber: 3, title: "Chapter 1", source: .explicitLine),
            ChapterDetector.Candidate(pageNumber: 4, title: "Vision", source: .visionTitle),
            ChapterDetector.Candidate(pageNumber: 9, title: "Chapter 2", source: .explicitLine)
        ]
        let merged = ChapterDetector.merge(candidates)
        #expect(merged.map(\.pageNumber) == [3, 9])
        #expect(merged[0].title == "Chapter 1")
    }

    @Test func titleSuggesterDossierIsCompact() {
        let texts = ["THE GREAT BOOK\nby Someone\n\n1", "The Great Book\nChapter One\nBody\n2", "The Great Book\nMore body\n3", "The Great Book\nThe End\n4"]
        let document = Fixtures.makeProject(texts: texts, in: container.mainContext)
        let dossier = ProjectTitleSuggester.dossier(for: document)
        #expect(dossier.firstPageLines.first == "THE GREAT BOOK")
        #expect(dossier.pageCount == 4)
        #expect(dossier.repeatedHeaders.contains("The Great Book"))
        let prompt = ProjectTitleSuggester.prompt(for: dossier)
        #expect(prompt.count <= 1800)
        #expect(prompt.contains("THE GREAT BOOK"))
        #expect(ProjectTitleSuggester.cleanTitle("“Untitled”") == "")
        #expect(ProjectTitleSuggester.cleanTitle("  \"The  Great Book\" ") == "The Great Book")
    }
}
