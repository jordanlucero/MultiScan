//
//  Preferences.swift
//  MultiScan
//
//  UserDefaults-backed preferences: the keys every `@AppStorage` shares, plus the two `@Observable` preference objects (export separators, filter-aware navigation).
//
//  `@AppStorage` only works inside views, so model-side preferences cache their values in stored properties and write through to UserDefaults in `didSet`. That is what lets `@Observable` tracking work; it also means a preference object must be *shared* when more than one place reads it (`NavigationSettings.shared`), or the copies silently diverge until relaunch.
//

import Foundation
import Observation

// MARK: - Keys

/// UserDefaults keys read from more than one file. Keys used by a single view stay inline with their `@AppStorage`.
nonisolated enum DefaultsKey {
    static let optimizeImagesOnImport = "optimizeImagesOnImport"
    static let showThumbnails = "showThumbnails"
    static let showTextPanel = "showTextPanel"
    static let showStatisticsPane = "showStatisticsPane"
    static let showSmartCleanup = "showSmartCleanup"
    static let filterOption = "filterOption"
    static let viewerBackground = "viewerBackground"
    static let viewerShowsHDR = "viewerShowsHDR"
    /// Suggest a project title with the on-device model after a new import (Foundation Models). Default on; silently inert where Apple Intelligence is unavailable.
    static let autoTitleProjects = "autoTitleProjects"
    /// Mark chapter starts automatically after a new import (`ChapterDetector`). Default on.
    static let autoDetectChapters = "autoDetectChapters"
    /// Include "[Illustration]" placeholders and draft reminders in exported text.
    static let exportIncludeDraftReminders = "exportIncludeDraftReminders"
}

private extension UserDefaults {
    /// `bool(forKey:)` returns `false` for a missing key; this honors a non-`false` default.
    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        object(forKey: key) == nil ? defaultValue : bool(forKey: key)
    }
}

// MARK: - Export

/// Style for visual separators between pages
nonisolated enum SeparatorStyle: String, CaseIterable, Codable, Sendable {
    case lineBreak         // Double line break between pages
    case hyphenatedDivider // Row of hyphens as visual divider

    var label: LocalizedStringResource {
        switch self {
        case .lineBreak: "Line Break"
        case .hyphenatedDivider: "Hyphenated Divider"
        }
    }
}

/// Separator settings for text export, as a value so they can cross actors (`TextExporter.buildResult`, `ProjectStore.projectText`).
nonisolated struct ExportOptions: Equatable, Sendable {
    var createVisualSeparation: Bool
    var separatorStyle: SeparatorStyle
    var includePageNumber: Bool
    var includeFilename: Bool
    var includeStatistics: Bool

    /// Insert each chapter's title (`Page.sectionTitle`) as a heading where the chapter begins. Default on — it's the whole point of marking chapters.
    var includeChapterHeadings: Bool = true

    /// Embed artwork captures as real images (RTFD export). Off → captures become a short `[Illustration]` note so the plain RTF stays portable.
    var includeCaptures: Bool = true

    /// Append a "revisit these pages" list for draft captures at the end, and mark each draft inline. Default on: the reminder is what the draft flag is *for*.
    var includeDraftReminders: Bool = true

    /// Plain "Page X of Y" separators (or none) — used by the Get Project Text intent.
    static func simple(separatePages: Bool) -> ExportOptions {
        ExportOptions(
            createVisualSeparation: separatePages,
            separatorStyle: .lineBreak,
            includePageNumber: true,
            includeFilename: false,
            includeStatistics: false,
            includeChapterHeadings: true,
            includeCaptures: false,
            includeDraftReminders: false
        )
    }
}

/// The user's export preferences. One instance per export panel; `options` is the value the exporter consumes.
@Observable
final class ExportSettings {
    private static let createVisualSeparationKey = "exportCreateVisualSeparation"
    private static let separatorStyleKey = "exportSeparatorStyle"
    private static let includePageNumberKey = "exportIncludePageNumber"
    private static let includeFilenameKey = "exportIncludeFilename"
    private static let includeStatisticsKey = "exportIncludeStatistics"
    private static let includeChapterHeadingsKey = "exportIncludeChapterHeadings"
    private static let includeCapturesKey = "exportIncludeCaptures"

    private let defaults: UserDefaults

    /// Whether to add visual separation between pages (default: false = inline)
    var createVisualSeparation: Bool {
        didSet { defaults.set(createVisualSeparation, forKey: Self.createVisualSeparationKey) }
    }

    /// Style of separator when visual separation is enabled
    var separatorStyle: SeparatorStyle {
        didSet { defaults.set(separatorStyle.rawValue, forKey: Self.separatorStyleKey) }
    }

    /// Include page number in separator (default: true)
    var includePageNumber: Bool {
        didSet { defaults.set(includePageNumber, forKey: Self.includePageNumberKey) }
    }

    /// Include filename in separator
    var includeFilename: Bool {
        didSet { defaults.set(includeFilename, forKey: Self.includeFilenameKey) }
    }

    /// Include word/character statistics in separator
    var includeStatistics: Bool {
        didSet { defaults.set(includeStatistics, forKey: Self.includeStatisticsKey) }
    }

    /// Chapter titles as headings (default: true)
    var includeChapterHeadings: Bool {
        didSet { defaults.set(includeChapterHeadings, forKey: Self.includeChapterHeadingsKey) }
    }

    /// Embed artwork captures (default: true)
    var includeCaptures: Bool {
        didSet { defaults.set(includeCaptures, forKey: Self.includeCapturesKey) }
    }

    /// Draft reminders (default: true). Shares `DefaultsKey.exportIncludeDraftReminders` with the export panel's notice.
    var includeDraftReminders: Bool {
        didSet { defaults.set(includeDraftReminders, forKey: DefaultsKey.exportIncludeDraftReminders) }
    }

    /// The user's current export preferences, for callers off the main actor (App Intents, Transferable exports).
    static var currentOptions: ExportOptions { ExportSettings().options }

    /// The current settings as one value — what `TextExporter` takes, and what the export panel observes.
    var options: ExportOptions {
        ExportOptions(
            createVisualSeparation: createVisualSeparation,
            separatorStyle: separatorStyle,
            includePageNumber: includePageNumber,
            includeFilename: includeFilename,
            includeStatistics: includeStatistics,
            includeChapterHeadings: includeChapterHeadings,
            includeCaptures: includeCaptures,
            includeDraftReminders: includeDraftReminders
        )
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        createVisualSeparation = defaults.bool(forKey: Self.createVisualSeparationKey)
        separatorStyle = defaults.string(forKey: Self.separatorStyleKey).flatMap(SeparatorStyle.init(rawValue:)) ?? .lineBreak
        includePageNumber = defaults.bool(forKey: Self.includePageNumberKey, default: true)
        includeFilename = defaults.bool(forKey: Self.includeFilenameKey)
        includeStatistics = defaults.bool(forKey: Self.includeStatisticsKey)
        includeChapterHeadings = defaults.bool(forKey: Self.includeChapterHeadingsKey, default: true)
        includeCaptures = defaults.bool(forKey: Self.includeCapturesKey, default: true)
        includeDraftReminders = defaults.bool(forKey: DefaultsKey.exportIncludeDraftReminders, default: true)
    }
}

// MARK: - Navigation

/// App-wide preferences for filter-aware page navigation.
@Observable
final class NavigationSettings {
    /// The one instance the app and every `NavigationState` share (see the file comment for why copies would diverge).
    static let shared = NavigationSettings(defaults: .standard)

    private static let sequentialFilterAwareKey = "navigationSequentialFilterAware"
    private static let shuffledFilterAwareKey = "navigationShuffledFilterAware"

    private let defaults: UserDefaults

    /// When true, sequential navigation skips pages that don't match the current filter (default: true)
    var sequentialUsesFilteredNavigation: Bool {
        didSet { defaults.set(sequentialUsesFilteredNavigation, forKey: Self.sequentialFilterAwareKey) }
    }

    /// When true, shuffled navigation only visits pages that match the current filter (default: true)
    var shuffledUsesFilteredNavigation: Bool {
        didSet { defaults.set(shuffledUsesFilteredNavigation, forKey: Self.shuffledFilterAwareKey) }
    }

    /// Only `shared` should back the app; tests pass their own suite.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        sequentialUsesFilteredNavigation = defaults.bool(forKey: Self.sequentialFilterAwareKey, default: true)
        shuffledUsesFilteredNavigation = defaults.bool(forKey: Self.shuffledFilterAwareKey, default: true)
    }
}
