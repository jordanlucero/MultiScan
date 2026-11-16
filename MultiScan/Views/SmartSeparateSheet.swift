//
//  SmartSeparateSheet.swift
//  MultiScan
//
//  Smart Separate after import: the one sheet behind "Separate into Two Pages…" (a page) and "Smart Separate Pages…" (the whole project).
//
//  `SmartSeparateModel` runs the flow — look for two-page scans, show what was found, separate on confirmation — and `SmartSeparateSheet` displays whichever phase it is in. Nothing is changed before the user confirms: separating replaces the text of the pages involved with a fresh reading of each half (see `PageSeparationService`), and the sheet says so, counting the pages whose text was edited or reviewed.
//
//  `ReviewView` owns the model, presents the sheet, and sets `onPageSeparated` to keep navigation on the page being viewed and rebuild its text editor when that page was one of those separated.
//

import SwiftUI
import SwiftData

@Observable
final class SmartSeparateModel {
    enum Scope: Equatable {
        case page(PersistentIdentifier)
        case project
    }

    enum Phase: Equatable {
        case idle
        /// Looking for two-page scans.
        case scanning(done: Int, total: Int)
        /// Found some; waiting for the user.
        case found
        /// Found none.
        case nothingFound
        case separating(done: Int, total: Int)
        case failed(String)
    }

    /// Drives the sheet.
    var isPresented = false
    private(set) var phase: Phase = .idle
    private(set) var scope: Scope = .project
    private(set) var candidates: [SeparationCandidate] = []

    /// Called on the main actor right after each page is separated — in the same turn as the model change, before SwiftUI draws — with the ID of the page that was split (it kept its identity as the first page of its pair). The review view uses it to keep navigation on the same page (every later page was just renumbered) and to rebuild the editor when the page on screen was the one split.
    @ObservationIgnored var onPageSeparated: ((PersistentIdentifier) -> Void)?

    @ObservationIgnored private var document: Document?
    @ObservationIgnored private var task: Task<Void, Never>?

    var editedCandidateCount: Int {
        candidates.filter(\.wasEditedOrReviewed).count
    }

    /// Whether the flow is about one page (so the "nothing found" phase can offer a manual split).
    var singlePage: Page? {
        guard case .page(let id) = scope else { return nil }
        return document?.unwrappedPages.first { $0.persistentModelID == id }
    }

    // MARK: Flow

    /// Starts looking — at one page, or at every whole-scan page of the project — and presents the sheet.
    func begin(_ scope: Scope, in document: Document) {
        task?.cancel()
        self.document = document
        self.scope = scope
        candidates = []

        let pages: [Page]
        switch scope {
        case .page(let id):
            pages = document.unwrappedPages.filter { $0.persistentModelID == id }
        case .project:
            pages = document.sortedPages.filter(PageSeparationService.canSeparate)
        }
        phase = .scanning(done: 0, total: pages.count)
        isPresented = true

        task = Task {
            var found: [SeparationCandidate] = []
            for (index, page) in pages.enumerated() {
                if Task.isCancelled { return }
                if let candidate = await PageSeparationService.candidate(for: page) {
                    found.append(candidate)
                }
                phase = .scanning(done: index + 1, total: pages.count)
            }
            guard !Task.isCancelled else { return }
            candidates = found
            phase = found.isEmpty ? .nothingFound : .found
        }
    }

    /// For a single page the layout didn't flag: offer a plain split down the middle instead.
    func useMiddleSplit() {
        guard let page = singlePage, let candidate = PageSeparationService.middleSplit(for: page) else { return }
        candidates = [candidate]
        phase = .found
    }

    /// Separates every candidate, last page first (so earlier candidates' page numbers don't move under the loop).
    func confirm() {
        guard let document, let context = document.modelContext, !candidates.isEmpty else { return }
        let work = candidates.sorted { $0.pageNumber > $1.pageNumber }
        phase = .separating(done: 0, total: work.count)

        task = Task {
            var separated: Set<PersistentIdentifier> = []
            var lastError: String?
            for (index, candidate) in work.enumerated() {
                if Task.isCancelled { break }
                do {
                    try await PageSeparationService.separate(candidate, in: document, context: context)
                    separated.insert(candidate.pageID)
                    onPageSeparated?(candidate.pageID)
                } catch is CancellationError {
                    break
                } catch {
                    lastError = error.localizedDescription
                }
                phase = .separating(done: index + 1, total: work.count)
            }
            if let lastError, separated.count < work.count {
                phase = .failed(lastError)
            } else {
                finish()
                AccessibilityNotification.Announcement(String(localized: "Separated \(separated.count) scans into two pages each.")).post()
            }
        }
    }

    /// Dismisses the sheet. Stops looking; a separation already under way for one page finishes that page (it can't be left half-applied) and then stops.
    func cancel() {
        task?.cancel()
        finish()
    }

    private func finish() {
        isPresented = false
        phase = .idle
        candidates = []
    }
}

struct SmartSeparateSheet: View {
    let model: SmartSeparateModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("Smart Separate")
                .font(.headline)

            content
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            buttons
        }
        .padding(24)
        .frame(minWidth: 320, idealWidth: 400)
        .presentationDetents([.medium])
        .interactiveDismissDisabled(isWorking)
    }

    private var isWorking: Bool {
        if case .separating = model.phase { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .scanning(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text(total == 1 ? "Looking at this scan…" : "Looking for scans that show two pages…")
            }
        case .found:
            foundMessage
        case .nothingFound:
            if model.singlePage != nil {
                Text("MultiScan didn't find two facing pages in this scan.")
                Text("If it does show two pages, you can split it down the middle instead.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("No scans in this project show two facing pages.")
            }
        case .separating(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text("Separating and reading \(done + 1 > total ? total : done + 1) of \(total)…")
            }
        case .failed(let message):
            Text("Some scans couldn't be separated.")
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var foundMessage: some View {
        let count = model.candidates.count
        if count == 1, let only = model.candidates.first {
            Text("Page \(only.pageNumber) shows two facing pages.")
        } else {
            Text("\(count) scans show two facing pages.")
        }
        Text("Each becomes two pages that share the original scan, and the text of each new page is read again.")
            .font(.callout)
            .foregroundStyle(.secondary)
        if model.editedCandidateCount > 0 {
            Label {
                Text(count == 1
                     ? "This page has been edited or reviewed. Its current text will be replaced."
                     : "\(model.editedCandidateCount) of them have been edited or reviewed. Their current text will be replaced.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.callout)
            .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            switch model.phase {
            case .found:
                Button("Cancel", role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(model.candidates.count == 1 ? "Separate" : "Separate \(model.candidates.count) Scans") { model.confirm() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            case .nothingFound:
                if model.singlePage != nil {
                    Button("Split Down the Middle") { model.useMiddleSplit() }
                }
                Button("Done") { model.cancel() }
                    .keyboardShortcut(.defaultAction)
            case .failed:
                Button("Done") { model.cancel() }
                    .keyboardShortcut(.defaultAction)
            case .scanning:
                Button("Cancel", role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            case .separating, .idle:
                EmptyView()
            }
        }
        .controlSize(.large)
    }
}
