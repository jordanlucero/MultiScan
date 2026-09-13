//
//  NavigationSettings.swift
//  MultiScan
//
//  App-wide preferences for filter-aware page navigation, persisted in UserDefaults.
//

import Foundation
import Observation

@MainActor
@Observable
final class NavigationSettings {
    /// The one instance the app and every `NavigationState` share.
    ///
    /// These are app-wide preferences, so separate instances can't stay in sync: each caches its values in stored properties at init and only writes through to UserDefaults, so a toggle in Settings wouldn't reach navigation until the next launch. Sharing one instance is also what lets `@Observable` tracking propagate the change live. The initializer is private to enforce this.
    static let shared = NavigationSettings()

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

    private init() {
        let defaults = UserDefaults.standard

        // Both default to true
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
