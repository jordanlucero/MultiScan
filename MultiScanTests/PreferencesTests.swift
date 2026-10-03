//
//  PreferencesTests.swift
//  MultiScanTests
//

import Foundation
import Testing
@testable import MultiScan

@Suite("Preferences")
struct PreferencesTests {
    @Test func exportSettingsDefaultsAndPersistence() {
        let defaults = Fixtures.defaults("export")

        let settings = ExportSettings(defaults: defaults)
        #expect(settings.options == ExportOptions(
            createVisualSeparation: false, separatorStyle: .lineBreak,
            includePageNumber: true, includeFilename: false, includeStatistics: false
        ))

        settings.createVisualSeparation = true
        settings.separatorStyle = .hyphenatedDivider
        settings.includePageNumber = false
        settings.includeFilename = true
        settings.includeStatistics = true

        let reloaded = ExportSettings(defaults: defaults)
        #expect(reloaded.options == settings.options)
        #expect(reloaded.separatorStyle == .hyphenatedDivider)
        #expect(!reloaded.includePageNumber)
    }

    @Test func simpleOptionsOnlyCarryPageNumbers() {
        let separated = ExportOptions.simple(separatePages: true)
        #expect(separated.createVisualSeparation && separated.includePageNumber && !separated.includeFilename && !separated.includeStatistics)
        #expect(!ExportOptions.simple(separatePages: false).createVisualSeparation)
    }

    @Test func navigationSettingsDefaultToFilterAwareAndPersist() {
        let defaults = Fixtures.defaults("navigation")
        let settings = NavigationSettings(defaults: defaults)
        #expect(settings.sequentialUsesFilteredNavigation)
        #expect(settings.shuffledUsesFilteredNavigation)

        settings.sequentialUsesFilteredNavigation = false
        let reloaded = NavigationSettings(defaults: defaults)
        #expect(!reloaded.sequentialUsesFilteredNavigation)
        #expect(reloaded.shuffledUsesFilteredNavigation)
    }

    @Test func separatorStyleRawValuesAreStable() {
        #expect(SeparatorStyle(rawValue: "lineBreak") == .lineBreak)
        #expect(SeparatorStyle(rawValue: "hyphenatedDivider") == .hyphenatedDivider)
    }
}
