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

struct FocusedShowAddFromPhotosKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

struct FocusedShowAddFromFilesKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

struct FocusedCurrentPageKey: FocusedValueKey {
    typealias Value = Page
}

struct FocusedShowFindNavigatorKey: FocusedValueKey {
    typealias Value = Binding<Bool>
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

    var showAddFromPhotos: Binding<Bool>? {
        get { self[FocusedShowAddFromPhotosKey.self] }
        set { self[FocusedShowAddFromPhotosKey.self] = newValue }
    }

    var showAddFromFiles: Binding<Bool>? {
        get { self[FocusedShowAddFromFilesKey.self] }
        set { self[FocusedShowAddFromFilesKey.self] = newValue }
    }

    var currentPage: Page? {
        get { self[FocusedCurrentPageKey.self] }
        set { self[FocusedCurrentPageKey.self] = newValue }
    }

    var showFindNavigator: Binding<Bool>? {
        get { self[FocusedShowFindNavigatorKey.self] }
        set { self[FocusedShowFindNavigatorKey.self] = newValue }
    }
}
