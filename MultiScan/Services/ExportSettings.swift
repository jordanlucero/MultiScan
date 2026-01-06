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

    var label: LocalizedStringResource {
        switch self {
        case .inline: "Inline"
        case .lineBreak: "Line Break"
        case .visualSeparation: "Visual Separation"
        }
    }

    var description: LocalizedStringResource {
        switch self {
        case .inline: "Pages flow continuously without breaks"
        case .lineBreak: "Add dual line breaks between pages"
        case .visualSeparation: "Add identifying information between pages"
        }
    }
}

/// Style for the visual separator between pages
enum SeparatorStyle: String, CaseIterable, Codable {
    case singleLine    // All metadata on one line with pipes
    case multipleLines // Metadata on separate lines
    case hyphenLine    // Row of hyphens as visual divider

    var label: LocalizedStringResource {
        switch self {
        case .singleLine: "Single Line"
        case .multipleLines: "Multiple Lines"
        case .hyphenLine: "Hyphen Divider"
        }
    }

    var description: LocalizedStringResource {
        switch self {
        case .singleLine: "[Page 1 of 5 | filename.heic | 245 words]"
        case .multipleLines: "Each detail on its own line"
        case .hyphenLine: "Horizontal line of hyphens"
        }
    }
}

/// Observable wrapper for export settings with UserDefaults persistence
@MainActor
@Observable
final class ExportSettings {
    private static let flowStyleKey = "exportFlowStyle"
    private static let includePageNumberKey = "exportIncludePageNumber"
    private static let includeFilenameKey = "exportIncludeFilename"
    private static let includeStatisticsKey = "exportIncludeStatistics"
    private static let separatorStyleKey = "exportSeparatorStyle"

    var flowStyle: ExportFlowStyle {
        didSet { UserDefaults.standard.set(flowStyle.rawValue, forKey: Self.flowStyleKey) }
    }

    var includePageNumber: Bool {
        didSet { UserDefaults.standard.set(includePageNumber, forKey: Self.includePageNumberKey) }
    }

    var includeFilename: Bool {
        didSet { UserDefaults.standard.set(includeFilename, forKey: Self.includeFilenameKey) }
    }

    var includeStatistics: Bool {
        didSet { UserDefaults.standard.set(includeStatistics, forKey: Self.includeStatisticsKey) }
    }

    var separatorStyle: SeparatorStyle {
        didSet { UserDefaults.standard.set(separatorStyle.rawValue, forKey: Self.separatorStyleKey) }
    }

    /// Whether visual separation options should be enabled
    var visualSeparationEnabled: Bool {
        flowStyle == .visualSeparation
    }

    init() {
        let defaults = UserDefaults.standard

        // Load flow style
        if let raw = defaults.string(forKey: Self.flowStyleKey),
           let style = ExportFlowStyle(rawValue: raw) {
            self.flowStyle = style
        } else {
            self.flowStyle = .lineBreak
        }

        // Load booleans (check if key exists to distinguish false from unset)
        if defaults.object(forKey: Self.includePageNumberKey) != nil {
            self.includePageNumber = defaults.bool(forKey: Self.includePageNumberKey)
        } else {
            self.includePageNumber = true
        }

        self.includeFilename = defaults.bool(forKey: Self.includeFilenameKey)
        self.includeStatistics = defaults.bool(forKey: Self.includeStatisticsKey)

        // Load separator style
        if let raw = defaults.string(forKey: Self.separatorStyleKey),
           let style = SeparatorStyle(rawValue: raw) {
            self.separatorStyle = style
        } else {
            self.separatorStyle = .singleLine
        }
    }
}
