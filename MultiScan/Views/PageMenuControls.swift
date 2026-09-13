//
//  PageMenuControls.swift
//  MultiScan
//
//  Small menu-item building blocks shared by every place that offers page actions: the thumbnail context menu, the iPad/iPhone "More" menus, and the macOS menu bar.
//
//  These are deliberately *pieces* rather than one monolithic menu — each call site keeps its own grouping (Section vs Divider) and ordering, but the item bodies and their labels/symbols live in exactly one place.
//

import SwiftUI

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
    @ObservedObject var navigationState: NavigationState

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
    @ObservedObject var navigationState: NavigationState

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
