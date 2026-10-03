//
//  SharedImportInbox.swift
//  MultiScan
//
//  The hand-off between the share extension and the app.
//
//  A share extension can't run OCR or open the SwiftData store (tight memory limit, short lifetime, and the store lives in the app's own container), so it only *stages* the shared files here, in the App Group container. The app drains the inbox through `ProjectImportPipeline` the next time it is active (`SharedImportCoordinator`).
//
//  Layout: `<group container>/SharedImportInbox/<uuid>/{manifest.plist, files/…}`. A batch is written under `<uuid>.staging` and renamed once complete, so the app never sees a half-copied batch.
//

import Foundation

enum SharedImportInbox {
    static let appGroupIdentifier = "group.co.jservices.MultiScan"

    /// Darwin notification posted by the extension after committing a batch, for the case where the app is already active (iPad multitasking, a visible Mac window). Prefixed with the app group so the macOS sandbox lets it through.
    static let didChangeNotificationName = "\(appGroupIdentifier).shared-import-inbox"

    /// Opened by the share extension to bring the app forward once a batch is committed.
    static let openAppURL = URL(string: "jservicesmultiscan://shared-import")!

    enum InboxError: Error {
        /// The App Group container isn't available (missing entitlement / provisioning).
        case containerUnavailable
    }

    fileprivate struct Manifest: Codable {
        var name: String?
        var createdAt: Date
        /// File names inside `files/`, in the order they were shared.
        var fileNames: [String]
    }

    private static let manifestFileName = "manifest.plist"
    private static let filesDirectoryName = "files"
    private static let stagingSuffix = "staging"
    private static let importingSuffix = "importing"

    private static func inboxDirectory() throws -> URL {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw InboxError.containerUnavailable
        }
        let inbox = container.appendingPathComponent("SharedImportInbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    // MARK: Writing (share extension)

    /// A batch being assembled by the share extension. Invisible to the app until `commit`.
    struct StagingBatch {
        private let directory: URL
        private var fileNames: [String] = []

        fileprivate init(directory: URL) {
            self.directory = directory
        }

        private var filesDirectory: URL {
            directory.appendingPathComponent(SharedImportInbox.filesDirectoryName, isDirectory: true)
        }

        /// Moves a file into the batch, uniquing its name against the files already staged.
        mutating func add(fileAt url: URL, preferredName: String) throws {
            let name = uniqueName(for: preferredName)
            try FileManager.default.moveItem(at: url, to: filesDirectory.appendingPathComponent(name))
            fileNames.append(name)
        }

        /// Publishes the batch to the app.
        func commit(name: String?) throws {
            let manifest = Manifest(name: name, createdAt: Date(), fileNames: fileNames)
            let data = try PropertyListEncoder().encode(manifest)
            try data.write(to: directory.appendingPathComponent(SharedImportInbox.manifestFileName))
            try FileManager.default.moveItem(at: directory, to: directory.deletingPathExtension())
        }

        func discard() {
            try? FileManager.default.removeItem(at: directory)
        }

        private func uniqueName(for preferredName: String) -> String {
            guard fileNames.contains(preferredName) else { return preferredName }
            let url = URL(fileURLWithPath: preferredName)
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            var counter = 2
            while true {
                let candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
                if !fileNames.contains(candidate) { return candidate }
                counter += 1
            }
        }
    }

    static func beginBatch() throws -> StagingBatch {
        let directory = try inboxDirectory()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathExtension(stagingSuffix)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(filesDirectoryName, isDirectory: true),
            withIntermediateDirectories: true
        )
        return StagingBatch(directory: directory)
    }

    // MARK: Reading (app)

    /// A committed batch waiting to become a project.
    struct Batch: Sendable {
        fileprivate let directory: URL
        /// Project name typed in the share sheet, if any.
        let name: String?
        let createdAt: Date
        fileprivate let fileNames: [String]

        /// The shared files, in the order they were shared.
        var fileURLs: [URL] {
            let files = directory.appendingPathComponent(SharedImportInbox.filesDirectoryName, isDirectory: true)
            return fileNames.map { files.appendingPathComponent($0) }
        }

        fileprivate init(directory: URL, name: String?, createdAt: Date, fileNames: [String]) {
            self.directory = directory
            self.name = name
            self.createdAt = createdAt
            self.fileNames = fileNames
        }

        fileprivate init(directory: URL, manifest: Manifest) {
            self.init(directory: directory, name: manifest.name, createdAt: manifest.createdAt, fileNames: manifest.fileNames)
        }
    }

    /// Committed batches, oldest first. Also sweeps staging directories abandoned by an extension that was killed mid-copy.
    static func pendingBatches() -> [Batch] {
        guard let inbox = try? inboxDirectory(),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: inbox,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
              ) else { return [] }

        var batches: [Batch] = []
        for entry in entries {
            if entry.pathExtension == stagingSuffix {
                let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, modified.timeIntervalSinceNow < -24 * 60 * 60 {
                    try? FileManager.default.removeItem(at: entry)
                }
                continue
            }
            guard entry.pathExtension.isEmpty,
                  let data = try? Data(contentsOf: entry.appendingPathComponent(manifestFileName)),
                  let manifest = try? PropertyListDecoder().decode(Manifest.self, from: data) else { continue }
            batches.append(Batch(directory: entry, manifest: manifest))
        }
        return batches.sorted { $0.createdAt < $1.createdAt }
    }

    /// Marks a batch as being imported, so it is attempted **at most once**: if the import takes the app down (a huge PDF exhausting memory), the next launch discards it instead of crashing on it again.
    static func claim(_ batch: Batch) -> Batch? {
        let claimed = batch.directory.appendingPathExtension(importingSuffix)
        guard (try? FileManager.default.moveItem(at: batch.directory, to: claimed)) != nil else { return nil }
        return Batch(directory: claimed, name: batch.name, createdAt: batch.createdAt, fileNames: batch.fileNames)
    }

    /// Removes batches a previous run claimed but never finished. Call once per launch, before claiming anything.
    /// - Returns: how many were discarded.
    static func discardInterruptedBatches() -> Int {
        guard let inbox = try? inboxDirectory(),
              let entries = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) else { return 0 }
        let interrupted = entries.filter { $0.pathExtension == importingSuffix }
        for entry in interrupted {
            try? FileManager.default.removeItem(at: entry)
        }
        return interrupted.count
    }

    static func remove(_ batch: Batch) {
        try? FileManager.default.removeItem(at: batch.directory)
    }
}
