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
    @FocusedValue(\.showExportPanel) private var showExportPanelBinding: Binding<Bool>?
    @FocusedValue(\.showAddFromPhotos) private var showAddFromPhotosBinding: Binding<Bool>?
    @FocusedValue(\.showAddFromFiles) private var showAddFromFilesBinding: Binding<Bool>?
    @FocusedValue(\.showFindNavigator) private var showFindNavigatorBinding: Binding<Bool>?

    @State private var showDeletePageConfirmation = false

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

                Button("Append Pages from Photos…", systemImage: "photo.on.rectangle") {
                    showAddFromPhotosBinding?.wrappedValue = true
                }
                .disabled(showAddFromPhotosBinding == nil)

                Button("Append Pages from Files…", systemImage: "folder") {
                    showAddFromFilesBinding?.wrappedValue = true
                }
                .disabled(showAddFromFilesBinding == nil)
            }

            // Edit Menu Commands
            CommandGroup(after: .pasteboard) {
                Button("Find…") {
                    showFindNavigatorBinding?.wrappedValue = true
                }
                .keyboardShortcut("F", modifiers: [.command])
                .disabled(showFindNavigatorBinding == nil)

                Divider()

                ShareLink("Share Page Text…",
                          item: RichText(focusedNavigationState?.currentPage?.richText ?? AttributedString()),
                          preview: SharePreview("Page Text"))
                .keyboardShortcut("C", modifiers: [.command, .shift])
                .disabled(focusedNavigationState?.currentPage == nil)

                Button("Export All Pages…", systemImage: "doc.on.doc") {
                    focusedEditableText?.saveNow()
                    showExportPanelBinding?.wrappedValue = true
                }
                .keyboardShortcut("C", modifiers: [.command, .option])
                .disabled(focusedDocument == nil)

                Divider()
                
                Button(focusedNavigationState?.currentPage?.isDone == true ? "Mark as Not Reviewed" : "Mark as Reviewed",
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

                Menu("Filter", systemImage: "line.3.horizontal.decrease.circle") {
                    Button("All Pages", systemImage: "book.pages") {
                        filterOption = "all"
                    }

                    Button("Reviewed Only", systemImage: "checkmark.circle.fill") {
                        filterOption = "done"
                    }

                    Button("Not Reviewed Only", systemImage: "ellipsis.circle.fill") {
                        filterOption = "notDone"
                    }
                }

                Divider()

                Button("Previous Page", systemImage: "backward") {
                    focusedNavigationState?.previousPage()
                }
                .keyboardShortcut("[", modifiers: [])
                .disabled(focusedNavigationState?.hasPrevious != true)

                Button("Next Page", systemImage: "forward") {
                    focusedNavigationState?.nextPage()
                }
                .keyboardShortcut("]", modifiers: [])
                .disabled(focusedNavigationState?.hasNext != true)

                Button(focusedNavigationState?.isRandomized == true ? "Sequential Order" : "Shuffled Order",
                       systemImage: focusedNavigationState?.isRandomized == true ? "arrow.left.and.line.vertical.and.arrow.right" : "shuffle") {
                    focusedNavigationState?.toggleRandomization()
                }
                .disabled(focusedDocument == nil)

                Divider()

                Button("Zoom In", systemImage: "plus.magnifyingglass") {
                    NotificationCenter.default.post(name: .zoomIn, object: nil)
                }
                .keyboardShortcut("+", modifiers: [.command])
                .disabled(focusedDocument == nil)

                Button("Zoom Out", systemImage: "") {
                    NotificationCenter.default.post(name: .zoomOut, object: nil)
                }
                .keyboardShortcut("-", modifiers: [.command])
                .disabled(focusedDocument == nil)

                Button("Fit to Window", systemImage: "") {
                    NotificationCenter.default.post(name: .zoomActualSize, object: nil)
                }
                .keyboardShortcut("0", modifiers: [.command])
                .disabled(focusedDocument == nil)
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

        Settings {
            Form {
                Section("Import") {
                    Toggle("Optimize images on import", isOn: $optimizeImagesOnImport)
                    Text("MultiScan will optimize images it stores to save storage.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Viewer") {
                    Picker("Background", selection: $viewerBackground) {
                        ForEach(ViewerBackground.allCases, id: \.rawValue) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
            .frame(width: 400)
        }
    }

}
