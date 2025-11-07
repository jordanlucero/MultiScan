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
    @AppStorage("useSmartParagraphs") private var useSmartParagraphs = false

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
                Button("Copy Page Text", systemImage: "document") {
                    copyCurrentPageText()
                }
                .keyboardShortcut("C", modifiers: [.command, .shift])
                .disabled(focusedNavigationState?.currentPage == nil)

                Button("Copy All Pages Text", systemImage: "document.on.document") {
                    copyAllPagesText()
                }
                .keyboardShortcut("C", modifiers: [.command, .option])
                .disabled(focusedDocument == nil)

                Divider()
                
                Button(focusedNavigationState?.currentPage?.isDone == true ? "Mark as Not Reviewed" : "Mark as Reviewed",
                       systemImage: focusedNavigationState?.currentPage?.isDone == true ? "checkmark.circle" : "x.circle") {
                    focusedNavigationState?.toggleCurrentPageDone()
                }
                .keyboardShortcut("D", modifiers: [.command])
                .disabled(focusedNavigationState?.currentPage == nil)
            }

            // View Menu Commands
            CommandGroup(after: .sidebar) {
                Toggle("Show Thumbnails", systemImage: "sidebar.squares.leading", isOn: $showThumbnails)
                    .keyboardShortcut("T", modifiers: [.command, .option])

                Toggle("Show Text Panel", systemImage: "sidebar.trailing", isOn: $showTextPanel)
                    .keyboardShortcut("P", modifiers: [.command, .option])

                Toggle("Show Statistics", systemImage: "chart.bar.xaxis", isOn: $showStatisticsPane)
                    .keyboardShortcut("T", modifiers: [.command, .shift])

                Divider()

                Toggle("Use Smart Paragraphs (Experimental)", isOn: $useSmartParagraphs)
                    .keyboardShortcut("P", modifiers: [.command, .shift])

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
                .keyboardShortcut("R", modifiers: [.command])
                .disabled(focusedDocument == nil)

                Divider()

                Button("Zoom In", systemImage: "plus.magnifyingglass") {
                    NotificationCenter.default.post(name: .zoomIn, object: nil)
                }
                .keyboardShortcut("+", modifiers: [.command])
                .disabled(focusedDocument == nil)

                Button("Zoom Out", systemImage: "minus.magnifyingglass") {
                    NotificationCenter.default.post(name: .zoomOut, object: nil)
                }
                .keyboardShortcut("-", modifiers: [.command])
                .disabled(focusedDocument == nil)

                Button("Fit to Window", systemImage: "arrow.down.left.and.arrow.up.right.rectangle") {
                    NotificationCenter.default.post(name: .zoomActualSize, object: nil)
                }
                .keyboardShortcut("0", modifiers: [.command])
                .disabled(focusedDocument == nil)
            }

            // Help Menu Commands
            CommandGroup(after: .help) {
                Button("Open MultiScan Repository on GitHub", systemImage: "safari") {
                    if let url = URL(string: "https://github.com/jordanlucero/multiscan") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private func copyCurrentPageText() {
        guard let currentPage = focusedNavigationState?.currentPage else { return }

        let textToCopy: String
        if useSmartParagraphs && !currentPage.boundingBoxes.isEmpty {
            textToCopy = TextPostProcessor.applySmartParagraphs(
                rawText: currentPage.text,
                boundingBoxes: currentPage.boundingBoxes
            )
        } else {
            textToCopy = currentPage.text
        }

        TextFormatter.copyFormattedText(textToCopy)
    }

    private func copyAllPagesText() {
        guard let document = focusedDocument else { return }
        let sortedPages = document.pages.sorted { $0.pageNumber < $1.pageNumber }

        let allText: String
        if useSmartParagraphs {
            // Apply smart paragraphs to each page individually, then join with paragraph breaks
            let processedPages = sortedPages.map { page -> String in
                if !page.boundingBoxes.isEmpty {
                    return TextPostProcessor.applySmartParagraphs(
                        rawText: page.text,
                        boundingBoxes: page.boundingBoxes
                    )
                } else {
                    return page.text
                }
            }
            allText = processedPages.joined(separator: "\n\n")
        } else {
            allText = sortedPages
                .map { $0.text }
                .joined(separator: "\n\n")
        }

        TextFormatter.copyFormattedText(allText)
    }
}
