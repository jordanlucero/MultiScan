//
//  NavigationSettings.swift
//  MultiScan
//
//  Settings for filtered navigation behavior with UserDefaults persistence.
//

import SwiftUI

/// Observable wrapper for navigation settings with UserDefaults persistence
@MainActor
@Observable
final class NavigationSettings {
    private static let sequentialFilterAwareKey = "navigationSequentialFilterAware"
    private static let shuffledFilterAwareKey = "navigationShuffledFilterAware"

    /// When true, sequential navigation skips pages that don't match the current filter
    var sequentialUsesFilteredNavigation: Bool {
        didSet { UserDefaults.standard.set(sequentialUsesFilteredNavigation, forKey: Self.sequentialFilterAwareKey) }
    }

    /// When true, shuffled navigation only visits pages that match the current filter
    var shuffledUsesFilteredNavigation: Bool {
        didSet { UserDefaults.standard.set(shuffledUsesFilteredNavigation, forKey: Self.shuffledFilterAwareKey) }
    }

    init() {
        let defaults = UserDefaults.standard

        // Load filter-aware navigation settings, both are defaulted to true
        
        if defaults.object(forKey: Self.sequentialFilterAwareKey) != nil {
            self.sequentialUsesFilteredNavigation = defaults.bool(forKey: Self.sequentialFilterAwareKey)
        } else {
            self.sequentialUsesFilteredNavigation = true
        }

        if defaults.object(forKey: Self.shuffledFilterAwareKey) != nil {
            self.shuffledUsesFilteredNavigation = defaults.bool(forKey: Self.shuffledFilterAwareKey)
        } else {
            self.shuffledUsesFilteredNavigation = true
        }
    }
}
