//
//  SmartCleanupModel.swift
//  MultiScan
//
//  Owns Smart Cleanup for one project: the debounced background analysis, the resulting options, and the edits that apply them. Shared by `RichTextSidebar` (the Smart Cleanup pane on macOS/horizontal size classes) and `CompactReviewView` (the vertical size class "More" menu), which previously carried two independent implementations.
//
//  ## Where edits land
//  The current page may be open in a live `PageTextController`. When it is, its edits go through the controller so they join the editor's undo stack. Every other page is edited model-side, reading from the export cache entry rather than the page's external storage. Batch edits load the cache once, mutate every entry in memory, and save it once.
//

import Foundation
import Observation

@MainActor
@Observable
final class SmartCleanupModel {

    // MARK: - State

    /// Actionable suggestions for the page the analysis last ran on.
    private(set) var options: [TextManipulationService.CleanupOption] = []

    /// True while analysis is pending or running (including the linger delay).
    private(set) var isAnalyzing = false

    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private let document: Document

    /// How long the user must linger on a page before analysis runs. Debounces rapid flips.
    private static let lingerDelay: Duration = .seconds(3)

    init(document: Document) {
        self.document = document
    }

    // MARK: - Analysis

    /// Schedules analysis for `pageNumber` after the linger delay, cancelling any pending run.
    /// Pass `enabled: false` when the UI that shows the results is hidden.
    func scheduleAnalysis(forPage pageNumber: Int?, enabled: Bool = true) {
        analysisTask?.cancel()
        options = []

        guard enabled, let pageNumber else {
            isAnalyzing = false
            return
        }

        isAnalyzing = true
        analysisTask = Task { @MainActor in
            do {
                try await Task.sleep(for: Self.lingerDelay)
            } catch {
                return // Cancelled — the user navigated away
            }
            await analyze(pageNumber: pageNumber)
        }
    }

    /// Re-runs analysis with no delay. Used after a cleanup action so applied options disappear.
    func reanalyzeImmediately(forPage pageNumber: Int?, liveController: PageTextController? = nil) {
        analysisTask?.cancel()
        options = []

        guard let pageNumber else {
            isAnalyzing = false
            return
        }

        isAnalyzing = true
        analysisTask = Task { @MainActor in
            // Flush pending editor edits so the cache reflects the latest text
            liveController?.saveNow()
            await analyze(pageNumber: pageNumber)
        }
    }

    /// Decodes the cache and runs detection off the MainActor, then publishes the options.
    private func analyze(pageNumber: Int) async {
        guard let cacheData = document.textExportCache else {
            isAnalyzing = false
            return
        }

        // Collect fingerprints here (cheap — stored columns only) so the freshness check can run alongside the decode off the main actor. Suggesting removals from a cache that diverged from the pages would delete text the user never sees.
        let fingerprints = TextExportCacheService.fingerprints(of: document)

        let options = await Task.detached(priority: .userInitiated) {
            guard let cache = TextExportCacheService.decodeCache(from: cacheData),
                  TextExportCacheService.isFresh(cache, against: fingerprints) else {
                return [TextManipulationService.CleanupOption]()
            }
            let result = TextManipulationService.analyzeForSmartCleanup(cache: cache)
            return TextManipulationService.buildOptions(from: result, forPageNumber: pageNumber)
        }.value

        guard !Task.isCancelled else { return }
        self.options = options
        isAnalyzing = false
    }

    // MARK: - Applying options

    /// Applies a cleanup option and re-analyzes.
    ///
    /// - Parameters:
    ///   - currentPageNumber: the page shown in the editor, if any.
    ///   - liveController: the editor for that page. Edits to the current page go through it so they join its undo stack; pass `nil` (the compact layout) to edit model-side.
    /// - Returns: `true` when the current page's stored text was rewritten *behind* the editor's back, meaning the host must reload it.
    @discardableResult
    func apply(
        _ option: TextManipulationService.CleanupOption,
        currentPageNumber: Int?,
        liveController: PageTextController?
    ) -> Bool {
        var currentPageNeedsReload = false

        switch option {
        case .removePageNumber(let detection):
            currentPageNeedsReload = removeTokens(
                [detection.numberText],
                fromPage: detection.pageNumber,
                currentPageNumber: currentPageNumber,
                liveController: liveController,
                actionName: String(localized: "Remove Page Number")
            )

        case .removeSectionHeaderFromPage(let header, let pageNumber):
            currentPageNeedsReload = removeHeader(
                header.headerText,
                fromPage: pageNumber,
                currentPageNumber: currentPageNumber,
                liveController: liveController,
                actionName: String(localized: "Remove Header")
            )

        case .removeSectionHeaderFromRange(let header):
            currentPageNeedsReload = applyBatchEdit(
                toPages: header.affectedPages,
                currentPageNumber: currentPageNumber,
                liveController: liveController
            ) { text, _ in
                TextManipulationService.removeLine(matching: header.headerText, in: text, stripNumbers: true)
            }

        case .removeConsecutiveNumbers(let group, let pageNumber):
            let numberTexts = group.pageMapping[pageNumber] ?? []
            guard !numberTexts.isEmpty else { break }
            currentPageNeedsReload = removeTokens(
                numberTexts,
                fromPage: pageNumber,
                currentPageNumber: currentPageNumber,
                liveController: liveController,
                actionName: String(localized: "Remove Numbers")
            )

        case .removeConsecutiveNumbersFromRange(let group):
            currentPageNeedsReload = applyBatchEdit(
                toPages: group.pageMapping.keys.sorted(),
                currentPageNumber: currentPageNumber,
                liveController: liveController
            ) { text, pageNumber in
                for numberText in group.pageMapping[pageNumber] ?? [] {
                    TextManipulationService.removePageNumberToken(numberText, in: text)
                }
            }

        case .removeAllPageNumbers(let detections, let consecutiveGroups):
            // Collect every token to remove, per page, then apply in one batch pass
            var tokensByPage: [Int: [String]] = [:]
            for detection in detections {
                tokensByPage[detection.pageNumber, default: []].append(detection.numberText)
            }
            for group in consecutiveGroups {
                for (pageNumber, numberTexts) in group.pageMapping {
                    tokensByPage[pageNumber, default: []].append(contentsOf: numberTexts)
                }
            }
            currentPageNeedsReload = applyBatchEdit(
                toPages: tokensByPage.keys.sorted(),
                currentPageNumber: currentPageNumber,
                liveController: liveController
            ) { text, pageNumber in
                for numberText in tokensByPage[pageNumber] ?? [] {
                    TextManipulationService.removePageNumberToken(numberText, in: text)
                }
            }
        }

        // A reloaded editor has no pending edits to flush
        reanalyzeImmediately(
            forPage: currentPageNumber,
            liveController: currentPageNeedsReload ? nil : liveController
        )
        return currentPageNeedsReload
    }

    private func removeTokens(
        _ numberTexts: [String],
        fromPage pageNumber: Int,
        currentPageNumber: Int?,
        liveController: PageTextController?,
        actionName: String
    ) -> Bool {
        if pageNumber == currentPageNumber, let liveController {
            liveController.removePageNumberTokens(numberTexts, actionName: actionName)
            return false
        }
        return applyEdit(toPage: pageNumber, currentPageNumber: currentPageNumber) { text in
            for numberText in numberTexts {
                TextManipulationService.removePageNumberToken(numberText, in: text)
            }
        }
    }

    private func removeHeader(
        _ headerText: String,
        fromPage pageNumber: Int,
        currentPageNumber: Int?,
        liveController: PageTextController?,
        actionName: String
    ) -> Bool {
        if pageNumber == currentPageNumber, let liveController {
            liveController.removeLine(matching: headerText, stripNumbers: true, actionName: actionName)
            return false
        }
        return applyEdit(toPage: pageNumber, currentPageNumber: currentPageNumber) { text in
            TextManipulationService.removeLine(matching: headerText, in: text, stripNumbers: true)
        }
    }

    // MARK: - Model-side edits

    /// Applies an edit to a single page, reading from its cache entry (no page external-storage load) and writing back to both the page and the cache.
    /// - Returns: whether the edited page is the one currently in the editor.
    private func applyEdit(
        toPage pageNumber: Int,
        currentPageNumber: Int?,
        _ transform: (NSMutableAttributedString) -> Void
    ) -> Bool {
        guard let cache = TextExportCacheService.loadFreshCache(from: document, rebuildIfStale: true),
              let entry = cache.pages.first(where: { $0.pageNumber == pageNumber }),
              let decoded = entry.decodedText() else { return false }

        let working = NSMutableAttributedString(attributedString: decoded)
        transform(working)
        guard !working.isEqual(to: decoded) else { return false }

        let cleaned = NSAttributedString(attributedString: working)
        guard let page = document.unwrappedPages.first(where: { $0.pageNumber == pageNumber }) else { return false }
        page.attributedText = cleaned
        TextExportCacheService.updateEntry(
            pageNumber: pageNumber,
            attributedText: cleaned,
            pageLastModified: page.lastModified,
            in: document
        )

        return pageNumber == currentPageNumber
    }

    /// Applies edits to multiple pages efficiently: loads the cache once, modifies every entry in memory, writes each page's text, and saves the cache once.
    /// - Returns: whether the page currently in the editor was among those modified.
    private func applyBatchEdit(
        toPages pageNumbers: [Int],
        currentPageNumber: Int?,
        liveController: PageTextController?,
        _ transform: (NSMutableAttributedString, Int) -> Void
    ) -> Bool {
        liveController?.saveNow()

        guard var cache = TextExportCacheService.loadFreshCache(from: document, rebuildIfStale: true) else { return false }

        var modifiedPages: Set<Int> = []

        for pageNumber in pageNumbers {
            guard let entryIndex = cache.pages.firstIndex(where: { $0.pageNumber == pageNumber }),
                  let decoded = cache.pages[entryIndex].decodedText() else { continue }

            let working = NSMutableAttributedString(attributedString: decoded)
            transform(working, pageNumber)
            guard !working.isEqual(to: decoded) else { continue }

            let cleaned = NSAttributedString(attributedString: working)
            let page = document.unwrappedPages.first(where: { $0.pageNumber == pageNumber })
            page?.attributedText = cleaned

            cache.pages[entryIndex] = PageCacheEntry(
                pageNumber: pageNumber,
                fileName: cache.pages[entryIndex].fileName,
                attributedText: cleaned,
                pageLastModified: page?.lastModified
            )
            modifiedPages.insert(pageNumber)
        }

        TextExportCacheService.saveCache(cache, to: document)

        guard let currentPageNumber else { return false }
        return modifiedPages.contains(currentPageNumber)
    }
}
