//
//  SpotlightIndexer.swift
//  MultiScan
//
//  Keeps the Spotlight index (App Intents `IndexedEntity` donations) in step with the database.
//
//  Rather than wiring index updates into every write site (text saves, reorders, deletes, imports, CloudKit imports have none), the indexer periodically diffs the database against a small local **manifest** of what it has indexed. Each row is reduced to a deterministic fingerprint string (`ProjectStore.fingerprints()`); rows whose fingerprint changed are re-donated, rows that vanished are deleted, everything else is skipped. Triggers: `ModelContext.didSave`, CloudKit remote-change notifications, app foregrounding, and the post-launch backfill.
//

import Foundation
import CoreSpotlight
import CoreData
import SwiftData
import os

actor SpotlightIndexer {
    static let shared = SpotlightIndexer()

    /// Named index (Apple: use the default index only for prototyping).
    static let indexName = "MultiScan"

    private static let logger = Logger(subsystem: "co.jservices.MultiScan", category: "SpotlightIndexer")

    /// Entities per `indexAppEntities` call.
    private static let batchSize = 200

    /// Coalesces bursts of save notifications (typing autosaves every second).
    private static let debounce: Duration = .seconds(2)

    /// A fresh handle per call: `CSSearchableIndex` is not Sendable, and each async call sends it away.
    private static var index: CSSearchableIndex { CSSearchableIndex(name: indexName) }

    // MARK: Manifest

    private struct Manifest: Codable {
        static let currentVersion = 1
        var version = currentVersion
        /// uuidString → fingerprint
        var projects: [String: String] = [:]
        var pages: [String: String] = [:]
    }

    private var manifest: Manifest?
    private var pendingReconcile: Task<Void, Never>?
    private var isReconciling = false
    private var needsAnotherPass = false

    private static var manifestURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MultiScan", isDirectory: true)
            .appendingPathComponent("spotlight-manifest.plist")
    }

    private func loadManifest() -> Manifest {
        if let manifest { return manifest }
        let loaded: Manifest
        if let data = try? Data(contentsOf: Self.manifestURL),
           let decoded = try? PropertyListDecoder().decode(Manifest.self, from: data),
           decoded.version == Manifest.currentVersion {
            loaded = decoded
        } else {
            loaded = Manifest()
        }
        manifest = loaded
        return loaded
    }

    private func saveManifest(_ manifest: Manifest) {
        self.manifest = manifest
        do {
            let url = Self.manifestURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(manifest).write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Failed to save manifest: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func clearManifest() {
        manifest = Manifest()
        try? FileManager.default.removeItem(at: Self.manifestURL)
    }

    // MARK: Triggers

    @MainActor private static var triggersInstalled = false

    /// Observes saves and remote changes; call once at launch.
    @MainActor
    static func installTriggers() {
        guard !triggersInstalled else { return }
        triggersInstalled = true

        let center = NotificationCenter.default
        center.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { _ in
            Task { await SpotlightIndexer.shared.scheduleReconcile() }
        }
        // SwiftData has no public remote-change notification; its store posts Core Data's.
        center.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: nil) { _ in
            Task { await SpotlightIndexer.shared.scheduleReconcile() }
        }
    }

    /// Debounced reconcile request.
    func scheduleReconcile() {
        pendingReconcile?.cancel()
        pendingReconcile = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.reconcile()
        }
    }

    // MARK: Public operations

    /// Diffs the database against the manifest and applies the difference to the index.
    func reconcile() async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        if isReconciling {
            needsAnotherPass = true
            return
        }
        isReconciling = true
        defer { isReconciling = false }

        repeat {
            needsAnotherPass = false
            await reconcileOnce()
        } while needsAnotherPass
    }

    /// Re-donates specific projects (and their pages) — `IndexedEntityQuery.reindexEntities`.
    func reindex(projects ids: [UUID]) async {
        var manifest = loadManifest()
        for id in ids { manifest.projects[id.uuidString] = nil }
        let store = await MainActor.run { ProjectStore.shared }
        let fingerprints = await store.fingerprints()
        let projectSet = Set(ids)
        for (pageID, projectID) in fingerprints.pageProject where projectSet.contains(projectID) {
            manifest.pages[pageID.uuidString] = nil
        }
        saveManifest(manifest)
        await reconcile()
    }

    /// Re-donates specific pages — `IndexedEntityQuery.reindexEntities`.
    func reindex(pages ids: [UUID]) async {
        var manifest = loadManifest()
        for id in ids { manifest.pages[id.uuidString] = nil }
        saveManifest(manifest)
        await reconcile()
    }

    /// Drops everything and rebuilds — `IndexedEntityQuery.reindexAllEntities`.
    func reindexAll() async {
        do {
            try await Self.index.deleteAllSearchableItems()
        } catch {
            Self.logger.error("deleteAllSearchableItems failed: \(error.localizedDescription, privacy: .public)")
        }
        clearManifest()
        await reconcile()
    }

    // MARK: Reconcile pass

    private func reconcileOnce() async {
        let store = await MainActor.run { ProjectStore.shared }
        let current = await store.fingerprints()
        var manifest = loadManifest()

        let deletedPages = manifest.pages.keys.compactMap { key -> UUID? in
            guard let id = UUID(uuidString: key), current.pages[id] == nil else { return nil }
            return id
        }
        let deletedProjects = manifest.projects.keys.compactMap { key -> UUID? in
            guard let id = UUID(uuidString: key), current.projects[id] == nil else { return nil }
            return id
        }
        let changedProjects = current.projects.filter { manifest.projects[$0.key.uuidString] != $0.value }.map(\.key)
        let changedPages = current.pages.filter { manifest.pages[$0.key.uuidString] != $0.value }.map(\.key)

        guard !deletedPages.isEmpty || !deletedProjects.isEmpty || !changedProjects.isEmpty || !changedPages.isEmpty else {
            return
        }
        Self.logger.info("Reconcile: +\(changedProjects.count) projects, +\(changedPages.count) pages, -\(deletedProjects.count) projects, -\(deletedPages.count) pages")

        do {
            // Deletions first so a page that moved between projects is never briefly duplicated.
            if !deletedPages.isEmpty {
                try await Self.index.deleteAppEntities(identifiedBy: deletedPages, ofType: PageEntity.self)
                for id in deletedPages { manifest.pages[id.uuidString] = nil }
                saveManifest(manifest)
            }
            if !deletedProjects.isEmpty {
                try await Self.index.deleteAppEntities(identifiedBy: deletedProjects, ofType: ProjectEntity.self)
                for id in deletedProjects { manifest.projects[id.uuidString] = nil }
                saveManifest(manifest)
            }

            // Projects (few) in one batch.
            if !changedProjects.isEmpty {
                let entities = await store.projectEntities(uuids: changedProjects)
                try await Self.index.indexAppEntities(entities)
                for entity in entities { manifest.projects[entity.id.uuidString] = current.projects[entity.id] }
                saveManifest(manifest)
            }

            // Pages in batches, fetched by owning project. Manifest is saved after every batch so a crash mid-pass only redoes the remainder.
            var batch: [UUID] = []
            batch.reserveCapacity(Self.batchSize)
            for pageID in changedPages {
                batch.append(pageID)
                if batch.count == Self.batchSize {
                    try await indexPages(batch, fingerprints: current, manifest: &manifest, store: store)
                    batch.removeAll(keepingCapacity: true)
                }
            }
            if !batch.isEmpty {
                try await indexPages(batch, fingerprints: current, manifest: &manifest, store: store)
            }
        } catch {
            Self.logger.error("Reconcile failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func indexPages(
        _ ids: [UUID],
        fingerprints: IndexFingerprints,
        manifest: inout Manifest,
        store: ProjectStore
    ) async throws {
        var groups: [UUID: [UUID]] = [:]
        for id in ids {
            guard let projectID = fingerprints.pageProject[id] else { continue }
            groups[projectID, default: []].append(id)
        }
        let entities = await store.pageEntities(byProject: groups)
        guard !entities.isEmpty else { return }
        try await Self.index.indexAppEntities(entities)
        for entity in entities { manifest.pages[entity.id.uuidString] = fingerprints.pages[entity.id] }
        saveManifest(manifest)
    }
}
