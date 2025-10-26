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

    @FocusedValue(\.document) private var focusedDocument: Document?
    @FocusedValue(\.navigationState) private var focusedNavigationState: NavigationState?

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
        }
        .modelContainer(sharedModelContainer)
        .commands {
            // Edit Menu Commands
            CommandGroup(after: .pasteboard) {
                Button("Copy Page Text") {
                    copyCurrentPageText()
                }
                .keyboardShortcut("C", modifiers: [.command, .shift])
                .disabled(focusedNavigationState?.currentPage == nil)

                Button("Copy All Pages Text") {
                    copyAllPagesText()
                }
                .keyboardShortcut("C", modifiers: [.command, .option])
                .disabled(focusedDocument == nil)

                Divider()

                Button(focusedNavigationState?.currentPage?.isDone == true ? "Mark as Not Reviewed" : "Mark as Reviewed") {
                    focusedNavigationState?.toggleCurrentPageDone()
                }
                .keyboardShortcut("D", modifiers: [.command])
                .disabled(focusedNavigationState?.currentPage == nil)
            }

            // View Menu Commands
            CommandGroup(after: .sidebar) {
                Toggle("Show Thumbnails", isOn: $showThumbnails)
                    .keyboardShortcut("T", modifiers: [.command, .option])

                Toggle("Show Text Panel", isOn: $showTextPanel)
                    .keyboardShortcut("P", modifiers: [.command, .option])

                Toggle("Show Statistics", isOn: $showStatisticsPane)
                    .keyboardShortcut("T", modifiers: [.command, .shift])

                Divider()

                Menu("Filter") {
                    Button("All Pages") {
                        filterOption = "all"
                    }

                    Button("Reviewed Only") {
                        filterOption = "done"
                    }

                    Button("Not Reviewed Only") {
                        filterOption = "notDone"
                    }
                }

                Divider()

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

                Button("Go to Page...") {
                    // This will be handled in ReviewView
                }
                .keyboardShortcut("G", modifiers: [.command])
                .disabled(focusedDocument == nil)

                Button(focusedNavigationState?.isRandomized == true ? "Sequential Order" : "Shuffled Order") {
                    focusedNavigationState?.toggleRandomization()
                }
                .keyboardShortcut("R", modifiers: [.command])
                .disabled(focusedDocument == nil)

                Divider()

                Button("Zoom In") {
                    NotificationCenter.default.post(name: .zoomIn, object: nil)
                }
                .keyboardShortcut("+", modifiers: [.command])
                .disabled(focusedDocument == nil)

                Button("Zoom Out") {
                    NotificationCenter.default.post(name: .zoomOut, object: nil)
                }
                .keyboardShortcut("-", modifiers: [.command])
                .disabled(focusedDocument == nil)

                Button("Actual Size") {
                    NotificationCenter.default.post(name: .zoomActualSize, object: nil)
                }
                .keyboardShortcut("0", modifiers: [.command])
                .disabled(focusedDocument == nil)
            }

            // Help Menu Commands
            CommandGroup(after: .help) {
                Button("Open on GitHub") {
                    if let url = URL(string: "https://github.com/jordanlucero/multiscan") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private func copyCurrentPageText() {
        guard let currentPage = focusedNavigationState?.currentPage else { return }
        TextFormatter.copyFormattedText(currentPage.text)
    }

    private func copyAllPagesText() {
        guard let document = focusedDocument else { return }
        let sortedPages = document.pages.sorted { $0.pageNumber < $1.pageNumber }
        let allText = sortedPages
            .map { $0.text }
            .joined(separator: "\n\n")
        TextFormatter.copyFormattedText(allText)
    }
}
