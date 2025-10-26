import SwiftUI

// FocusedValue keys for menu commands
struct FocusedDocumentKey: FocusedValueKey {
    typealias Value = Document
}

struct FocusedNavigationStateKey: FocusedValueKey {
    typealias Value = NavigationState
}

extension FocusedValues {
    var document: Document? {
        get { self[FocusedDocumentKey.self] }
        set { self[FocusedDocumentKey.self] = newValue }
    }

    var navigationState: NavigationState? {
        get { self[FocusedNavigationStateKey.self] }
        set { self[FocusedNavigationStateKey.self] = newValue }
    }
}
