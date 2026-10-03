//
//  SharedImportCoordinator.swift
//  MultiScan
//
//  App side of the share sheet: turns batches the share extension staged in `SharedImportInbox` into projects, through the same `ProjectImportPipeline` the Home screen and "Start New Project" intent use.
//
//  Reconcile, don't hook — `drain()` is safe to call from any trigger (launch, foregrounding, the extension's Darwin notification) and runs one pass at a time.
//

import Foundation
import Observation
import SwiftUI
import notify

@Observable
final class SharedImportCoordinator {
    static let shared = SharedImportCoordinator()

    /// A shared batch is being scanned/rendered, before its project card exists (Home shows the placeholder card).
    private(set) var isPreparing = false

    /// Message of the most recent failed import; cleared by the alert that shows it.
    var errorMessage: String?

    private var isDraining = false
    private var needsAnotherPass = false
    private var hasStarted = false

    private init() {}

    /// Starts listening for the share extension and imports anything already waiting. Called once the store is known to be usable (from `ContentView`), never from the recovery screen.
    func start() {
        guard !AppModelContainer.isRunningTests else { return }
        if !hasStarted {
            hasStarted = true

            // A batch still claimed at launch means the previous run died importing it. Never retry it — that would crash every launch.
            if SharedImportInbox.discardInterruptedBatches() > 0 {
                errorMessage = String(localized: "MultiScan couldn’t finish importing the items you shared.")
            }

            var token: Int32 = 0
            notify_register_dispatch(SharedImportInbox.didChangeNotificationName, &token, .main) { _ in
                MainActor.assumeIsolated { SharedImportCoordinator.shared.drain() }
            }
        }
        drain()
    }

    func drain() {
        guard !AppModelContainer.isRunningTests else { return }
        guard !isDraining else {
            needsAnotherPass = true
            return
        }
        isDraining = true
        Task {
            repeat {
                needsAnotherPass = false
                for batch in SharedImportInbox.pendingBatches() {
                    await importBatch(batch)
                }
            } while needsAnotherPass
            isDraining = false
        }
    }

    private func importBatch(_ pending: SharedImportInbox.Batch) async {
        guard let batch = SharedImportInbox.claim(pending) else { return }
        defer { SharedImportInbox.remove(batch) }

        // The user just asked for a new project — show where it's appearing.
        AppRouter.shared.wantsHome = true

        let pipeline = ProjectImportPipeline.shared
        let optimizeImages = UserDefaults.standard.bool(forKey: DefaultsKey.optimizeImagesOnImport)

        do {
            isPreparing = true
            defer { isPreparing = false }
            let prepared = try await pipeline.prepare(urls: batch.fileURLs, optimizeImages: optimizeImages) { estimatedPageCount in
                if estimatedPageCount > 0 {
                    AccessibilityNotification.Announcement(String(localized: "Processing \(estimatedPageCount) pages. This will take a few moments.")).post()
                }
            }
            isPreparing = false

            let name = batch.name ?? prepared.suggestedName ?? ProjectImportPipeline.defaultProjectName()
            try await pipeline.createProject(named: name, images: prepared.images)
            AccessibilityNotification.Announcement(String(localized: "Scan complete. \(prepared.images.count) pages ready for review.")).post()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
