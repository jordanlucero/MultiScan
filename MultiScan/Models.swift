//
//  Item.swift
//  MultiScan
//
//  Created by Jordan Lucero on 5/23/25.
//

import Foundation
import SwiftData
import CoreGraphics

@Model
final class Page {
    var pageNumber: Int
    var text: String
    var imageFileName: String
    var document: Document?
    var createdAt: Date
    var isDone: Bool = false
    var thumbnailData: Data?
    var boundingBoxesData: Data? // Encoded array of CGRect from VisionKit

    init(pageNumber: Int, text: String, imageFileName: String, boundingBoxesData: Data? = nil) {
        self.pageNumber = pageNumber
        self.text = text
        self.imageFileName = imageFileName
        self.createdAt = Date()
        self.isDone = false
        self.thumbnailData = nil
        self.boundingBoxesData = boundingBoxesData
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
    var folderPath: String
    var folderBookmark: Data?
    var totalPages: Int
    var createdAt: Date
    @Relationship(deleteRule: .cascade) var pages: [Page]
    
    init(name: String, folderPath: String, folderBookmark: Data? = nil, totalPages: Int) {
        self.name = name
        self.folderPath = folderPath
        self.folderBookmark = folderBookmark
        self.totalPages = totalPages
        self.createdAt = Date()
        self.pages = []
    }
    
    func resolvedFolderURL() -> URL? {
        guard let bookmarkData = folderBookmark else {
            return URL(fileURLWithPath: folderPath)
        }
        
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale {
                print("Bookmark is stale for document: \(name)")
            }
            return url
        } catch {
            print("Error resolving bookmark: \(error)")
            return URL(fileURLWithPath: folderPath)
        }
    }
}
