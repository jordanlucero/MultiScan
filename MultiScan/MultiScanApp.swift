//
//  MultiScanApp.swift
//  MultiScan
//
//  Created by Jordan Lucero on 5/23/25.
//

import SwiftUI
import SwiftData

@main
struct MultiScanApp: App {
    @AppStorage("showStatisticsPane") private var showStatisticsPane = true
    @AppStorage("showThumbnails") private var showThumbnails = true
    @AppStorage("showTextPanel") private var showTextPanel = true
    @AppStorage("filterOption") private var filterOption = "all"
    @AppStorage("optimizeImagesOnImport") private var optimizeImagesOnImport = false
    @AppStorage("viewerBackground") private var viewerBackground = ViewerBackground.default.rawValue

    @FocusedValue(\.document) private var focusedDocument: Document?
    @FocusedValue(\.navigationState) private var focusedNavigationState: NavigationState?
    @FocusedValue(\.editableText) private var focusedEditableText: EditablePageText?
    @FocusedValue(\.currentPage) private var focusedCurrentPage: Page?
    @FocusedBinding(\.isRandomized) private var isRandomized
    @FocusedValue(\.showExportPanel) private var showExportPanelBinding: Binding<Bool>?
    @FocusedValue(\.showAddFromPhotos) private var showAddFromPhotosBinding: Binding<Bool>?
    @FocusedValue(\.showAddFromFiles) private var showAddFromFilesBinding: Binding<Bool>?
    @FocusedValue(\.showFindNavigator) private var showFindNavigatorBinding: Binding<Bool>?

    @State private var showDeletePageConfirmation = false
    @State private var navigationSettings = NavigationSettings()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Document.self,
            Page.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .confirmationDialog(
                    "Delete Page \(focusedNavigationState?.currentPageNumber ?? 0)?",
                    isPresented: $showDeletePageConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        let context = sharedModelContainer.mainContext
                        focusedNavigationState?.deleteCurrentPage(modelContext: context)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will permanently delete the page from your project. This cannot be undone.")
                }
        }
        .modelContainer(sharedModelContainer)
        .commands {

            // File Menu Commands - Append Pages
            CommandGroup(after: .newItem) {
                Divider()

                Button("Append Pages from Photos…", systemImage: "plus") {
                    showAddFromPhotosBinding?.wrappedValue = true
                }
                .disabled(showAddFromPhotosBinding == nil)

                Button("Append Pages from Files…") {
                    showAddFromFilesBinding?.wrappedValue = true
                }
                .disabled(showAddFromFilesBinding == nil)
                
                Divider()

                // programtically makes single page export available due to ShareLink possibly not respecting .disabled()
                if let page = focusedCurrentPage {
                    ShareLink("Export Page Text…",
                              item: RichText(page.richText),
                              preview: SharePreview(String(localized: "Page \(page.pageNumber) Text")))
                } else {
                    Button("Export Page Text…", systemImage: "square.and.arrow.up") {}
                    .disabled(true)
                }

                Button("Export Project Text…") {
                    focusedEditableText?.saveNow()
                    showExportPanelBinding?.wrappedValue = true
                }
                .keyboardShortcut("C", modifiers: [.command, .option])
                .disabled(focusedDocument == nil)
            }

            // Edit Menu Commands
            CommandGroup(after: .pasteboard) {
                Button("Find…") {
                    showFindNavigatorBinding?.wrappedValue = true
                }
                .keyboardShortcut("F", modifiers: [.command])
                .disabled(showFindNavigatorBinding == nil)

                Divider()
                
                Button(focusedNavigationState?.currentPage?.isDone == true ? "Mark Page as Not Reviewed" : "Mark Page as Reviewed",
                       systemImage: focusedNavigationState?.currentPage?.isDone == true ? "x.circle" : "checkmark.circle") {
                    focusedNavigationState?.toggleCurrentPageDone()
                }
                .keyboardShortcut("D", modifiers: [.command])
                .disabled(focusedNavigationState?.currentPage == nil)

                Divider()

                Button("Move Page Up", systemImage: "arrow.up") {
                    focusedNavigationState?.moveCurrentPageUp()
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(focusedNavigationState?.canMoveCurrentPageUp != true)

                Button("Move Page Down", systemImage: "arrow.down") {
                    focusedNavigationState?.moveCurrentPageDown()
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(focusedNavigationState?.canMoveCurrentPageDown != true)

                Divider()

                Button("Delete Page…", systemImage: "trash", role: .destructive) {
                    showDeletePageConfirmation = true
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(focusedNavigationState?.currentPage == nil || focusedDocument?.totalPages ?? 0 <= 1)
            }

            // Format Menu Commands
            CommandMenu("Format") {
                Button("Bold", systemImage: "bold") {
                    focusedEditableText?.applyBold()
                }
                .keyboardShortcut("B", modifiers: [.command])
                .disabled(focusedEditableText == nil || focusedEditableText?.hasSelection != true)

                Button("Italic", systemImage: "italic") {
                    focusedEditableText?.applyItalic()
                }
                .keyboardShortcut("I", modifiers: [.command])
                .disabled(focusedEditableText == nil || focusedEditableText?.hasSelection != true)

                Button("Underline", systemImage: "underline") {
                    focusedEditableText?.applyUnderline()
                }
                .keyboardShortcut("U", modifiers: [.command])
                .disabled(focusedEditableText == nil || focusedEditableText?.hasSelection != true)

                Button("Strikethrough", systemImage: "strikethrough") {
                    focusedEditableText?.applyStrikethrough()
                }
                .keyboardShortcut("X", modifiers: [.command, .shift])
                .disabled(focusedEditableText == nil || focusedEditableText?.hasSelection != true)
            }

            // Image Menu Commands
            CommandMenu("Image") {
                Button("Rotate Clockwise", systemImage: "rotate.right") {
                    if let page = focusedCurrentPage {
                        page.rotation = (page.rotation + 90) % 360
                    }
                }
                .keyboardShortcut("R", modifiers: [.command])
                .disabled(focusedCurrentPage == nil)

                Button("Rotate Counterclockwise", systemImage: "rotate.left") {
                    if let page = focusedCurrentPage {
                        page.rotation = (page.rotation + 270) % 360
                    }
                }
                .keyboardShortcut("R", modifiers: [.command, .shift])
                .disabled(focusedCurrentPage == nil)

                Divider()

                Toggle(isOn: Binding(
                    get: { focusedCurrentPage?.increaseContrast ?? false },
                    set: { newValue in focusedCurrentPage?.increaseContrast = newValue }
                )) {
                    Label("Increase Contrast", systemImage: "circle.lefthalf.filled")
                }
                .disabled(focusedCurrentPage == nil)

                Toggle(isOn: Binding(
                    get: { focusedCurrentPage?.increaseBlackPoint ?? false },
                    set: { newValue in focusedCurrentPage?.increaseBlackPoint = newValue }
                )) {
                    Label("Increase Black Point", systemImage: "")
                }
                .disabled(focusedCurrentPage == nil)
            }

            // View Menu Commands
            CommandGroup(after: .sidebar) {
                Toggle("Show Thumbnails", systemImage: "sidebar.squares.leading", isOn: $showThumbnails)
                    .keyboardShortcut("S", modifiers: [.command])

                Toggle("Show Text Panel", systemImage: "sidebar.trailing", isOn: $showTextPanel)
                    .keyboardShortcut("P", modifiers: [.command, .option])

                Toggle("Show Statistics", systemImage: "chart.bar.xaxis", isOn: $showStatisticsPane)
                    .keyboardShortcut("T", modifiers: [.command, .shift])

                Divider()

                Menu("Filter by Status", systemImage: "line.3.horizontal.decrease.circle") {
                    Toggle("All Pages", isOn: Binding(
                        get: { filterOption == "all" },
                        set: { if $0 { filterOption = "all" } }
                    ))

                    Toggle("Reviewed Only", isOn: Binding(
                        get: { filterOption == "done" },
                        set: { if $0 { filterOption = "done" } }
                    ))

                    Toggle("Not Reviewed Only", isOn: Binding(
                        get: { filterOption == "notDone" },
                        set: { if $0 { filterOption = "notDone" } }
                    ))
                }

                Divider()
                
                Button(focusedNavigationState?.isRandomized == true ? "Use Sequential Order" : "Use Shuffled Order",
                       systemImage: focusedNavigationState?.isRandomized == true ? "arrow.left.and.line.vertical.and.arrow.right" : "shuffle") {
                    focusedNavigationState?.toggleRandomization()
                }
                .disabled(focusedDocument == nil)

                Button("Previous Page") {
                    focusedNavigationState?.previousPage()
                }
                .keyboardShortcut("[", modifiers: [])
                .disabled(focusedNavigationState?.hasPrevious != true)

                Button("Next Page") {
                    focusedNavigationState?.nextPage()
                }
                .keyboardShortcut("]", modifiers: [])
                .disabled(focusedNavigationState?.hasNext != true)

                Divider()

                Button("Zoom In", systemImage: "plus.magnifyingglass") {
                    NotificationCenter.default.post(name: .zoomIn, object: nil)
                }
                .keyboardShortcut("+", modifiers: [.command])
                .disabled(focusedDocument == nil)

                Button("Zoom Out") {
                    NotificationCenter.default.post(name: .zoomOut, object: nil)
                }
                .keyboardShortcut("-", modifiers: [.command])
                .disabled(focusedDocument == nil)

                Button("Fit to Window") {
                    NotificationCenter.default.post(name: .zoomActualSize, object: nil)
                }
                .keyboardShortcut("0", modifiers: [.command])
                .disabled(focusedDocument == nil)
            }

            // App Menu Commands - Settings
            // ⚠️ WORKAROUND: Delete this CommandGroup when native Settings scene works.
            // The native Settings scene auto-generates the "Settings…" menu item with ⌘,
            CommandGroup(replacing: .appSettings) {
                OpenSettingsCommand()
            }

            // Help Menu Commands
            CommandGroup(replacing: .help) {
                Button("MultiScan Known Issues", systemImage: "") { // bulb icon used by system apps missing from SF symbols?? temporarily just pointing to GitHub releases for Known Issues
                    if let url = URL(string: "https://github.com/jordanlucero/MultiScan/releases") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Open MultiScan Repository on GitHub", systemImage: "safari") {
                    if let url = URL(string: "https://github.com/jordanlucero/MultiScan") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        // MARK: - Settings Window (Workaround)
        //
        // ⚠️ WORKAROUND: Custom Window scene instead of native Settings scene
        //
        // As of 26.3, SwiftUI's built-in `Settings` scene has a bug where
        // NavigationSplitView renders incorrectly - the toolbar appears in a separate
        // row below the window title, creating a double-header appearance. The SwiftUI
        // Preview renders correctly, but the actual Settings window does not.
        //
        // This workaround uses a custom `Window` scene that follows Apple's HIG for
        // settings windows:
        // - Opens with ⌘, keyboard shortcut (via OpenSettingsCommand)
        // - Non-resizable window (.windowResizability(.contentSize))
        // - Minimize and zoom buttons disabled (via NSWindow access in onAppear)
        // - Remembers last viewed pane (@AppStorage)
        // - Window title updates to reflect current pane
        // If fixed, delete this Window scene, OpenSettingsCommand, and the CommandGroup
        // replacing .appSettings (around line 275).
        //
        // Last tested: 26.3 Beta 1
        //
        Window("MultiScan Settings", id: "settings") {
            SettingsView(
                optimizeImagesOnImport: $optimizeImagesOnImport,
                viewerBackground: $viewerBackground,
                navigationSettings: navigationSettings
            )
        }
        .windowResizability(.contentSize)
        .commandsRemoved()
        .defaultSize(width: 650, height: 400)

        // MARK: - Native Settings Scene (Currently Broken)
        //
        //  ORIGINAL IMPLEMENTATION - Uncomment to test if Apple has fixed the bug
        // If this works correctly in a future SwiftUI implementation:
        // 1. Delete the custom Window scene above
        // 2. Delete OpenSettingsCommand struct
        // 3. Delete the CommandGroup(replacing: .appSettings) in .commands {}
        // 4. Remove the NSWindow button-disabling code from SettingsView.onAppear
        //
        // Settings {
        //     SettingsView(
        //         optimizeImagesOnImport: $optimizeImagesOnImport,
        //         viewerBackground: $viewerBackground,
        //         navigationSettings: navigationSettings
        //     )
        // }
    }
}

// MARK: - Settings Command (Workaround)
//
// ⚠️ WORKAROUND: Required because we use a custom Window instead of Settings scene.
// The native Settings scene automatically provides ⌘, shortcut; custom Windows do not.
// This view is used in CommandGroup(replacing: .appSettings) to provide the shortcut.
//
// DELETE THIS when the native Settings scene works correctly.
//
struct OpenSettingsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…", systemImage: "gear") {
            openWindow(id: "settings")
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

// MARK: - Settings View

enum SettingsPane: String, CaseIterable, Identifiable {
    case importAndStorage
    case viewer

    var id: String { rawValue }

    /// Localized display name for the pane
    var displayName: String {
        switch self {
        case .importAndStorage: return String(localized: "Import and Storage")
        case .viewer: return String(localized: "Viewer")
        }
    }

    var icon: String {
        switch self {
        case .importAndStorage: return "square.and.arrow.down"
        case .viewer: return "eye"
        }
    }
}

struct SettingsView: View {
    @Binding var optimizeImagesOnImport: Bool
    @Binding var viewerBackground: String
    var navigationSettings: NavigationSettings

    // Persist last viewed pane
    @AppStorage("settingsSelectedPane") private var selectedPaneRawValue: String = SettingsPane.importAndStorage.rawValue

    @State private var navigationHistory: [SettingsPane] = []
    @State private var historyIndex: Int = 0
    @State private var isNavigatingHistory = false

    private var selectedPane: SettingsPane {
        get { SettingsPane(rawValue: selectedPaneRawValue) ?? .importAndStorage }
        set { selectedPaneRawValue = newValue.rawValue }
    }

    private var canGoBack: Bool { historyIndex > 0 }
    private var canGoForward: Bool { historyIndex < navigationHistory.count - 1 }

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding(
                get: { selectedPane },
                set: { newValue in selectedPaneRawValue = newValue.rawValue }
            )) { pane in
                Label(pane.displayName, systemImage: pane.icon)
                    .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
        } detail: {
            switch selectedPane {
            case .importAndStorage:
                ImportAndStorageSettingsView(optimizeImagesOnImport: $optimizeImagesOnImport)
            case .viewer:
                ViewerSettingsView(
                    viewerBackground: $viewerBackground,
                    navigationSettings: navigationSettings
                )
            }
        }
        .navigationTitle(selectedPane.displayName)
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 0) {
                    Button {
                        goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!canGoBack)

                    Button {
                        goForward()
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!canGoForward)
                }
            }
        }
        .onAppear {
            // Initialize history with current pane
            if navigationHistory.isEmpty {
                navigationHistory = [selectedPane]
                historyIndex = 0
            }

            // ⚠️ WORKAROUND: Disable minimize and zoom buttons per HIG for settings windows.
            // Native Settings scene handles this automatically. Delete this block when
            // switching back to native Settings scene.
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "settings" }) {
                window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
                window.standardWindowButton(.zoomButton)?.isEnabled = false
            }
        }
        .onChange(of: selectedPaneRawValue) { oldValue, newValue in
            guard !isNavigatingHistory else { return }
            guard let newPane = SettingsPane(rawValue: newValue) else { return }

            // Remove any forward history
            if historyIndex < navigationHistory.count - 1 {
                navigationHistory = Array(navigationHistory.prefix(historyIndex + 1))
            }
            // Add new pane to history
            if navigationHistory.last != newPane {
                navigationHistory.append(newPane)
                historyIndex = navigationHistory.count - 1
            }
        }
    }

    private func goBack() {
        guard canGoBack else { return }
        isNavigatingHistory = true
        historyIndex -= 1
        selectedPaneRawValue = navigationHistory[historyIndex].rawValue
        isNavigatingHistory = false
    }

    private func goForward() {
        guard canGoForward else { return }
        isNavigatingHistory = true
        historyIndex += 1
        selectedPaneRawValue = navigationHistory[historyIndex].rawValue
        isNavigatingHistory = false
    }
}

// MARK: - Import and Storage Settings

struct ImportAndStorageSettingsView: View {
    @Binding var optimizeImagesOnImport: Bool

    var body: some View {
        Form {
            Section("Import") {
                Toggle("Optimize images on import", isOn: $optimizeImagesOnImport)
                Text("MultiScan will optimize images it stores to save storage.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Viewer Settings

struct ViewerSettingsView: View {
    @Binding var viewerBackground: String
    var navigationSettings: NavigationSettings

    var body: some View {
        Form {
            Section("Viewer") {
                Picker("Background", selection: $viewerBackground) {
                    ForEach(ViewerBackground.allCases, id: \.rawValue) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
            }

            Section("Project Navigation") {
                Toggle("Navigate only between filtered pages (Sequential)", isOn: Bindable(navigationSettings).sequentialUsesFilteredNavigation)
                Text("When a filter is active, the previous and next page buttons will skip pages that don't match the filter.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("Navigate only between filtered pages (Shuffled)", isOn: Bindable(navigationSettings).shuffledUsesFilteredNavigation)
                Text("When shuffle is on and a filter is active, the previous and next page buttons will only visit matching pages.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview("Settings Pane (English)") {
    @Previewable @State var optimizeImages = false
    @Previewable @State var viewerBackground = ViewerBackground.default.rawValue
    @Previewable @State var navigationSettings = NavigationSettings()

    SettingsView(
        optimizeImagesOnImport: $optimizeImages,
        viewerBackground: $viewerBackground,
        navigationSettings: navigationSettings
    )
    .environment(\.locale, Locale(identifier: "en"))
}

#Preview("Settings Pane (es-419)") {
    @Previewable @State var optimizeImages = false
    @Previewable @State var viewerBackground = ViewerBackground.default.rawValue
    @Previewable @State var navigationSettings = NavigationSettings()

    SettingsView(
        optimizeImagesOnImport: $optimizeImages,
        viewerBackground: $viewerBackground,
        navigationSettings: navigationSettings
    )
    .environment(\.locale, Locale(identifier: "es-419"))
}
