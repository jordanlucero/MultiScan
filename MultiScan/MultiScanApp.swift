//
//  MultiScanApp.swift
//  MultiScan
//
//  Created by Jordan Lucero on 5/23/25.
//

import SwiftUI
import SwiftData
import CloudKit
import CoreData

// MARK: - Notification Names

extension Notification.Name {
    static let zoomIn = Notification.Name("zoomIn")
    static let zoomOut = Notification.Name("zoomOut")
    static let zoomActualSize = Notification.Name("zoomActualSize")
}

// MARK: - FocusedValue Keys

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

struct FocusedIsRandomizedKey: FocusedValueKey {
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

    var isRandomized: Binding<Bool>? {
        get { self[FocusedIsRandomizedKey.self] }
        set { self[FocusedIsRandomizedKey.self] = newValue }
    }
}

// MARK: - Export Settings

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

// MARK: - Navigation Settings

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

// MARK: - App Entry Point

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

    // MARK: - Container State Management

    /// Tracks the container loading state for showing appropriate UI.
    /// Initial state is determined by checking for pre-existing errors.
    @State private var containerLoadState: ContainerLoadState = {
        // Check for container creation errors first
        if let error = MultiScanApp.containerCreationError {
            return .failed(.failed(error: error.localizedDescription))
        }
        // Check for pre-load version issues
        if case .newerThanApp(let version) = MultiScanApp.preLoadCheckResult {
            return .failed(.incompatible(version: version))
        }
        return .ready
    }()

    /// State for container loading and error handling.
    enum ContainerLoadState {
        case ready
        case failed(RecoveryState)
    }

    // MARK: - SwiftData + CloudKit Container
    //
    // This property creates the SwiftData ModelContainer with CloudKit sync enabled.
    //
    // ## How CloudKit Sync Works
    //
    // 1. SwiftData is built on top of Core Data
    // 2. Core Data has CloudKit integration via NSPersistentCloudKitContainer
    // 3. SwiftData uses this under the hood when you specify `cloudKitDatabase:`
    // 4. Your SwiftData models become "record types" in CloudKit (like database tables)
    //    - Document.self → CD_Document record type
    //    - Page.self → CD_Page record type
    //
    // ## Development vs Production Environments
    //
    // CloudKit has TWO separate environments within your container:
    //
    //   iCloud.co.jservices.MultiScan
    //   ├── Development Environment  ← Debug/Xcode builds sync here
    //   │   └── (test data, can be reset freely)
    //   └── Production Environment   ← App Store builds sync here
    //       └── (real user data, be careful!)
    //
    // These environments are completely isolated. Your debug testing never
    // touches production data, and vice versa.
    //
    // ## Schema Initialization (the #if DEBUG block below)
    //
    // Before CloudKit can sync data, it needs to know your data structure (the "schema").
    // The schema defines what record types exist and what fields they have.
    //
    // SwiftData doesn't expose a direct way to push the schema to CloudKit, so we
    // temporarily use Core Data's API (NSPersistentCloudKitContainer.initializeCloudKitSchema)
    // to do this during development. This is Apple's recommended approach as of macOS 26-aligned releases.
    //
    //
    // ## Schema Changes & Version Compatibility
    //
    // After shipping to the App Store (or GitHub), be careful with model changes:
    //
    //   ✅ SAFE changes (additive):
    //      - Adding new properties WITH default values
    //      - Adding new @Model classes
    //
    //   ⚠️  BREAKING changes (avoid after shipping):
    //      - Renaming properties or models
    //      - Deleting properties or models
    //      - Changing property types
    //
    // Breaking changes will cause sync failures for users on older app versions.
    // Options for handling this:
    //   1. Only make additive changes (recommended)
    //   2. Add a schemaVersion field and show "please update" for old clients
    //   3. Accept that old versions break (fine for personal/specialist tools)
    //
    /// Error captured during container creation (if any).
    /// Using a static var because the container is created during init.
    private static var containerCreationError: ContainerLoadError?

    /// Result of pre-load version check.
    private static var preLoadCheckResult: PreLoadCheckResult = .compatible

    var sharedModelContainer: ModelContainer = {
        // ────────────────────────────────────────────────────────────────────
        // MARK: Pre-Load Version Check
        // ────────────────────────────────────────────────────────────────────
        //
        // Check for incompatible data BEFORE attempting to load the container.
        // This uses UserDefaults, which survives database corruption.
        //
        let preLoadResult = SchemaValidationService.checkPreLoadCompatibility()
        MultiScanApp.preLoadCheckResult = preLoadResult

        // If data is from a newer app version, we should warn the user
        // but still attempt to load (they might want to see their data in read-only mode)
        if case .newerThanApp(let version) = preLoadResult {
            print("⚠️ Schema Warning: Data was written by schema version \(version), " +
                  "but this app only supports version \(SchemaVersioning.currentVersion)")
        }

        // ────────────────────────────────────────────────────────────────────
        // MARK: iCloud Sync Configuration
        // ────────────────────────────────────────────────────────────────────
        //
        // Check user preference for iCloud sync.
        // Default is OFF - users must opt-in via Settings > Import and Storage.
        //
        // If enabled: Uses CloudKit private database for cross-device sync
        // If disabled: Data stays local to this device only
        //
        // Note: If user isn't signed into iCloud, enabling sync has no effect -
        // data just stays local until they sign in.
        //
        let iCloudSyncEnabled = SchemaVersioning.isICloudSyncEnabled

        if iCloudSyncEnabled {
            print("☁️ iCloud sync ENABLED")
        } else {
            print("☁️ iCloud sync DISABLED")
        }

        // Create ModelConfiguration - this determines the store URL
        let modelConfiguration = ModelConfiguration(
            isStoredInMemoryOnly: false,
            cloudKitDatabase: iCloudSyncEnabled
                ? .private("iCloud.co.jservices.MultiScan")
                : .none
        )

        do {
            // Create the SwiftData container
            // SwiftData handles CloudKit schema creation automatically when data is saved
            let container = try ModelContainer(
                for: Document.self, Page.self, SchemaMetadata.self,
                configurations: modelConfiguration
            )

            // Record successful load for future version checks
            SchemaValidationService.markHasLaunched()
            SchemaValidationService.recordSuccessfulLoad()

            return container
        } catch {
            // ────────────────────────────────────────────────────────────────────
            // MARK: Container Creation Failed
            // ────────────────────────────────────────────────────────────────────
            //
            // Instead of crashing, we capture the error and show a recovery UI.
            // The user can then choose to:
            // - Try again (maybe a transient issue)
            // - Reset all data (delete and recreate the database)
            // - Report the issue
            //
            // We still need to return SOMETHING for the container, so we create
            // an in-memory container as a fallback. The app will show recovery UI
            // instead of the normal content.
            //
            MultiScanApp.containerCreationError = .containerCreationFailed(error.localizedDescription)
            print("ModelContainer creation failed: \(error)")

            // Create a minimal in-memory container as fallback
            // (the app will show recovery UI, not actual content)
            let fallbackConfig = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            do {
                return try ModelContainer(
                    for: Document.self, Page.self, SchemaMetadata.self,
                    configurations: fallbackConfig
                )
            } catch {
                // If even the fallback fails, we have no choice but to crash
                fatalError("Could not create a fallback ModelContainer: \(error)")
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            // ────────────────────────────────────────────────────────────────────
            // MARK: Container State Handling
            // ────────────────────────────────────────────────────────────────────
            //
            // Show different UI based on container load state:
            // - ready: Normal app content
            // - failed: Recovery UI with options to retry or reset
            //
            Group {
                switch containerLoadState {
                case .ready:
                    // Normal app content
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

                case .failed(let recoveryState):
                    // Recovery UI for errors
                    SchemaRecoveryView(
                        state: recoveryState,
                        onRetry: {
                            // Reset state and attempt reload (requires app restart for now)
                            // A full solution would re-create the container, but that's complex
                            // For now, just suggest the user restart the app
                        },
                        onReset: {
                            // Delete the database and restart
                            let url = sharedModelContainer.configurations.first?.url
                            if let url = url {
                                _ = SchemaValidationService.resetDatabase(containerURL: url)
                            }
                            // Clear version tracking
                            UserDefaults.standard.removeObject(forKey: SchemaVersioning.userDefaultsKey)
                            // The user will need to restart the app
                        }
                    )
                }
            }
            .task {
                // ────────────────────────────────────────────────────────────────────
                // MARK: Post-Load Validation & Self-Healing
                // ────────────────────────────────────────────────────────────────────
                //
                // This runs after the view appears. If we're already in a failed state
                // (from pre-load checks), skip validation.
                //

                // Skip if already in error state
                if case .failed = containerLoadState {
                    return
                }

                // Run post-load validation
                // This checks SchemaMetadata in the database (important for CloudKit sync
                // scenarios where another device might have written newer data)
                let result = await SchemaValidationService.validatePostLoad(
                    context: sharedModelContainer.mainContext
                )

                // Check for critical issues (e.g., data from newer schema via CloudKit)
                if result.hasCriticalIssues {
                    for issue in result.issues {
                        if case .newerSchemaVersion(let stored, _) = issue {
                            containerLoadState = .failed(.incompatible(version: stored))
                            return
                        }
                    }
                }

                // Self-heal minor issues (totalPages mismatch, page numbering, etc.)
                if result.hasMinorIssues {
                    let unfixable = SchemaValidationService.attemptSelfHeal(
                        issues: result.issues,
                        context: sharedModelContainer.mainContext
                    )
                    if !unfixable.isEmpty {
                        print("Some integrity issues could not be auto-fixed: \(unfixable.map { $0.description })")
                    }
                }
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

            #if os(macOS)
            // App Menu Commands - Settings
            // ⚠️ WORKAROUND: Delete this CommandGroup when native Settings scene works.
            // The native Settings scene auto-generates the "Settings…" menu item with ⌘,
            CommandGroup(replacing: .appSettings) {
                OpenSettingsCommand()
            }
            #endif
            
            // Help Menu Commands
            CommandGroup(replacing: .help) {
                Link("MultiScan Known Issues", destination: URL(string: "https://github.com/jordanlucero/MultiScan/releases")!) // tips icon used by system apps missing from SF symbols. removed SF symbols from both links and temporarily just pointing to GitHub releases for Known Issues
                Link("Open MultiScan Repository on GitHub", destination: URL(string: "https://github.com/jordanlucero/MultiScan")!)
            }
        }

        #if os(macOS)
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
            .frame(width: 650, height: 400)
        }
        .windowResizability(.contentSize)
        .commandsRemoved()
        #endif
    }
}

#if os(macOS)
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

// MARK: - Settings Command (Workaround)
//
// ⚠️ WORKAROUND: Required because we use a custom Window instead of Settings scene.
// The native Settings scene automatically provides ⌘, shortcut; custom Windows do not.
// This view is used in CommandGroup(replacing: .appSettings) to provide the shortcut.
//
// DELETE THIS when the native Settings scene works correctly.

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
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 300)
//            .toolbar(removing: .sidebarToggle) // works, but users might accidentally collapse the sidebar when resizing and have no easy way of showing it again
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

    // iCloud sync setting - uses UserDefaults directly because changing it requires restart
    @State private var iCloudSyncEnabled = SchemaVersioning.isICloudSyncEnabled
    @State private var showRestartAlert = false
    @State private var pendingSyncValue: Bool? = nil

    // Debug state
    #if DEBUG
    @Environment(\.modelContext) private var modelContext
    @State private var iCloudAccountStatus: String = "Checking..."
    @State private var lastSyncAttempt: Date? = nil
    @State private var syncStatusMessage: String = ""
    #endif

    var body: some View {
        Form {
            Section("Import") {
                Toggle("Optimize images on import", isOn: $optimizeImagesOnImport)
                Text("MultiScan will optimize images it stores to save storage.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("iCloud") {
                Toggle("Sync projects with iCloud", isOn: $iCloudSyncEnabled)
                    .onChange(of: iCloudSyncEnabled) { oldValue, newValue in
                        // Don't process if alert is already showing (means we're reverting the toggle)
                        guard oldValue != newValue, !showRestartAlert else { return }
                        pendingSyncValue = newValue
                        showRestartAlert = true
                        // Revert the toggle until user confirms
                        iCloudSyncEnabled = oldValue
                    }

                Text("Sync your MultiScan projects in iCloud to work with them across your devices. Image data in larger projects may use significant iCloud storage.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            #if DEBUG
            Section("Debug: CloudKit Status") {
                LabeledContent("Setting Enabled") {
                    Text(iCloudSyncEnabled ? "Yes" : "No")
                        .foregroundColor(iCloudSyncEnabled ? .green : .secondary)
                }

                LabeledContent("Container Active") {
                    // Check if container was created with CloudKit
                    Text(SchemaVersioning.isICloudSyncEnabled ? "Yes" : "No (restart required)")
                        .foregroundColor(SchemaVersioning.isICloudSyncEnabled ? .green : .orange)
                }

                LabeledContent("iCloud Account") {
                    Text(iCloudAccountStatus)
                        .foregroundColor(iCloudAccountStatus == "Available" ? .green : .orange)
                }

                LabeledContent("Container ID") {
                    Text("iCloud.co.jservices.MultiScan")
                        .font(.caption)
                        .textSelection(.enabled)
                }

                LabeledContent("Device ID") {
                    Text(SchemaMetadata.currentDeviceID.prefix(8) + "...")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }

                if let lastSync = lastSyncAttempt {
                    LabeledContent("Last Sync Attempt") {
                        Text(lastSync, style: .relative)
                    }
                }

                if !syncStatusMessage.isEmpty {
                    Text(syncStatusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button("Force Sync Now") {
                    forceSyncNow()
                }
                .disabled(!SchemaVersioning.isICloudSyncEnabled)

                Button("Refresh Status") {
                    Task { await checkICloudStatus() }
                }
            }
            .onAppear {
                Task { await checkICloudStatus() }
            }
            #endif
        }
        .formStyle(.grouped)
        .alert("Restart Required", isPresented: $showRestartAlert) {
            Button("Cancel", role: .cancel) {
                pendingSyncValue = nil
            }
            Button(pendingSyncValue == true ? "Enable & Quit" : "Disable & Quit") {
                if let newValue = pendingSyncValue {
                    // Save the new setting
                    UserDefaults.standard.set(newValue, forKey: SchemaVersioning.iCloudSyncEnabledKey)
                    // Quit the app so user can relaunch with new setting
                    NSApplication.shared.terminate(nil)
                }
            }
        } message: {
            if pendingSyncValue == true {
                Text("Your projects will begin syncing to and from iCloud after you quit and reopen MultiScan.")
            } else {
                Text("Quit and reopen MultiScan to disable iCloud sync. Your projects will remain on this device but will no longer sync with other devices.")
            }
        }
    }

    #if DEBUG
    private func checkICloudStatus() async {
        do {
            let container = CKContainer(identifier: "iCloud.co.jservices.MultiScan")
            let status = try await container.accountStatus()
            await MainActor.run {
                switch status {
                case .available:
                    iCloudAccountStatus = "Available"
                case .noAccount:
                    iCloudAccountStatus = "No Account"
                case .restricted:
                    iCloudAccountStatus = "Restricted"
                case .couldNotDetermine:
                    iCloudAccountStatus = "Could Not Determine"
                case .temporarilyUnavailable:
                    iCloudAccountStatus = "Temporarily Unavailable"
                @unknown default:
                    iCloudAccountStatus = "Unknown"
                }
            }
        } catch {
            await MainActor.run {
                iCloudAccountStatus = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func forceSyncNow() {
        lastSyncAttempt = Date()
        syncStatusMessage = "Saving context to trigger sync..."

        do {
            try modelContext.save()
            syncStatusMessage = "Context saved. CloudKit should sync automatically."
        } catch {
            syncStatusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Tests direct CloudKit access by saving a test record to the private database.
    /// This bypasses SwiftData/Core Data to verify the container is accessible.
    private func testCloudKitAccess() async {
        syncStatusMessage = "Testing CloudKit access..."

        let container = CKContainer(identifier: "iCloud.co.jservices.MultiScan")
        let privateDB = container.privateCloudDatabase

        // Create a simple test record
        let testRecord = CKRecord(recordType: "TestRecord")
        testRecord["testValue"] = "Test from MultiScan at \(Date())" as CKRecordValue

        do {
            let savedRecord = try await privateDB.save(testRecord)
            await MainActor.run {
                syncStatusMessage = "✅ CloudKit access OK! Saved record: \(savedRecord.recordID.recordName)"
            }

            // Clean up - delete the test record
            try? await privateDB.deleteRecord(withID: savedRecord.recordID)

        } catch let error as CKError {
            await MainActor.run {
                syncStatusMessage = "❌ CloudKit error: \(error.code.rawValue) - \(error.localizedDescription)"
                print("☁️ CloudKit Test Error: \(error)")
                if let partialErrors = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
                    for (key, partialError) in partialErrors {
                        print("☁️   Partial error for \(key): \(partialError)")
                    }
                }
            }
        } catch {
            await MainActor.run {
                syncStatusMessage = "❌ Error: \(error.localizedDescription)"
            }
        }
    }
    #endif
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
#else
// iOS/iPadOS version of ImportAndStorageSettingsView
struct ImportAndStorageSettingsView: View {
    @Binding var optimizeImagesOnImport: Bool

    // iCloud sync setting - uses UserDefaults directly because changing it requires restart
    @State private var iCloudSyncEnabled = SchemaVersioning.isICloudSyncEnabled
    @State private var showRestartAlert = false
    @State private var pendingSyncValue: Bool? = nil

    // Debug state
    #if DEBUG
    @Environment(\.modelContext) private var modelContext
    @State private var iCloudAccountStatus: String = "Checking..."
    @State private var lastSyncAttempt: Date? = nil
    @State private var syncStatusMessage: String = ""
    #endif

    var body: some View {
        Form {
            Section("Import") {
                Toggle("Optimize images on import", isOn: $optimizeImagesOnImport)
                Text("MultiScan will optimize images it stores to save storage.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("iCloud") {
                Toggle("Sync projects with iCloud", isOn: $iCloudSyncEnabled)
                    .onChange(of: iCloudSyncEnabled) { oldValue, newValue in
                        // Don't process if alert is already showing (means we're reverting the toggle)
                        guard oldValue != newValue, !showRestartAlert else { return }
                        pendingSyncValue = newValue
                        showRestartAlert = true
                        // Revert the toggle until user confirms
                        iCloudSyncEnabled = oldValue
                    }

                Text("Sync your MultiScan projects in iCloud to work with them across your devices. Larger projects may use significant iCloud storage.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            #if DEBUG
            Section("Debug: CloudKit Status") {
                LabeledContent("Setting Enabled") {
                    Text(iCloudSyncEnabled ? "Yes" : "No")
                        .foregroundColor(iCloudSyncEnabled ? .green : .secondary)
                }

                LabeledContent("Container Active") {
                    // Check if container was created with CloudKit
                    Text(SchemaVersioning.isICloudSyncEnabled ? "Yes" : "No (restart required)")
                        .foregroundColor(SchemaVersioning.isICloudSyncEnabled ? .green : .orange)
                }

                LabeledContent("iCloud Account") {
                    Text(iCloudAccountStatus)
                        .foregroundColor(iCloudAccountStatus == "Available" ? .green : .orange)
                }

                LabeledContent("Container ID") {
                    Text("iCloud.co.jservices.MultiScan")
                        .font(.caption)
                        .textSelection(.enabled)
                }

                LabeledContent("Device ID") {
                    Text(SchemaMetadata.currentDeviceID.prefix(8) + "...")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }

                if let lastSync = lastSyncAttempt {
                    LabeledContent("Last Sync Attempt") {
                        Text(lastSync, style: .relative)
                    }
                }

                if !syncStatusMessage.isEmpty {
                    Text(syncStatusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button("Force Sync Now") {
                    forceSyncNow()
                }
                .disabled(!SchemaVersioning.isICloudSyncEnabled)

                Button("Test CloudKit Access") {
                    Task { await testCloudKitAccess() }
                }

                Button("Refresh Status") {
                    Task { await checkICloudStatus() }
                }
            }
            .onAppear {
                Task { await checkICloudStatus() }
            }
            #endif
        }
        .formStyle(.grouped)
        .alert("Restart Required", isPresented: $showRestartAlert) {
            Button("Cancel", role: .cancel) {
                pendingSyncValue = nil
            }
            Button(pendingSyncValue == true ? "Enable & Close" : "Disable & Close") {
                if let newValue = pendingSyncValue {
                    // Save the new setting
                    UserDefaults.standard.set(newValue, forKey: SchemaVersioning.iCloudSyncEnabledKey)
                    // On iOS, we can't programmatically quit - just inform the user
                }
            }
        } message: {
            if pendingSyncValue == true {
                Text("Your projects will begin syncing to and from iCloud after you close and reopen MultiScan.")
            } else {
                Text("Close and reopen MultiScan to disable iCloud sync. Your projects will remain on this device but will no longer sync with other devices.")
            }
        }
    }

    #if DEBUG
    private func checkICloudStatus() async {
        do {
            let container = CKContainer(identifier: "iCloud.co.jservices.MultiScan")
            let status = try await container.accountStatus()
            await MainActor.run {
                switch status {
                case .available:
                    iCloudAccountStatus = "Available"
                case .noAccount:
                    iCloudAccountStatus = "No Account"
                case .restricted:
                    iCloudAccountStatus = "Restricted"
                case .couldNotDetermine:
                    iCloudAccountStatus = "Could Not Determine"
                case .temporarilyUnavailable:
                    iCloudAccountStatus = "Temporarily Unavailable"
                @unknown default:
                    iCloudAccountStatus = "Unknown"
                }
            }
        } catch {
            await MainActor.run {
                iCloudAccountStatus = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func forceSyncNow() {
        lastSyncAttempt = Date()
        syncStatusMessage = "Saving context to trigger sync..."

        do {
            try modelContext.save()
            syncStatusMessage = "Context saved. CloudKit should sync automatically."
        } catch {
            syncStatusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Tests direct CloudKit access by saving a test record to the private database.
    /// This bypasses SwiftData/Core Data to verify the container is accessible.
    private func testCloudKitAccess() async {
        syncStatusMessage = "Testing CloudKit access..."

        let container = CKContainer(identifier: "iCloud.co.jservices.MultiScan")
        let privateDB = container.privateCloudDatabase

        // Create a simple test record
        let testRecord = CKRecord(recordType: "TestRecord")
        testRecord["testValue"] = "Test from MultiScan at \(Date())" as CKRecordValue

        do {
            let savedRecord = try await privateDB.save(testRecord)
            await MainActor.run {
                syncStatusMessage = "✅ CloudKit access OK! Saved record: \(savedRecord.recordID.recordName)"
            }

            // Clean up - delete the test record
            try? await privateDB.deleteRecord(withID: savedRecord.recordID)

        } catch let error as CKError {
            await MainActor.run {
                syncStatusMessage = "❌ CloudKit error: \(error.code.rawValue) - \(error.localizedDescription)"
                print("☁️ CloudKit Test Error: \(error)")
                if let partialErrors = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
                    for (key, partialError) in partialErrors {
                        print("☁️   Partial error for \(key): \(partialError)")
                    }
                }
            }
        } catch {
            await MainActor.run {
                syncStatusMessage = "❌ Error: \(error.localizedDescription)"
            }
        }
    }
    #endif
}
#endif
