//
//  ShareModel.swift
//  MultiScanShare
//
//  State for the share sheet UI: collects the shared images/PDFs, stages them in `SharedImportInbox`, and hands off to the app. No OCR and no SwiftData here — see SharedImportInbox.swift for why.
//

import CoreTransferable
import Foundation
import Observation
import UniformTypeIdentifiers
import notify

@MainActor
@Observable
final class ShareModel {
    enum Phase: Equatable {
        case sending(completed: Int)
        /// Staged, but the app couldn't be brought forward — the user has to open it.
        case finished
        case failed
    }

    private(set) var phase: Phase = .sending(completed: 0)

    var itemCount: Int { providers.count }

    /// Project name; `nil` means the app picks its default.
    private let name: String?

    private let extensionContext: NSExtensionContext?
    private let providers: [NSItemProvider]
    private let openApp: @MainActor (URL) async -> Bool
    private var hasStarted = false

    /// - Parameter openApp: Brings MultiScan forward; platform-specific, so the view controller supplies it.
    init(extensionContext: NSExtensionContext?, openApp: @escaping @MainActor (URL) async -> Bool) {
        self.extensionContext = extensionContext
        self.openApp = openApp

        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        providers = items
            .flatMap { $0.attachments ?? [] }
            .filter { provider in
                SharedFile.contentTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
            }

        // A single shared file names the project, like a single folder does for an in-app import.
        if providers.count == 1, let suggested = providers[0].suggestedName, !suggested.isEmpty {
            name = URL(fileURLWithPath: suggested).deletingPathExtension().lastPathComponent
        } else {
            name = nil
        }

        if providers.isEmpty { phase = .failed }
    }

    /// Stages the shared files and hands off to the app. There is nothing to confirm, so this starts as soon as the sheet appears and the sheet only stays up as long as the copy takes.
    func send() async {
        guard !hasStarted, phase != .failed else { return }
        hasStarted = true

        var staging: SharedImportInbox.StagingBatch?
        do {
            var batch = try SharedImportInbox.beginBatch()
            staging = batch
            for (index, provider) in providers.enumerated() {
                let file = try await Self.loadFile(from: provider)
                try batch.add(fileAt: file.url, preferredName: Self.fileName(for: file, suggestedName: provider.suggestedName))
                phase = .sending(completed: index + 1)
            }
            try batch.commit(name: name)
        } catch {
            staging?.discard()
            phase = .failed
            return
        }

        // Wakes the app's inbox drain if it is already active.
        notify_post(SharedImportInbox.didChangeNotificationName)

        if await openApp(SharedImportInbox.openAppURL) {
            finish()
        } else {
            phase = .finished
        }
    }

    func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    func cancel() {
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    private static func loadFile(from provider: NSItemProvider) async throws -> SharedFile {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: SharedFile.self) { result in
                continuation.resume(with: result)
            }
        }
    }

    /// Prefers the provider's display name (data-backed items arrive as generically named temp files), keeping the real file's extension so the app can identify its type.
    private static func fileName(for file: SharedFile, suggestedName: String?) -> String {
        let actualName = file.url.lastPathComponent
        guard let suggestedName, !suggestedName.isEmpty else { return actualName }
        let fileExtension = file.url.pathExtension
        if fileExtension.isEmpty || URL(fileURLWithPath: suggestedName).pathExtension.caseInsensitiveCompare(fileExtension) == .orderedSame {
            return suggestedName
        }
        return "\(suggestedName).\(fileExtension)"
    }
}

/// A shared image or PDF, received as a file so large PDFs are copied rather than loaded into the extension's limited memory.
private struct SharedFile: Transferable {
    static let contentTypes: [UTType] = [.pdf, .image]

    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .pdf) { try SharedFile(copying: $0.file) }
        FileRepresentation(importedContentType: .image) { try SharedFile(copying: $0.file) }
    }

    /// The received file only lives for the duration of the import closure.
    private init(copying source: URL) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
    }
}
