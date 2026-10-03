//
//  PageMenuControls.swift
//  MultiScan
//
//  Menu building blocks shared by every place that offers page actions: the per-page context menu (thumbnail sidebar + iPhone page grid), the iPad/iPhone "More" menu, and the macOS menu bar.
//
//  These are deliberately *pieces* rather than one monolithic menu — each call site keeps its own grouping (Section vs Divider) and ordering, but the item bodies and their labels/symbols live in exactly one place.
//

import SwiftUI
import SwiftData

// MARK: - Image

/// Rotate Clockwise / Rotate Counterclockwise.
struct PageRotationButtons: View {
    let page: Page?

    /// Adds ⌘R / ⌘⇧R. Only the macOS Image menu should set this — duplicating the shortcut on context menus would make it ambiguous.
    var showsKeyboardShortcuts = false

    var body: some View {
        Button {
            rotate(by: 90)
        } label: {
            Label("Rotate Clockwise", systemImage: "rotate.right")
        }
        .keyboardShortcut(showsKeyboardShortcuts ? KeyboardShortcut("R", modifiers: [.command]) : nil)
        .disabled(page == nil)

        Button {
            rotate(by: 270)
        } label: {
            Label("Rotate Counterclockwise", systemImage: "rotate.left")
        }
        .keyboardShortcut(showsKeyboardShortcuts ? KeyboardShortcut("R", modifiers: [.command, .shift]) : nil)
        .disabled(page == nil)
    }

    private func rotate(by degrees: Int) {
        guard let page else { return }
        page.rotation = (page.rotation + degrees) % 360
    }
}

/// Increase Contrast / Increase Black Point toggles (non-destructive display adjustments).
struct PageAdjustmentToggles: View {
    let page: Page?

    var body: some View {
        Toggle(isOn: Binding(
            get: { page?.increaseContrast ?? false },
            set: { page?.increaseContrast = $0 }
        )) {
            Label("Increase Contrast", systemImage: "circle.lefthalf.filled")
        }
        .disabled(page == nil)

        Toggle(isOn: Binding(
            get: { page?.increaseBlackPoint ?? false },
            set: { page?.increaseBlackPoint = $0 }
        )) {
            Label("Increase Black Point", systemImage: "circle.bottomhalf.filled")
        }
        .disabled(page == nil)
    }
}

// MARK: - Review

/// Marks the current page reviewed / not reviewed.
struct PageReviewStatusButton: View {
    let navigationState: NavigationState

    var body: some View {
        let isDone = navigationState.currentPage?.isDone == true
        Button {
            navigationState.toggleCurrentPageDone()
        } label: {
            Label(
                isDone ? "Mark as Not Reviewed" : "Mark as Reviewed",
                systemImage: isDone ? "checkmark.circle.fill" : "checkmark.circle"
            )
        }
    }
}

/// Switches between sequential and shuffled page order.
struct PageOrderButton: View {
    let navigationState: NavigationState

    var body: some View {
        let isRandomized = navigationState.isRandomized
        Button {
            navigationState.toggleRandomization()
        } label: {
            Label(
                isRandomized ? "Sequential Order" : "Shuffled Order",
                systemImage: isRandomized ? "shuffle.circle.fill" : "shuffle.circle"
            )
        }
    }
}

// MARK: - Delete

extension View {
    /// The one "Delete Page N?" confirmation, shared by the page context menu and the Edit ▸ Delete Page… command.
    func deletePageConfirmation(isPresented: Binding<Bool>, pageNumber: Int, onDelete: @escaping () -> Void) -> some View {
        confirmationDialog(
            "Delete Page \(pageNumber)?",
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the page from your project. This cannot be undone.")
        }
    }
}

// MARK: - Page Context Menu

/// The one per-page context menu, shared by the thumbnail sidebar (macOS + iPad) and the iPhone page grid: info header, export, rotation, adjustments, move up/down, insert (iOS), delete — with its confirmation dialog.
struct PageContextMenu: ViewModifier {
    let page: Page
    let document: Document
    let navigationState: NavigationState

    /// Insert-at-position callbacks; the Int is the page number to insert after (0 = at the beginning). Shown on iOS only — macOS appends through the File menu.
    var onInsertFromPhotos: ((Int) -> Void)?
    var onInsertFromFiles: ((Int) -> Void)?

    @Environment(\.modelContext) private var modelContext
    @State private var showDeleteConfirmation = false

    /// Whether this page has a neighbor to swap with (adjacent page number exists)
    private var canMoveUp: Bool {
        document.unwrappedPages.contains { $0.pageNumber == page.pageNumber - 1 }
    }

    private var canMoveDown: Bool {
        document.unwrappedPages.contains { $0.pageNumber == page.pageNumber + 1 }
    }

    func body(content: Content) -> some View {
        content
            .contextMenu {
                // Page info header (non-interactive)
                Section {
                    Text("Page \(page.pageNumber) of \(document.totalPages)")
                    if let filename = page.originalFileName {
                        Text(filename)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    ShareLink(item: RichText(page.attributedText),
                              preview: SharePreview(String(localized: "Page \(page.pageNumber) Text"))) {
                        Label("Export Page Text…", systemImage: "square.and.arrow.up")
                    }
                }

                Section {
                    PageRotationButtons(page: page)
                }

                Section {
                    PageAdjustmentToggles(page: page)
                }

                // Reordering (undoable, through NavigationState)
                Section {
                    Button {
                        navigationState.movePage(page, by: -1)
                    } label: {
                        Label("Move Page Up", systemImage: "arrow.up")
                    }
                    .disabled(!canMoveUp)

                    Button {
                        navigationState.movePage(page, by: 1)
                    } label: {
                        Label("Move Page Down", systemImage: "arrow.down")
                    }
                    .disabled(!canMoveDown)
                }

                #if os(iOS)
                if onInsertFromPhotos != nil || onInsertFromFiles != nil {
                    Section {
                        insertMenu("Insert Pages Before", insertAfter: page.pageNumber - 1)
                        insertMenu("Insert Pages After", insertAfter: page.pageNumber)
                    }
                }
                #endif

                Section {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete Page…", systemImage: "trash")
                    }
                    .disabled(document.totalPages <= 1)
                }
            }
            .deletePageConfirmation(isPresented: $showDeleteConfirmation, pageNumber: page.pageNumber) {
                withAnimation {
                    navigationState.deletePage(page, modelContext: modelContext)
                }
            }
    }

    #if os(iOS)
    private func insertMenu(_ title: LocalizedStringKey, insertAfter: Int) -> some View {
        Menu {
            if let onInsertFromPhotos {
                Button("From Photos…", systemImage: "photo.on.rectangle") {
                    onInsertFromPhotos(insertAfter)
                }
            }
            if let onInsertFromFiles {
                Button("From Files…", systemImage: "folder") {
                    onInsertFromFiles(insertAfter)
                }
            }
        } label: {
            Label(title, systemImage: "doc.badge.plus")
        }
    }
    #endif
}

extension View {
    /// Attaches the shared per-page context menu (and its delete confirmation) to a page cell.
    func pageContextMenu(
        for page: Page,
        in document: Document,
        navigationState: NavigationState,
        onInsertFromPhotos: ((Int) -> Void)? = nil,
        onInsertFromFiles: ((Int) -> Void)? = nil
    ) -> some View {
        modifier(PageContextMenu(
            page: page,
            document: document,
            navigationState: navigationState,
            onInsertFromPhotos: onInsertFromPhotos,
            onInsertFromFiles: onInsertFromFiles
        ))
    }
}

// MARK: - Export & Statistics

/// Opens the export panel.
struct ExportProjectTextButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Export Project Text…", systemImage: "square.and.arrow.up.on.square")
        }
    }
}

/// Non-interactive word/character count for a page.
struct PageStatisticsLabel: View {
    let page: Page

    var body: some View {
        let plain = page.plainText
        Label("\(TextStatistics.wordCount(of: plain)) words, \(plain.count) characters",
              systemImage: "textformat")
    }
}
