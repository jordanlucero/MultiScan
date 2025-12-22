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
    var pageNumber: Int
    var document: Document?
    var createdAt: Date
    var isDone: Bool = false
    var thumbnailData: Data?
    var boundingBoxesData: Data? // Encoded array of CGRect from VisionKit
    var lastModified: Date = Date()

    /// Original filename for display purposes
    var originalFileName: String?

    /// Full image data stored externally for efficiency
    @Attribute(.externalStorage)
    var imageData: Data?

    /// JSON-encoded AttributedString data for rich text storage
    @Attribute(.externalStorage)
    private var richTextData: Data = Data()

    /// Flag to track if rich text has been modified
    @Transient
    private var richTextChanged: Bool = false

    /// The rich text content as an AttributedString
    @Transient
    lazy var richText: AttributedString = initializeRichText() {
        didSet {
            richTextChanged = true
            lastModified = Date()
        }
    }

    /// Plain text accessor for convenience (e.g., statistics)
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

        // Initialize rich text from plain text
        self.richText = AttributedString(text)

        // Immediately serialize
        if let data = try? richText.encodeToJSON() {
            self.richTextData = data
        }

        // Set up save observer
        setupSaveObserver()
    }

    /// Initialize rich text from stored data
    private func initializeRichText() -> AttributedString {
        setupSaveObserver()

        // Try to decode from JSON data
        if !richTextData.isEmpty,
           let decoded = try? AttributedString.decodeFromJSON(richTextData) {
            return decoded
        }

        // Return empty attributed string if no data
        return AttributedString("")
    }

    /// Set up observer to serialize rich text before SwiftData saves
    private func setupSaveObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(willSave),
            name: ModelContext.willSave,
            object: nil
        )
    }

    @objc
    private func willSave() {
        guard richTextChanged else { return }
        richTextChanged = false

        do {
            richTextData = try richText.encodeToJSON()
        } catch {
            print("Failed to encode rich text: \(error)")
        }
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
    var name: String
    var totalPages: Int
    var createdAt: Date
    @Relationship(deleteRule: .cascade) var pages: [Page]

    init(name: String, totalPages: Int = 0) {
        self.name = name
        self.totalPages = totalPages
        self.createdAt = Date()
        self.pages = []
    }
}
