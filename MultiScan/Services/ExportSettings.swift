//
//  ExportSettings.swift
//  MultiScan
//
//  Settings for text export with UserDefaults persistence.
//

import SwiftUI

/// Style for visual separators between pages
enum SeparatorStyle: String, CaseIterable, Codable {
    case lineBreak         // Double line break between pages
    case hyphenatedDivider // Row of hyphens as visual divider

    var label: LocalizedStringResource {
        switch self {
        case .lineBreak: "Line Break"
        case .hyphenatedDivider: "Hyphenated Divider"
        }
    }
}

/// Observable wrapper for export settings with UserDefaults persistence
@MainActor
@Observable
final class ExportSettings {
    private static let createVisualSeparationKey = "exportCreateVisualSeparation"
    private static let separatorStyleKey = "exportSeparatorStyle"
    private static let includePageNumberKey = "exportIncludePageNumber"
    private static let includeFilenameKey = "exportIncludeFilename"
    private static let includeStatisticsKey = "exportIncludeStatistics"

    /// Whether to add visual separation between pages (default: false = inline)
    var createVisualSeparation: Bool {
        didSet { UserDefaults.standard.set(createVisualSeparation, forKey: Self.createVisualSeparationKey) }
    }

    /// Style of separator when visual separation is enabled
    var separatorStyle: SeparatorStyle {
        didSet { UserDefaults.standard.set(separatorStyle.rawValue, forKey: Self.separatorStyleKey) }
    }

    /// Include page number in separator
    var includePageNumber: Bool {
        didSet { UserDefaults.standard.set(includePageNumber, forKey: Self.includePageNumberKey) }
    }

    /// Include filename in separator
    var includeFilename: Bool {
        didSet { UserDefaults.standard.set(includeFilename, forKey: Self.includeFilenameKey) }
    }

    /// Include word/character statistics in separator
    var includeStatistics: Bool {
        didSet { UserDefaults.standard.set(includeStatistics, forKey: Self.includeStatisticsKey) }
    }

    init() {
        let defaults = UserDefaults.standard

        // Load visual separation toggle (default: false = inline)
        self.createVisualSeparation = defaults.bool(forKey: Self.createVisualSeparationKey)

        // Load separator style (default: lineBreak)
        if let raw = defaults.string(forKey: Self.separatorStyleKey),
           let style = SeparatorStyle(rawValue: raw) {
            self.separatorStyle = style
        } else {
            self.separatorStyle = .lineBreak
        }

        // Load include options (page number defaults to true)
        if defaults.object(forKey: Self.includePageNumberKey) != nil {
            self.includePageNumber = defaults.bool(forKey: Self.includePageNumberKey)
        } else {
            self.includePageNumber = true
        }

        self.includeFilename = defaults.bool(forKey: Self.includeFilenameKey)
        self.includeStatistics = defaults.bool(forKey: Self.includeStatisticsKey)
    }
}
