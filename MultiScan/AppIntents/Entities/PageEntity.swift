//
//  PageEntity.swift
//  MultiScan
//
//  App Intents representation of a single scanned page. Pages are indexed individually because they are where the OCR text lives: `text` maps to Spotlight's `textContent`, so searching a phrase in Spotlight lands on the page that contains it.
//
//  `id` is the CloudKit-synced `Page.uuid` — stable across devices. `SyncableEntity` is declarative only; see the note in `ProjectEntity` for why the id stays a bare `UUID`.
//

import AppIntents
import CoreSpotlight
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct PageEntity: IndexedEntity, SyncableEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Page", comment: "App Intents type name for a scanned page"),
        numericFormat: LocalizedStringResource("\(placeholder: .int) pages", comment: "App Intents plural type name")
    )

    static let defaultQuery = PageEntityQuery()

    var id: UUID
    var projectID: UUID

    @Property(title: "Page Number")
    var pageNumber: Int

    @Property(title: "Project Name")
    var projectName: String

    @Property(title: "Reviewed")
    var isReviewed: Bool

    @Property(title: "File Name")
    var fileName: String?

    /// Recognized text (from the stored `Page.plainText` column — no RTF decoding at index time).
    @Property(title: "Text", indexingKey: \.textContent)
    var text: String

    @Property(title: "Last Modified", indexingKey: \.contentModificationDate)
    var lastModified: Date

    /// Small JPEG thumbnail for display representations (not a `@Property`).
    var thumbnail: Data?

    init(
        id: UUID,
        projectID: UUID,
        pageNumber: Int,
        projectName: String,
        isReviewed: Bool,
        fileName: String?,
        text: String,
        lastModified: Date,
        thumbnail: Data?
    ) {
        self.id = id
        self.projectID = projectID
        self.pageNumber = pageNumber
        self.projectName = projectName
        self.isReviewed = isReviewed
        self.fileName = fileName
        self.text = text
        self.lastModified = lastModified
        self.thumbnail = thumbnail
    }

    // MARK: Display

    var displayRepresentation: DisplayRepresentation {
        let title = LocalizedStringResource("Page \(pageNumber)", comment: "Page title in App Intents/Spotlight")
        if let thumbnail {
            return DisplayRepresentation(title: title, subtitle: "\(projectName)", image: .init(data: thumbnail))
        }
        return DisplayRepresentation(title: title, subtitle: "\(projectName)", image: .init(systemName: "doc.text"))
    }

    // MARK: Spotlight

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.contentDescription = ProjectStore.summary(of: text)
        attributes.domainIdentifier = ProjectEntity.domainIdentifier(for: projectID)
        attributes.keywords = [projectName, fileName].compactMap { $0 }.filter { !$0.isEmpty }
        return attributes
    }
}

// MARK: - Transferable

extension PageEntity: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .rtf) { entity in
            let store = await MainActor.run { ProjectStore.shared }
            return try await store.pageRTF(uuid: entity.id)
        }

        DataRepresentation(exportedContentType: .utf8PlainText) { entity in
            Data(entity.text.utf8)
        }

        DataRepresentation(exportedContentType: .jpeg) { entity in
            let store = await MainActor.run { ProjectStore.shared }
            return try await store.pageJPEG(uuid: entity.id)
        }
    }
}
