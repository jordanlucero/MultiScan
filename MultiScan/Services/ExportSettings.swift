//
//  ExportSettings.swift
//  MultiScan
//
//  Settings for text export with @AppStorage persistence.
//

import SwiftUI

/// How pages should flow together in the export
enum ExportFlowStyle: String, CaseIterable, Codable {
    case inline           // No separation between pages
    case lineBreak        // Double line break between pages (default)
    case visualSeparation // Custom separators with metadata

    var label: String {
        switch self {
        case .inline: "Inline"
        case .lineBreak: "Line Break"
        case .visualSeparation: "Visual Separation"
        }
    }

    var description: String {
        switch self {
        case .inline: "Pages flow continuously without breaks"
        case .lineBreak: "Double line break between pages"
        case .visualSeparation: "Add page info between pages"
        }
    }
}

/// Style for the visual separator between pages
enum SeparatorStyle: String, CaseIterable, Codable {
    case singleLine    // All metadata on one line with pipes
    case multipleLines // Metadata on separate lines
    case hyphenLine    // Row of hyphens as visual divider

    var label: String {
        switch self {
        case .singleLine: "Single Line"
        case .multipleLines: "Multiple Lines"
        case .hyphenLine: "Hyphen Divider"
        }
    }

    var description: String {
        switch self {
        case .singleLine: "[Page 1 of 5 | filename.jpg | 245 words]"
        case .multipleLines: "Each detail on its own line"
        case .hyphenLine: "Horizontal line of hyphens"
        }
    }
}

/// Observable wrapper for export settings with AppStorage persistence
@MainActor
@Observable
final class ExportSettings {
    // Store raw strings for @AppStorage compatibility
    @ObservationIgnored
    @AppStorage("exportFlowStyle")
    private var flowStyleRaw: String = ExportFlowStyle.lineBreak.rawValue

    @ObservationIgnored
    @AppStorage("exportIncludePageNumber")
    var includePageNumber: Bool = true

    @ObservationIgnored
    @AppStorage("exportIncludeFilename")
    var includeFilename: Bool = false

    @ObservationIgnored
    @AppStorage("exportIncludeStatistics")
    var includeStatistics: Bool = false

    @ObservationIgnored
    @AppStorage("exportSeparatorStyle")
    private var separatorStyleRaw: String = SeparatorStyle.singleLine.rawValue

    var flowStyle: ExportFlowStyle {
        get { ExportFlowStyle(rawValue: flowStyleRaw) ?? .lineBreak }
        set { flowStyleRaw = newValue.rawValue }
    }

    var separatorStyle: SeparatorStyle {
        get { SeparatorStyle(rawValue: separatorStyleRaw) ?? .singleLine }
        set { separatorStyleRaw = newValue.rawValue }
    }

    /// Whether visual separation options should be enabled
    var visualSeparationEnabled: Bool {
        flowStyle == .visualSeparation
    }
}
