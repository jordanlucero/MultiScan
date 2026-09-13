//
//  CreateProjectIntent.swift
//  MultiScan
//
//  "Start New Project": builds a project from images/PDFs handed in by Shortcuts or Siri and runs OCR through the same pipeline the Home screen uses. OCR of a long PDF easily exceeds the default intent time limit, so this is a `LongRunningIntent` reporting per-page progress.
//

import AppIntents
import Foundation
import UniformTypeIdentifiers

struct CreateProjectIntent: AppIntent, LongRunningIntent, CancellableIntent {
    static let title: LocalizedStringResource = "Start New Project"
    static let description = IntentDescription(
        "Creates a MultiScan project from images or PDFs and recognizes their text.",
        categoryName: "Projects"
    )
    static var supportedModes: IntentModes { .background }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(
        title: "Files",
        description: "Images or PDF documents to scan.",
        supportedContentTypes: [.image, .pdf]
    )
    var files: [IntentFile]

    @Parameter(title: "Name", description: "Project name. Defaults to the folder or file name.")
    var name: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Scan \(\.$files) into a new project") {
            \.$name
        }
    }

    @Dependency var store: ProjectStore

    /// Conforms to `CustomLocalizedStringResourceConvertible` so Siri/Shortcuts show the real
    /// message — the framework routes thrown errors by type and genericizes a plain `Error`.
    enum CreateProjectError: Error, CustomLocalizedStringResourceConvertible {
        case nothingToScan
        case projectUnavailable

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .nothingToScan: "No images or PDF pages were found to scan."
            case .projectUnavailable: "The project was created but could not be loaded."
            }
        }
    }

    @MainActor
    func perform() async throws -> some ReturnsValue<ProjectEntity> & ProvidesDialog {
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("intent-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        let files = self.files
        let requestedName = self.name
        let progress = self.progress
        let optimizeImages = UserDefaults.standard.bool(forKey: "optimizeImagesOnImport")

        let projectID: UUID = try await performBackgroundTask { @MainActor @Sendable in
            // `stageFiles` is nonisolated, so the copy/write loop runs off the main actor.
            let urls = try await Self.stageFiles(files, in: stagingDirectory)

            let pipeline = ProjectImportPipeline.shared
            let prepared = try await pipeline.prepare(urls: urls, optimizeImages: optimizeImages) { estimate in
                progress.totalUnitCount = Int64(max(estimate, 1))
            }
            guard !prepared.images.isEmpty else { throw CreateProjectError.nothingToScan }

            let total = Int64(prepared.images.count)
            progress.totalUnitCount = total

            let trimmedName = requestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let projectName = trimmedName.isEmpty
                ? (prepared.suggestedName ?? ProjectImportPipeline.defaultProjectName())
                : trimmedName

            return try await pipeline.createProject(named: projectName, images: prepared.images) { fraction in
                progress.completedUnitCount = Int64((fraction * Double(total)).rounded(.down))
            }
        } onCancel: { _ in
            // The OCR loop observes task cancellation; the staging directory is removed by `defer`.
        }

        guard let entity = await store.projectEntity(uuid: projectID) else {
            throw CreateProjectError.projectUnavailable
        }
        return .result(
            value: entity,
            dialog: IntentDialog("Created “\(entity.name)” with \(entity.pageCount) pages.")
        )
    }

    /// Copies the incoming `IntentFile`s into a staging directory. Plain disk I/O — deliberately nonisolated so a large PDF handed in by Shortcuts doesn't block the main actor.
    private static func stageFiles(_ files: [IntentFile], in directory: URL) async throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (index, file) in files.enumerated() {
            let fileName = file.filename.isEmpty ? "file-\(index + 1)" : file.filename
            let destination = directory.appendingPathComponent(fileName)
            if let sourceURL = file.fileURL {
                let accessed = sourceURL.startAccessingSecurityScopedResource()
                defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
                try FileManager.default.copyItem(at: sourceURL, to: destination)
            } else {
                try file.data.write(to: destination)
            }
            urls.append(destination)
        }
        return urls
    }
}
