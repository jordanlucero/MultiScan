//
//  MultiScanCommands.swift
//  MultiScan
//
//  The menu bar (macOS + iPadOS) and hardware-keyboard commands. Everything that acts on a project reads the focused review view's state through `FocusedValues` (see `MultiScanApp.swift`), so a command is enabled exactly when a window that can perform it has focus.
//

import SwiftUI

struct MultiScanCommands: Commands {
    @AppStorage("showStatisticsPane") private var showStatisticsPane = false
    @AppStorage("showSmartCleanup") private var showSmartCleanup = false
    @AppStorage("showThumbnails") private var showThumbnails = true
    @AppStorage("showTextPanel") private var showTextPanel = true
    @AppStorage("filterOption") private var filterOption = PageFilterOption.all.rawValue
    @AppStorage("viewerShowsHDR") private var viewerShowsHDR = true

    @FocusedValue(\.navigationState) private var navigationState
    @FocusedValue(\.pageTextController) private var textController
    @FocusedValue(\.imageZoomController) private var zoomController
    @FocusedBinding(\.showExportPanel) private var showExportPanel
    @FocusedBinding(\.showAddFromPhotos) private var showAddFromPhotos
    @FocusedBinding(\.showAddFromFiles) private var showAddFromFiles
    @FocusedBinding(\.showFindNavigator) private var showFindNavigator
    @FocusedBinding(\.showDeletePageConfirmation) private var showDeletePageConfirmation

    private var document: Document? { navigationState?.selectedDocument }
    private var currentPage: Page? { navigationState?.currentPage }

    var body: some Commands {
        fileCommands
        editCommands
        formatCommands
        imageCommands
        viewCommands

        #if os(macOS)
        // ⚠️ WORKAROUND: goes away with the custom Settings window (see SettingsView.swift).
        CommandGroup(replacing: .appSettings) {
            OpenSettingsCommand()
        }
        #endif

        CommandGroup(replacing: .help) {
            Link("MultiScan Documentation", destination: URL(string: "https://multiscan.jservices.co/help")!)
            Link("Open MultiScan Repository on GitHub", destination: URL(string: "https://github.com/jordanlucero/MultiScan")!)
        }
    }

    // MARK: - File

    private var fileCommands: some Commands {
        CommandGroup(after: .newItem) {
            Divider()

            Button("Append Pages from Photos…", systemImage: "plus") {
                showAddFromPhotos = true
            }
            .disabled(showAddFromPhotos == nil)

            Button("Append Pages from Files…") {
                showAddFromFiles = true
            }
            .disabled(showAddFromFiles == nil)

            Divider()

            // A ShareLink may not honor `.disabled()`, so the item is swapped for a disabled button when there is no page.
            if let page = currentPage {
                ShareLink("Export Page Text…",
                          item: RichText(textController?.attributedTextForExport ?? page.attributedText),
                          preview: SharePreview(String(localized: "Page \(page.pageNumber) Text")))
            } else {
                Button("Export Page Text…", systemImage: "square.and.arrow.up") {}
                    .disabled(true)
            }

            Button("Export Project Text…") {
                textController?.saveNow()
                showExportPanel = true
            }
            .keyboardShortcut("C", modifiers: [.command, .option])
            .disabled(document == nil)
        }
    }

    // MARK: - Edit

    private var editCommands: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Find…") {
                showFindNavigator = true
            }
            .keyboardShortcut("F", modifiers: [.command])
            .disabled(showFindNavigator == nil)

            Divider()

            Button(currentPage?.isDone == true ? "Mark Page as Not Reviewed" : "Mark Page as Reviewed",
                   systemImage: currentPage?.isDone == true ? "x.circle" : "checkmark.circle") {
                navigationState?.toggleCurrentPageDone()
            }
            .keyboardShortcut("D", modifiers: [.command])
            .disabled(currentPage == nil)

            Divider()

            Button("Move Page Up", systemImage: "arrow.up") {
                navigationState?.moveCurrentPageUp()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            .disabled(navigationState?.canMoveCurrentPageUp != true)

            Button("Move Page Down") {
                navigationState?.moveCurrentPageDown()
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(navigationState?.canMoveCurrentPageDown != true)

            Divider()

            Button("Delete Page…", systemImage: "trash", role: .destructive) {
                showDeletePageConfirmation = true
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(currentPage == nil || (document?.totalPages ?? 0) <= 1 || showDeletePageConfirmation == nil)
        }
    }

    // MARK: - Format

    private var formatCommands: some Commands {
        CommandMenu("Format") {
            Button("Bold", systemImage: "bold") {
                textController?.toggleBold()
            }
            .keyboardShortcut("B", modifiers: [.command])
            .disabled(textController == nil)

            Button("Italic", systemImage: "italic") {
                textController?.toggleItalic()
            }
            .keyboardShortcut("I", modifiers: [.command])
            .disabled(textController == nil)

            Button("Underline", systemImage: "underline") {
                textController?.toggleUnderline()
            }
            .keyboardShortcut("U", modifiers: [.command])
            .disabled(textController == nil)

            Button("Strikethrough", systemImage: "strikethrough") {
                textController?.toggleStrikethrough()
            }
            .keyboardShortcut("X", modifiers: [.command, .shift])
            .disabled(textController == nil)
        }
    }

    // MARK: - Image

    private var imageCommands: some Commands {
        CommandMenu("Image") {
            PageRotationButtons(page: currentPage, showsKeyboardShortcuts: true)

            Divider()

            PageAdjustmentToggles(page: currentPage)

            Divider()

            // Viewer-wide display preference (not a page edit): when off, the system tone-maps HDR photos down to SDR. No effect on SDR images.
            Toggle(isOn: $viewerShowsHDR) {
                Label("Show HDR", systemImage: "sun.max")
            }
        }
    }

    // MARK: - View

    private var viewCommands: some Commands {
        CommandGroup(after: .sidebar) {
            Toggle("Show Thumbnails", systemImage: "sidebar.squares.leading", isOn: $showThumbnails)
                .keyboardShortcut("S", modifiers: [.command])

            Toggle("Show Text Panel", isOn: $showTextPanel)
                .keyboardShortcut("P", modifiers: [.command, .option])

            Toggle("Show Statistics", isOn: $showStatisticsPane)
                .keyboardShortcut("T", modifiers: [.command, .shift])

            Toggle("Show Smart Cleanup", isOn: $showSmartCleanup)
                .keyboardShortcut("K", modifiers: [.command, .shift])

            Divider()

            Menu("Filter By Status", systemImage: "line.3.horizontal.decrease.circle") {
                // Labels are menu-specific; the stored values come from PageFilterOption
                Toggle("All Pages", isOn: filterBinding(for: .all))
                Toggle("Reviewed Only", isOn: filterBinding(for: .done))
                Toggle("Not Reviewed Only", isOn: filterBinding(for: .notDone))
            }

            Divider()

            Button(navigationState?.isRandomized == true ? "Use Sequential Order" : "Use Shuffled Order",
                   systemImage: navigationState?.isRandomized == true ? "arrow.left.and.line.vertical.and.arrow.right" : "shuffle") {
                navigationState?.toggleRandomization()
            }
            .disabled(document == nil)

            Button("Previous Page") {
                navigationState?.previousPage()
            }
            .keyboardShortcut("[", modifiers: [])
            .disabled(navigationState?.hasPrevious != true)

            Button("Next Page") {
                navigationState?.nextPage()
            }
            .keyboardShortcut("]", modifiers: [])
            .disabled(navigationState?.hasNext != true)

            Divider()

            Button("Fit to Window", systemImage: "magnifyingglass") {
                zoomController?.zoomToFit()
            }
            .keyboardShortcut("0", modifiers: [.command])
            .disabled(zoomController == nil)

            Button("Zoom In") {
                zoomController?.zoomIn()
            }
            .keyboardShortcut("+", modifiers: [.command])
            .disabled(zoomController == nil)

            Button("Zoom Out") {
                zoomController?.zoomOut()
            }
            .keyboardShortcut("-", modifiers: [.command])
            .disabled(zoomController == nil)
        }
    }

    /// Radio-style binding for the View ▸ Filter By Status menu: selecting an option stores it, deselecting is a no-op (one option is always active).
    private func filterBinding(for option: PageFilterOption) -> Binding<Bool> {
        Binding(
            get: { filterOption == option.rawValue },
            set: { if $0 { filterOption = option.rawValue } }
        )
    }
}
