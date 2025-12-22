import SwiftUI

// FocusedValue keys for menu commands
struct FocusedDocumentKey: FocusedValueKey {
    typealias Value = Document
}

struct FocusedNavigationStateKey: FocusedValueKey {
    typealias Value = NavigationState
}

struct FocusedEditableTextKey: FocusedValueKey {
    typealias Value = EditablePageText
}

struct FocusedShowExportPanelKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

struct FocusedFullDocumentTextKey: FocusedValueKey {
    typealias Value = String
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

    var editableText: EditablePageText? {
        get { self[FocusedEditableTextKey.self] }
        set { self[FocusedEditableTextKey.self] = newValue }
    }

    var showExportPanel: Binding<Bool>? {
        get { self[FocusedShowExportPanelKey.self] }
        set { self[FocusedShowExportPanelKey.self] = newValue }
    }

    var fullDocumentText: String? {
        get { self[FocusedFullDocumentTextKey.self] }
        set { self[FocusedFullDocumentTextKey.self] = newValue }
    }
}
