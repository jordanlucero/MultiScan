//
//  PageEntity.swift
//  MultiScan
//
//  App Intents representation of a single scanned page. Pages are indexed individually because they are where the OCR text lives: `text` maps to Spotlight's `textContent`, so searching a phrase in Spotlight lands on the page that contains it.
//
//  `id` is the CloudKit-synced `Page.uuid` — stable across devices. `SyncableEntity` is declarative only; see the note in `ProjectEntity` for why the id stays a bare `UUID`.
//
//  Isolation: the struct is main-actor isolated (project default) because `nonisolated` on the type would propagate onto the `@Property` storage, which the compiler rejects. The members App Intents, Spotlight, and Transferable call synchronously are `nonisolated`; they read the wrapped properties through their backing storage (`_pageNumber.wrappedValue`), which is a plain Sendable stored property and therefore readable from any isolation (SE-0434).
//

import AppIntents
import CoreSpotlight
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct PageEntity: IndexedEntity, SyncableEntity {
    nonisolated static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Page", comment: "App Intents type name for a scanned page"),
        numericFormat: LocalizedStringResource("\(placeholder: .int) pages", comment: "App Intents plural type name")
    )

    nonisolated static let defaultQuery = PageEntityQuery()

    let id: UUID
    let projectID: UUID

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
    let thumbnail: Data?

    nonisolated init(
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

    nonisolated var displayRepresentation: DisplayRepresentation {
        let title = LocalizedStringResource("Page \(_pageNumber.wrappedValue)", comment: "Page title in App Intents/Spotlight")
        let subtitle = _projectName.wrappedValue
        if let thumbnail {
            return DisplayRepresentation(title: title, subtitle: "\(subtitle)", image: .init(data: thumbnail))
        }
        return DisplayRepresentation(title: title, subtitle: "\(subtitle)", image: .init(systemName: "doc.text"))
    }

    // MARK: Spotlight

    nonisolated var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.contentDescription = ProjectStore.summary(of: _text.wrappedValue)
        attributes.domainIdentifier = ProjectEntity.domainIdentifier(for: projectID)
        attributes.keywords = [_projectName.wrappedValue, _fileName.wrappedValue].compactMap { $0 }.filter { !$0.isEmpty }
        return attributes
    }
}

// MARK: - Transferable

extension PageEntity: Transferable {
    nonisolated static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .rtf) { entity in
            try await ProjectStore.shared.pageRTF(uuid: entity.id)
        }

        DataRepresentation(exportedContentType: .utf8PlainText) { entity in
            Data(entity._text.wrappedValue.utf8)
        }

        DataRepresentation(exportedContentType: .jpeg) { entity in
            try await ProjectStore.shared.pageJPEG(uuid: entity.id)
        }
    }
}
