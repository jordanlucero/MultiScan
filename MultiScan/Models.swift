//
//  Models.swift
//  MultiScan
//
//  Created by Jordan Lucero on 5/23/25.
//

import Foundation
import SwiftData
import CoreGraphics
import SwiftUI

@Model
final class Page {
    // MARK: - CloudKit Compatibility
    // All properties must have default values for CloudKit sync.
    // Relationships must be optional.

    var pageNumber: Int = 0
    var document: Document?
    var createdAt: Date = Date()
    var isDone: Bool = false
    var thumbnailData: Data?
    var boundingBoxesData: Data? // Encoded array of CGRect from VisionKit
    var lastModified: Date = Date()

    /// User rotation in degrees (0, 90, 180, 270) - non-destructive, applied at display time
    var rotation: Int = 0

    /// Toggle for increased contrast display adjustment
    var increaseContrast: Bool = false

    /// Toggle for increased black point display adjustment
    var increaseBlackPoint: Bool = false

    /// Original filename for display purposes
    var originalFileName: String?

    /// Full image data stored externally for efficiency
    @Attribute(.externalStorage)
    var imageData: Data?

    /// Rich text content stored as JSON-encoded Data for CloudKit compatibility.
    /// Use the `richText` computed property for convenient access.
    @Attribute(.externalStorage)
    var richTextData: Data?

    /// Rich text accessor that encodes/decodes from `richTextData`.
    /// CloudKit doesn't support AttributedString directly, so we store as Data.
    var richText: AttributedString {
        get {
            guard let data = richTextData else { return AttributedString() }
            do {
                return try JSONDecoder().decode(AttributedString.self, from: data)
            } catch {
                print("⚠️ Failed to decode richText: \(error)")
                return AttributedString()
            }
        }
        set {
            do {
                richTextData = try JSONEncoder().encode(newValue)
                lastModified = Date()
            } catch {
                print("⚠️ Failed to encode richText: \(error)")
            }
        }
    }

    /// Plain text accessor for convenience (e.g., statistics, search)
    var plainText: String {
        String(richText.characters)
    }

    init(pageNumber: Int, text: String, imageData: Data?, originalFileName: String? = nil, boundingBoxesData: Data? = nil) {
        self.pageNumber = pageNumber
        self.imageData = imageData
        self.originalFileName = originalFileName
        self.createdAt = Date()
        self.isDone = false
        self.thumbnailData = nil
        self.boundingBoxesData = boundingBoxesData
        self.lastModified = Date()
        // Encode AttributedString directly to avoid computed property access during init
        self.richTextData = try? JSONEncoder().encode(AttributedString(text))
    }

    /// Decode stored bounding boxes
    var boundingBoxes: [CGRect] {
        guard let data = boundingBoxesData,
              let boxes = try? JSONDecoder().decode([CGRect].self, from: data) else {
            return []
        }
        return boxes
    }
}

@Model
final class Document {
    // MARK: - CloudKit Compatibility
    // All properties must have default values for CloudKit sync.
    // Relationships must be optional.

    var name: String = ""
    var totalPages: Int = 0
    var createdAt: Date = Date()
    @Relationship(deleteRule: .cascade) var pages: [Page]? = []

    /// Optional project emoji for visual customization
    var emoji: String?

    /// Cached storage size in bytes (external storage size isn't easily queryable)
    var cachedStorageBytes: Int64 = 0

    /// Pre-computed cache of all page text data for efficient export.
    /// Stored as JSON-encoded `TextExportCache` to avoid loading individual page external storage files.
    /// See `TextExportCacheService` for cache management.
    @Attribute(.externalStorage)
    var textExportCache: Data?

    init(name: String, totalPages: Int = 0) {
        self.name = name
        self.totalPages = totalPages
        self.createdAt = Date()
        self.pages = []
        self.emoji = nil
        self.cachedStorageBytes = 0
    }

    // MARK: - Convenience Accessors

    /// Non-optional pages array for convenient access. Returns empty array if nil.
    var unwrappedPages: [Page] {
        pages ?? []
    }

    // MARK: - Computed Properties

    /// Returns the most recently modified page (for thumbnail preview)
    var lastModifiedPage: Page? {
        unwrappedPages.max(by: { $0.lastModified < $1.lastModified })
    }

    /// Returns the date of the most recent page modification
    var lastModifiedDate: Date {
        lastModifiedPage?.lastModified ?? createdAt
    }

    /// Completion percentage as integer (0-100)
    var completionPercentage: Int {
        guard totalPages > 0 else { return 0 }
        return Int(Double(unwrappedPages.filter { $0.isDone }.count) / Double(totalPages) * 100)
    }

    /// Formatted storage size string (e.g., "45.2 MB")
    var formattedStorageSize: String {
        ByteCountFormatter.string(fromByteCount: cachedStorageBytes, countStyle: .file)
    }

    /// Recalculates and updates the cached storage size
    func recalculateStorageSize() {
        var totalBytes: Int64 = 0
        for page in unwrappedPages {
            if let imageData = page.imageData {
                totalBytes += Int64(imageData.count)
            }
            if let thumbnailData = page.thumbnailData {
                totalBytes += Int64(thumbnailData.count)
            }
            if let richTextData = page.richTextData {
                totalBytes += Int64(richTextData.count)
            }
        }
        cachedStorageBytes = totalBytes
    }
}

// MARK: - Accessibility Extensions

extension Page {
    /// Label for VoiceOver rotor navigation
    var rotorLabel: String {
        "Page \(pageNumber)"
    }
}

