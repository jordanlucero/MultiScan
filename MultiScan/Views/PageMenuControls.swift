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

// MARK: - Actions the review view performs

/// What a page's menus can ask the review view to do. Each closure is optional: a menu shows an item only where its host can perform it. One value instead of a growing list of callback parameters on every list, cell, and menu — and the same value reaches the menu bar through `FocusedValues.pageActions`.
struct PageActions {
    /// Insert pages at a position; the Int is the page number to insert after (0 = at the beginning). The context menu offers these on iOS only — macOS appends through the File menu.
    var insertFromPhotos: ((Int) -> Void)?
    var insertFromFiles: ((Int) -> Void)?
    /// Opens the artwork capture overlay for a page.
    var captureArtwork: ((Page) -> Void)?
    /// Smart Separate after import: looks at one page / at the whole project.
    var separate: ((Page) -> Void)?
    var separateProject: (() -> Void)?
    /// Puts a separated scan back on one page.
    var rejoin: ((Page) -> Void)?
    /// Shows the whole scan a separated page was cut from.
    var viewOriginalScan: ((Page) -> Void)?
    /// Reads the page's text again with the configured engine / puts Apple Vision's text back.
    var recognizeAgain: ((Page) -> Void)?
    var restoreVisionText: ((Page) -> Void)?
}

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

/// "Capture Artwork…" — opens the crop overlay for a page. Shown wherever a page is in context (viewer context menu, page context menu, Edit menu, iPhone More menu).
struct CaptureArtworkButton: View {
    let page: Page?
    let action: () -> Void
    var showsKeyboardShortcut = false

    var body: some View {
        Button(action: action) {
            Label("Capture Artwork…", systemImage: "crop")
        }
        .keyboardShortcut(showsKeyboardShortcut ? KeyboardShortcut("A", modifiers: [.command, .shift]) : nil)
        .disabled(page == nil)
    }
}

/// Smart Separate for one page: Separate into Two Pages… (a whole scan) or Rejoin Separated Pages… (a page that was separated), and View Original Scan… — the whole image a separated page was cut from. The menu bar shows these as Edit ▸ Smart Separate; the page context menu and the iOS More menu list them inline.
struct SmartSeparateMenuItems: View {
    let page: Page?
    let actions: PageActions

    var body: some View {
        if let page, page.isSeparated {
            if let rejoin = actions.rejoin {
                Button { rejoin(page) } label: {
                    Label("Rejoin Separated Pages…", systemImage: "rectangle.portrait.on.rectangle.portrait")
                }
            }
        } else if let separate = actions.separate {
            Button { if let page { separate(page) } } label: {
                Label("Separate into Two Pages…", systemImage: "rectangle.split.2x1")
            }
            .disabled(page.map { !PageSeparationService.canSeparate($0) } ?? true)
        }

        if let viewOriginalScan = actions.viewOriginalScan {
            // Only a separated page has an original that differs from what the viewer already shows.
            Button { if let page { viewOriginalScan(page) } } label: {
                Label("View Original Scan…", systemImage: "photo")
            }
            .disabled(page?.isSeparated != true)
        }
    }
}

/// Reading a page's text again: Recognize Text Again… and, when a model wrote the current text, Restore Apple Vision Text….
struct PageRecognitionMenuItems: View {
    let page: Page?
    let actions: PageActions

    var body: some View {
        if let recognizeAgain = actions.recognizeAgain {
            Button { if let page { recognizeAgain(page) } } label: {
                Label("Recognize Text Again…", systemImage: "text.viewfinder")
            }
            .disabled(page == nil)
        }

        if let page, let restore = actions.restoreVisionText, PageRecognitionService.textCameFromModel(page) {
            Button { restore(page) } label: {
                Label("Restore Apple Vision Text…", systemImage: "arrow.uturn.backward")
            }
        }
    }
}

/// Scan-level actions for a page, inline: Smart Separate's items, then reading the text again. Used where there is no room for a submenu's extra step (page context menu, iOS More menu). Everything here that replaces or merges page text is confirmed by the host before it acts.
struct PageScanMenuItems: View {
    let page: Page?
    let actions: PageActions

    var body: some View {
        SmartSeparateMenuItems(page: page, actions: actions)
        PageRecognitionMenuItems(page: page, actions: actions)
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

// MARK: - Chapters

/// "Set Chapter Title…" / "Edit Chapter Title…" + "Remove Chapter Mark". The editing alert is owned by whoever presents these (`chapterTitleEditor`).
struct ChapterMenuItems: View {
    let page: Page?
    let onEdit: () -> Void

    var body: some View {
        let hasChapter = page?.sectionTitle != nil
        Button(action: onEdit) {
            Label(hasChapter ? "Edit Chapter Title…" : "Mark Chapter Start…", systemImage: "bookmark")
        }
        .disabled(page == nil)

        if hasChapter {
            Button {
                page?.sectionTitle = nil
                page?.sectionTitleIsAutomatic = false
                page?.document?.lastModified = Date()
            } label: {
                Label("Remove Chapter Mark", systemImage: "bookmark.slash")
            }
        }
    }
}

extension View {
    /// The one chapter-title alert: a text field prefilled with the current title. Saving writes `sectionTitle` and marks it manual so automatic detection never overrides it.
    func chapterTitleEditor(isPresented: Binding<Bool>, page: Page?, draft: Binding<String>) -> some View {
        alert(
            page?.sectionTitle == nil ? "Mark Chapter Start" : "Edit Chapter Title",
            isPresented: isPresented
        ) {
            TextField("Chapter title", text: draft)
            Button("Save") {
                let trimmed = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let page, !trimmed.isEmpty else { return }
                page.sectionTitle = trimmed
                page.sectionTitleIsAutomatic = false
                page.document?.lastModified = Date()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let page {
                Text("Page \(page.pageNumber) will begin this chapter in the sidebar, the Digest, and exports.")
            }
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

/// The one per-page context menu, shared by the thumbnail sidebar (macOS + iPad) and the iPhone page grid: info header, export/copy, capture, chapter, scan actions (separate / rejoin / read again), rotation, adjustments, move up/down, insert (iOS), delete — with its confirmation dialog and the chapter editor.
struct PageContextMenu: ViewModifier {
    let page: Page
    let document: Document
    let navigationState: NavigationState
    var actions = PageActions()

    @Environment(\.modelContext) private var modelContext
    @State private var showDeleteConfirmation = false
    @State private var isEditingChapter = false
    @State private var chapterDraft = ""

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
                    if let printed = page.printedPageLabel {
                        Text("Printed page \(printed)", comment: "Context menu header: the number printed on the physical page")
                            .foregroundStyle(.secondary)
                    }
                    if let filename = page.originalFileName {
                        Text(filename)
                            .foregroundStyle(.secondary)
                    }
                    if let engine = page.ocrEngine, engine != "vision" {
                        Text("Recognized by \(engine)", comment: "Context menu header: OCR engine that produced the page text")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    // `exportableText` swaps capture references for real images and tables for native tables (macOS) before anything leaves the app.
                    ShareLink(item: RichText(TextExporter.exportableText(for: page), suggestedName: "\(document.name) — \(page.title)"),
                              preview: SharePreview(String(localized: "Page \(page.pageNumber) Text"))) {
                        Label("Share Page Text…", systemImage: "square.and.arrow.up")
                    }
                }

                if let captureArtwork = actions.captureArtwork {
                    Section {
                        CaptureArtworkButton(page: page) { captureArtwork(page) }
                    }
                }

                Section {
                    ChapterMenuItems(page: page) {
                        chapterDraft = page.sectionTitle ?? ""
                        isEditingChapter = true
                    }
                }

                Section {
                    PageScanMenuItems(page: page, actions: actions)
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
                if actions.insertFromPhotos != nil || actions.insertFromFiles != nil {
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
            .chapterTitleEditor(isPresented: $isEditingChapter, page: page, draft: $chapterDraft)
    }

    #if os(iOS)
    private func insertMenu(_ title: LocalizedStringKey, insertAfter: Int) -> some View {
        Menu {
            if let insertFromPhotos = actions.insertFromPhotos {
                Button("From Photos…", systemImage: "photo.on.rectangle") {
                    insertFromPhotos(insertAfter)
                }
            }
            if let insertFromFiles = actions.insertFromFiles {
                Button("From Files…", systemImage: "folder") {
                    insertFromFiles(insertAfter)
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
        actions: PageActions = PageActions()
    ) -> some View {
        modifier(PageContextMenu(page: page, document: document, navigationState: navigationState, actions: actions))
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
