//
//  ProjectTitleSuggester.swift
//  MultiScan
//
//  Proposes a project name from the scanned text, using the on-device Apple Foundation Model.
//
//  ## How a title is chosen
//  The model never sees whole pages (the on-device context window is 4096 tokens and OCR output is noisy). Instead MultiScan assembles a short *dossier* of the strings most likely to be the title, then asks the model to pick/compose one:
//  - the first non-empty lines of the first two pages (title pages, half-titles) and of the last page (colophons often restate the title);
//  - Vision's `title` detections on the first three pages;
//  - lines that repeat across many pages — running headers, found by the same analysis Smart Cleanup uses (`detectSectionHeaders`); a book's own title typically alternates with chapter titles in the header;
//  - chapter starts already detected (`Page.sectionTitle`), as negative examples: those are chapters, not the book;
//  - the folder/file name hint, if any.
//  Guided generation (`@Generable`) returns a `title` plus a confidence; low confidence or an empty answer leaves the default name in place.
//
//  ## When it runs
//  Only on a **new import** whose name is the placeholder ("Import <date>"), when the user has the setting on and `SystemLanguageModel.default.availability == .available`. Never on renames, never on existing projects, never when the import came with a human-chosen name (a picked folder, the share sheet's title). The result is marked `Document.isAutoTitled`; a manual rename clears the flag.
//
//  `#if canImport(FoundationModels)` guards the model code so the file compiles on any SDK; the dossier builder is plain Swift and unit-tested.
//

import Foundation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

nonisolated enum ProjectTitleSuggester {
    private static let logger = Logger(subsystem: "co.jservices.MultiScan", category: "ProjectTitleSuggester")

    /// The compact evidence handed to the model.
    struct Dossier: Sendable, Equatable {
        var firstPageLines: [String] = []
        var secondPageLines: [String] = []
        var lastPageLines: [String] = []
        var visionTitles: [String] = []
        var repeatedHeaders: [String] = []
        var chapterTitles: [String] = []
        var fileNameHint: String?
        var pageCount: Int = 0

        var isEmpty: Bool {
            firstPageLines.isEmpty && visionTitles.isEmpty && repeatedHeaders.isEmpty && lastPageLines.isEmpty
        }
    }

    // MARK: Dossier

    /// Builds the dossier from stored columns and the export cache (no external reads of page text).
    @MainActor
    static func dossier(for document: Document) -> Dossier {
        let pages = document.sortedPages
        var dossier = Dossier()
        dossier.pageCount = pages.count
        dossier.fileNameHint = pages.first?.originalFileName

        if let first = pages.first { dossier.firstPageLines = leadingLines(of: first.plainText, limit: 8) }
        if pages.count > 1 { dossier.secondPageLines = leadingLines(of: pages[1].plainText, limit: 5) }
        if let last = pages.last, pages.count > 2 { dossier.lastPageLines = leadingLines(of: last.plainText, limit: 5) }
        dossier.visionTitles = pages.prefix(3).compactMap { $0.visionLayout?.title?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        dossier.chapterTitles = Array(pages.compactMap(\.sectionTitle).prefix(8))

        if let cache = TextExportCacheService.loadFreshCache(from: document) {
            dossier.repeatedHeaders = repeatedHeaders(in: cache, pageCount: pages.count)
        }
        return dossier
    }

    /// Lines that recur across pages, most widespread first — the running-header candidates.
    static func repeatedHeaders(in cache: TextExportCache, pageCount: Int, limit: Int = 6) -> [String] {
        let analysis = TextManipulationService.analyzeForSmartCleanup(cache: cache)
        return analysis.sectionHeaders
            .sorted { $0.affectedPages.count > $1.affectedPages.count }
            .map { ChapterDetector.cleanedTitle($0.displayText) }
            .filter { $0.count >= 3 }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .prefix(limit)
            .map { $0 }
    }

    /// First `limit` non-empty, non-page-number lines, each trimmed and capped at 120 characters.
    static func leadingLines(of text: String, limit: Int) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && TextManipulationService.extractPageNumber(from: $0) == nil }
            .prefix(limit)
            .map { String($0.prefix(120)) }
    }

    /// The prompt body. Kept well under ~1500 characters so the whole exchange fits the 4096-token on-device window with room for the schema.
    static func prompt(for dossier: Dossier) -> String {
        func section(_ name: String, _ lines: [String]) -> String {
            guard !lines.isEmpty else { return "" }
            return "\(name):\n" + lines.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        var text = "A person scanned a \(dossier.pageCount)-page printed document. Pick the document's real title from the evidence below.\n\n"
        text += section("First page, first lines", dossier.firstPageLines)
        text += section("Second page, first lines", dossier.secondPageLines)
        text += section("Last page, first lines", dossier.lastPageLines)
        text += section("Lines Vision marked as titles", dossier.visionTitles)
        text += section("Lines repeated on many pages (running headers)", dossier.repeatedHeaders)
        text += section("Chapter titles (NOT the document title)", dossier.chapterTitles)
        if let hint = dossier.fileNameHint { text += "File name: \(hint)\n" }
        text += "\nAnswer with the title as it would appear on the cover, in title case, without the author or a subtitle unless the title alone is ambiguous. If nothing here is clearly a title, answer with an empty title and confidence 0."
        return String(text.prefix(1800))
    }

    // MARK: Model

    /// Whether the on-device model can run here right now.
    static var isModelAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
        #else
        return false
        #endif
    }

    #if canImport(FoundationModels)
    @Generable(description: "A document title proposal")
    struct TitleSuggestion {
        @Guide(description: "The document's title in title case, at most 60 characters. Empty when no title is evident.")
        var title: String
        @Guide(description: "Confidence from 0 (guess) to 100 (the title appears verbatim in the evidence).", .range(0...100))
        var confidence: Int
    }
    #endif

    /// Asks the model. Returns nil when unavailable, uncertain, or on any error — callers keep the default name.
    static func suggestTitle(from dossier: Dossier, minimumConfidence: Int = 55) async -> String? {
        guard !dossier.isEmpty else { return nil }
        #if canImport(FoundationModels)
        guard isModelAvailable else { return nil }
        do {
            let session = LanguageModelSession(instructions: """
                You name scanned documents. You only ever answer with the document's title taken from the evidence; you never invent one. Prefer a line that appears both on the first page and in the running headers.
                """)
            let promptText = prompt(for: dossier)
            // Builder form: a `String` expression inside the closure becomes the Prompt (a bare String isn't a `Prompt` argument).
            let response = try await session.respond(
                generating: TitleSuggestion.self,
                options: GenerationOptions(samplingMode: .greedy)
            ) {
                promptText
            }
            let suggestion = response.content
            let cleaned = cleanTitle(suggestion.title)
            guard !cleaned.isEmpty, suggestion.confidence >= minimumConfidence else { return nil }
            return cleaned
        } catch {
            logger.error("Title suggestion failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Trims quotes/whitespace, rejects placeholders, caps length.
    static func cleanTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’«»"))
        title = title.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        let rejected: Set<String> = ["", "untitled", "unknown", "document", "title", "none", "n/a"]
        if rejected.contains(title.lowercased()) { return "" }
        if title.count > 60 { title = String(title.prefix(59)) + "…" }
        return title
    }

    // MARK: Apply

    /// Full flow for a freshly imported project: build the dossier, ask the model, rename if confident. Safe to call fire-and-forget; it re-checks that the name is still the placeholder before writing, so a user who renamed first wins.
    @MainActor
    static func suggestAndApply(to document: Document, placeholderName: String) async {
        guard UserDefaults.standard.object(forKey: DefaultsKey.autoTitleProjects) == nil || UserDefaults.standard.bool(forKey: DefaultsKey.autoTitleProjects) else { return }
        guard isModelAvailable else { return }
        let dossier = dossier(for: document)
        guard let title = await suggestTitle(from: dossier) else { return }
        guard document.name == placeholderName else { return } // renamed meanwhile
        guard title.lowercased() != document.name.lowercased() else { return }
        document.name = title
        document.isAutoTitled = true
        document.lastModified = Date()
        try? document.modelContext?.save()
        MultiScanShortcuts.updateAppShortcutParameters()
        logger.info("Auto-titled project as \(title, privacy: .public)")
    }
}
