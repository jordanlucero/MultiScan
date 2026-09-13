//
//  ProjectEntity.swift
//  MultiScan
//
//  App Intents representation of a project (`Document`).
//
//  - `IndexedEntity`: donated to the Spotlight semantic index by `SpotlightIndexer`.
//  - `Transferable`: exports the whole project as RTF (file/data) or plain text, fetched lazily through `ProjectStore` — the entity itself carries only metadata.
//
//  `id` is the CloudKit-synced `Document.uuid`, so it is already stable across devices and launches.
//
//

import AppIntents
import CoreSpotlight
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct ProjectEntity: IndexedEntity, SyncableEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Project", comment: "App Intents type name for a MultiScan project"),
        numericFormat: LocalizedStringResource("\(placeholder: .int) projects", comment: "App Intents plural type name")
    )

    static let defaultQuery = ProjectEntityQuery()

    var id: UUID

    @Property(title: "Name", indexingKey: \.displayName)
    var name: String

    @Property(title: "Emoji")
    var emoji: String?

    @Property(title: "Page Count")
    var pageCount: Int

    @Property(title: "Reviewed Pages")
    var reviewedPageCount: Int

    @Property(title: "Created", indexingKey: \.contentCreationDate)
    var createdAt: Date

    @Property(title: "Last Modified", indexingKey: \.contentModificationDate)
    var lastModified: Date

    /// Opening text of the first page — what Spotlight shows under the title.
    @Property(title: "Summary", indexingKey: \.contentDescription)
    var summary: String

    /// Small JPEG cover for display representations (not a `@Property`).
    var coverThumbnail: Data?

    init(
        id: UUID,
        name: String,
        emoji: String?,
        pageCount: Int,
        reviewedPageCount: Int,
        createdAt: Date,
        lastModified: Date,
        summary: String,
        coverThumbnail: Data?
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.pageCount = pageCount
        self.reviewedPageCount = reviewedPageCount
        self.createdAt = createdAt
        self.lastModified = lastModified
        self.summary = summary
        self.coverThumbnail = coverThumbnail
    }

    // MARK: Display

    var displayTitle: String {
        let emoji = emoji ?? ""
        return emoji.isEmpty ? name : "\(emoji) \(name)"
    }

    var completionPercentage: Int {
        guard pageCount > 0 else { return 0 }
        return Int(Double(reviewedPageCount) / Double(pageCount) * 100)
    }

    var displayRepresentation: DisplayRepresentation {
        let pages = LocalizedStringResource("\(pageCount) pages", comment: "Project page count in App Intents/Spotlight")
        let subtitle = LocalizedStringResource("\(pages) · \(completionPercentage.formatted(.percent)) reviewed", comment: "Project subtitle in App Intents/Spotlight")
        if let coverThumbnail {
            return DisplayRepresentation(
                title: "\(displayTitle)",
                subtitle: subtitle,
                image: .init(data: coverThumbnail)
            )
        }
        return DisplayRepresentation(
            title: "\(displayTitle)",
            subtitle: subtitle,
            image: .init(systemName: "document.viewfinder")
        )
    }

    // MARK: Spotlight

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.keywords = [name, emoji].compactMap { $0 }.filter { !$0.isEmpty }
        attributes.domainIdentifier = Self.domainIdentifier(for: id)
        return attributes
    }

    static func domainIdentifier(for projectID: UUID) -> String {
        "project.\(projectID.uuidString)"
    }
}

// MARK: - Transferable

extension ProjectEntity: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .rtf) { entity in
            let data = try await entity.exportedText().rtfDataOrThrow()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let file = url.appendingPathComponent(entity.exportFileName).appendingPathExtension("rtf")
            try data.write(to: file)
            return SentTransferredFile(file)
        }
        .suggestedFileName { "\($0.exportFileName).rtf" }

        DataRepresentation(exportedContentType: .rtf) { entity in
            try await entity.exportedText().rtfDataOrThrow()
        }

        DataRepresentation(exportedContentType: .utf8PlainText) { entity in
            Data(try await entity.exportedText().plainText.utf8)
        }
    }

    private var exportFileName: String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Project" : cleaned
    }

    /// Builds the combined text with the user's current export separators.
    private func exportedText() async throws -> ProjectTextExport {
        let (store, options) = await MainActor.run { (ProjectStore.shared, ExportOptions.current()) }
        return try await store.projectText(uuid: id, options: options)
    }
}

extension ProjectTextExport {
    func rtfDataOrThrow() throws -> Data {
        guard !plainText.isEmpty else { throw RichTextExportError.emptyContent }
        guard let rtfData, !rtfData.isEmpty else { throw RichTextExportError.rtfConversionFailed }
        return rtfData
    }
}
