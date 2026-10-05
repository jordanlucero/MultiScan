//
//  SettingsView.swift
//  MultiScan
//
//  The settings surface on every platform. macOS presents `SettingsView` in a custom `Window` scene (see the workaround note below); iOS/iPadOS present `SettingsSheetView` from the Home screen's gear button. Both host the same panes.
//
//  Panes: Import & Storage (import options, intelligence toggles, iCloud), Viewer, and — DEBUG builds only — OCR Engine (Vision vs. an on-device Core AI model vs. an LM Studio server).
//

import SwiftUI
import SwiftData
#if DEBUG
import CloudKit
#endif

// MARK: - Panes (shared)

struct ImportAndStorageSettingsView: View {
    @AppStorage(DefaultsKey.optimizeImagesOnImport) private var optimizeImagesOnImport = false
    @AppStorage(DefaultsKey.autoTitleProjects) private var autoTitleProjects = true
    @AppStorage(DefaultsKey.autoDetectChapters) private var autoDetectChapters = true

    private let ocrSettings = OCREngineSettings.shared

    // iCloud sync is read straight from UserDefaults because changing it requires a relaunch: the container is configured once per process.
    @State private var iCloudSyncEnabled = SchemaVersioning.isICloudSyncEnabled
    @State private var showRestartAlert = false
    @State private var pendingSyncValue: Bool?

    var body: some View {
        Form {
            Section("Import") {
                Toggle("Optimize images on import", isOn: $optimizeImagesOnImport)
                Text("MultiScan will optimize images it stores to save storage.")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)

                Toggle("Smart Separate", isOn: Bindable(ocrSettings).smartSeparateEnabled)
                Text("When a scan shows two facing pages, MultiScan splits it into two pages along the gutter, using the recognized text's layout. Each half is cropped to its text with a margin for easier review.")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }

            Section("Intelligence") {
                Toggle("Suggest project titles", isOn: $autoTitleProjects)
                Text(ProjectTitleSuggester.isModelAvailable
                     ? "After a new import, the on-device model proposes a title from the document's title page and running headers. You can always rename the project."
                     : "Requires Apple Intelligence. The on-device model isn't available on this device right now, so new projects keep their date-based names.")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)

                Toggle("Detect chapters", isOn: $autoDetectChapters)
                Text("Marks pages that begin a chapter, part, or section so the sidebar, Digest, and exports can group them. You can edit or remove any mark from a page's context menu.")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
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
                    .foregroundStyle(Color.secondary)
            }

            #if DEBUG
            CloudKitDebugSection(iCloudSyncEnabled: iCloudSyncEnabled)
            #endif
        }
        .formStyle(.grouped)
        .alert("Restart Required", isPresented: $showRestartAlert) {
            Button("Cancel", role: .cancel) {
                pendingSyncValue = nil
            }
            #if os(macOS)
            Button(pendingSyncValue == true ? "Enable and Quit" : "Disable and Quit") {
                applyPendingSyncValue()
                NSApp.terminate(nil)
            }
            #else
            Button(pendingSyncValue == true ? "Enable" : "Disable") {
                // iOS apps can't quit themselves; the message tells the user to relaunch.
                applyPendingSyncValue()
            }
            #endif
        } message: {
            #if os(macOS)
            if pendingSyncValue == true {
                Text("Your projects will begin syncing to and from iCloud after you quit and reopen MultiScan.")
            } else {
                Text("Quit and reopen MultiScan to disable iCloud sync. Your projects will remain on this device but will no longer sync with other devices.")
            }
            #else
            if pendingSyncValue == true {
                Text("Your projects will begin syncing to and from iCloud after you close and reopen MultiScan.")
            } else {
                Text("Close and reopen MultiScan to disable iCloud sync. Your projects will remain on this device but will no longer sync with other devices.")
            }
            #endif
        }
    }

    private func applyPendingSyncValue() {
        guard let newValue = pendingSyncValue else { return }
        UserDefaults.standard.set(newValue, forKey: SchemaVersioning.iCloudSyncEnabledKey)
    }
}

struct ViewerSettingsView: View {
    @AppStorage(DefaultsKey.viewerBackground) private var viewerBackground = ViewerBackground.system.rawValue
    private let navigationSettings = NavigationSettings.shared

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
                    .foregroundStyle(Color.secondary)

                Toggle("Navigate only between filtered pages (Shuffled)", isOn: Bindable(navigationSettings).shuffledUsesFilteredNavigation)
                Text("When shuffle is on and a filter is active, the previous and next page buttons will only visit matching pages.")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - OCR Engine (DEBUG builds only)

#if DEBUG
/// Chooses what produces page text on import. Vision always runs for layout; this picks what *also* runs and wins. Debug-only until a downloadable model ships — see `OCREngine.swift`.
struct OCREngineSettingsView: View {
    private let settings = OCREngineSettings.shared

    @State private var availableModels: [String] = []
    @State private var connectionStatus: String?
    @State private var isTestingConnection = false
    @State private var showModelFolderPicker = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Picker("Engine", selection: $settings.kind) {
                    ForEach(OCREngineKind.availableOnThisPlatform, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                Text("Apple Vision always runs to capture the page layout. With a model engine selected, the model's Markdown transcription becomes the page text and Vision's transcript is kept alongside it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("OCR Engine (Debug)")
            }

            if settings.kind == .coreAI {
                Section("On-device model") {
                    LabeledContent("Model folder") {
                        Text(settings.coreAIModelURL?.lastPathComponent ?? String(localized: "None"))
                            .foregroundStyle(settings.coreAIModelURL == nil ? .secondary : .primary)
                            .lineLimit(1)
                    }
                    Button("Choose Exported Model Folder…") { showModelFolderPicker = true }
                    Text("An export from the coreai-models tooling: a folder with the .aimodel and its tokenizer. The model must accept an image and produce text. Loading happens on the first page of an import and can take a while unless the model was compiled ahead of time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    #if !canImport(CoreAILanguageModels)
                    Label("The CoreAILanguageModels module isn't linked yet; imports will fall back to Vision. Add the apple/coreai-models package to the MultiScan target.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    #endif
                }
            }

            #if os(macOS)
            if settings.kind == .lmStudio {
                Section("Local server") {
                    TextField("Server URL", text: Binding(
                        get: { settings.lmStudioBaseURL.absoluteString },
                        set: { if let url = URL(string: $0) { settings.lmStudioBaseURL = url } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Text("LM Studio's default is http://localhost:1234. Any OpenAI-compatible chat-completions server works. Load a vision-capable model (one that accepts images) in LM Studio first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if availableModels.isEmpty {
                        TextField("Model identifier (optional)", text: $settings.lmStudioModelID)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Picker("Model", selection: $settings.lmStudioModelID) {
                            Text("Server default").tag("")
                            ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                        }
                    }

                    HStack {
                        Button(isTestingConnection ? "Testing…" : "Test Connection") { testConnection() }
                            .disabled(isTestingConnection)
                        if let connectionStatus {
                            Text(connectionStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
            #endif

            if settings.kind != .vision {
                Section("Prompt") {
                    TextEditor(text: $settings.transcriptionPrompt)
                        .font(.caption.monospaced())
                        .frame(minHeight: 120)
                    HStack {
                        Button("Reset to Default") { settings.resetPrompt() }
                        Spacer()
                        LabeledContent("Timeout per page") {
                            TextField("", value: $settings.transformerTimeout, format: .number)
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                            Text("s")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $showModelFolderPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                // The folder is copied into Application Support so the app keeps access without a security-scoped bookmark.
                settings.coreAIModelURL = Self.installModelFolder(from: url) ?? url
            }
        }
    }

    #if os(macOS)
    private func testConnection() {
        isTestingConnection = true
        connectionStatus = nil
        let base = settings.lmStudioBaseURL
        Task {
            defer { isTestingConnection = false }
            do {
                let models = try await LMStudioTranscriber.listModels(baseURL: base)
                availableModels = models
                connectionStatus = models.isEmpty
                    ? String(localized: "Connected, but no models are loaded.")
                    : String(localized: "Connected: \(models.count) models available.")
            } catch {
                connectionStatus = error.localizedDescription
            }
        }
    }
    #endif

    /// Copies an exported model folder into `Application Support/MultiScan/Models/<name>` and returns the new location.
    private static func installModelFolder(from url: URL) -> URL? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let destination = support.appending(path: "MultiScan/Models/\(url.lastPathComponent)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            print("Model install failed: \(error)")
            return nil
        }
    }
}
#endif

// MARK: - CloudKit debug tools (DEBUG builds only)

#if DEBUG
/// Direct CloudKit status and access checks that bypass SwiftData, for diagnosing sync setup.
private struct CloudKitDebugSection: View {
    let iCloudSyncEnabled: Bool

    @Environment(\.modelContext) private var modelContext
    @State private var iCloudAccountStatus: String = "Checking..."
    @State private var lastSyncAttempt: Date?
    @State private var syncStatusMessage: String = ""

    private static let containerIdentifier = "iCloud.co.jservices.MultiScan"

    var body: some View {
        Section("Debug: CloudKit Status") {
            LabeledContent("Setting Enabled") {
                Text(iCloudSyncEnabled ? "Yes" : "No")
                    .foregroundStyle(iCloudSyncEnabled ? .green : .secondary)
            }

            LabeledContent("Container Active") {
                Text(SchemaVersioning.isICloudSyncEnabled ? "Yes" : "No (restart required)")
                    .foregroundStyle(SchemaVersioning.isICloudSyncEnabled ? .green : .orange)
            }

            LabeledContent("iCloud Services") {
                Text(iCloudAccountStatus)
                    .foregroundStyle(iCloudAccountStatus == "Available" ? .green : .orange)
            }

            LabeledContent("Device ID") {
                Text(SchemaMetadata.currentDeviceID.prefix(8) + "...")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            if let lastSyncAttempt {
                LabeledContent("Last Sync Attempt") {
                    Text(lastSyncAttempt, style: .relative)
                }
            }

            if !syncStatusMessage.isEmpty {
                Text(syncStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Attempt Force Sync") {
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
        .task {
            await checkICloudStatus()
        }
    }

    private func checkICloudStatus() async {
        do {
            let status = try await CKContainer(identifier: Self.containerIdentifier).accountStatus()
            switch status {
            case .available: iCloudAccountStatus = "Available"
            case .noAccount: iCloudAccountStatus = "No Account"
            case .restricted: iCloudAccountStatus = "Restricted"
            case .couldNotDetermine: iCloudAccountStatus = "Could Not Determine"
            case .temporarilyUnavailable: iCloudAccountStatus = "Temporarily Unavailable"
            @unknown default: iCloudAccountStatus = "Unknown"
            }
        } catch {
            iCloudAccountStatus = "Error: \(error.localizedDescription)"
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

    /// Saves (and then deletes) a throwaway record in the private database to verify the container is reachable.
    private func testCloudKitAccess() async {
        syncStatusMessage = "Testing CloudKit access..."

        let privateDB = CKContainer(identifier: Self.containerIdentifier).privateCloudDatabase
        let testRecord = CKRecord(recordType: "TestRecord")
        testRecord["testValue"] = "Test from MultiScan at \(Date())" as CKRecordValue

        do {
            let savedRecord = try await privateDB.save(testRecord)
            syncStatusMessage = "CloudKit access OK! Saved record: \(savedRecord.recordID.recordName)"
            _ = try? await privateDB.deleteRecord(withID: savedRecord.recordID)
        } catch let error as CKError {
            syncStatusMessage = "CloudKit error: \(error.code.rawValue) - \(error.localizedDescription)"
            print("CloudKit Test Error: \(error)")
            if let partialErrors = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
                for (key, partialError) in partialErrors {
                    print("Partial error for \(key): \(partialError)")
                }
            }
        } catch {
            syncStatusMessage = "Error: \(error.localizedDescription)"
        }
    }
}
#endif

#if os(macOS)
// MARK: - macOS Settings window
//
// ⚠️ WORKAROUND: a custom `Window` scene stands in for SwiftUI's `Settings` scene, which (last tested in 26.3) breaks with `NavigationSplitView`. The window follows the HIG for settings windows: opened with ⌘, via `OpenSettingsCommand`, non-resizable (`.windowResizability(.contentSize)` in `MultiScanApp`), minimize/zoom disabled below, title tracks the pane.
// If a future release fixes the native scene: replace the `Window` in `MultiScanApp` with `Settings { SettingsView() }`, delete `OpenSettingsCommand` and its `CommandGroup(replacing: .appSettings)`, and drop the `onAppear` button-disabling block.

enum SettingsPane: String, CaseIterable, Identifiable {
    case importAndStorage
    case viewer
    #if DEBUG
    case ocrEngine
    #endif

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .importAndStorage: String(localized: "Import and Storage")
        case .viewer: String(localized: "Viewer")
        #if DEBUG
        case .ocrEngine: String(localized: "OCR Engine")
        #endif
        }
    }

    var icon: String {
        switch self {
        case .importAndStorage: "square.and.arrow.down"
        case .viewer: "eye"
        #if DEBUG
        case .ocrEngine: "cpu"
        #endif
        }
    }
}

struct SettingsView: View {
    @AppStorage("settingsSelectedPane") private var selectedPaneRawValue: String = SettingsPane.importAndStorage.rawValue

    private var selectedPane: Binding<SettingsPane> {
        Binding(
            get: { SettingsPane(rawValue: selectedPaneRawValue) ?? .importAndStorage },
            set: { selectedPaneRawValue = $0.rawValue }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: selectedPane) { pane in
                Label(pane.displayName, systemImage: pane.icon)
                    .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
        } detail: {
            switch selectedPane.wrappedValue {
            case .importAndStorage:
                ImportAndStorageSettingsView()
            case .viewer:
                ViewerSettingsView()
            #if DEBUG
            case .ocrEngine:
                OCREngineSettingsView()
            #endif
            }
        }
        .navigationTitle(selectedPane.wrappedValue.displayName)
        .onAppear {
            // ⚠️ WORKAROUND: the native Settings scene disables these itself.
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "settings" }) {
                window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
                window.standardWindowButton(.zoomButton)?.isEnabled = false
            }
        }
    }
}

/// App menu ▸ Settings… (⌘,). Part of the custom-window workaround above.
struct OpenSettingsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…", systemImage: "gear") {
            openWindow(id: "settings")
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

#Preview("Settings Pane (English)") {
    SettingsView()
        .environment(\.locale, Locale(identifier: "en"))
}

#Preview("Settings Pane (es-419)") {
    SettingsView()
        .environment(\.locale, Locale(identifier: "es-419"))
}

#else
// MARK: - iOS / iPadOS Settings sheet

/// Presented from the Home screen's gear button. Mirrors the panes of the macOS Settings window.
struct SettingsSheetView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    ImportAndStorageSettingsView()
                        .navigationTitle("Import and Storage")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("Import and Storage", systemImage: "square.and.arrow.down")
                }

                NavigationLink {
                    ViewerSettingsView()
                        .navigationTitle("Viewer")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("Viewer", systemImage: "eye")
                }

                #if DEBUG
                NavigationLink {
                    OCREngineSettingsView()
                        .navigationTitle("OCR Engine")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("OCR Engine (Debug)", systemImage: "cpu")
                }
                #endif
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        }
    }
}
#endif
