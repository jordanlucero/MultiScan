//
//  ContentView.swift
//  MultiScan
//
//  Created by Jordan Lucero on 5/23/25.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedDocument: Document?

    /// Imports handed over by the share extension.
    private let sharedImports = SharedImportCoordinator.shared

    var body: some View {
        @Bindable var sharedImports = sharedImports

        Group {
            if let document = selectedDocument {
                documentView(for: document)
                    // A deep link can switch straight from one project to another; new identity gives the review view fresh `@State` (navigation, controllers) for the new document.
                    .id(document.persistentModelID)
                    // ⚠️ Opacity only — no `.scale`. A scale transition lays the AppKit-hosted views (the TextKit 2 editor's scroll view) out at fractional, per-frame sizes; the text view re-fits its content size on every pass, each re-fit invalidates SwiftUI's host layout mid-layout, and when it fails to settle within one display cycle AppKit throws "more Update Constraints in Window passes than there are views in the window".
                    .transition(.opacity)
            } else {
                HomeView(onDocumentSelected: { document in
                    withAnimation(.easeInOut(duration: 0.25)) {
                        selectedDocument = document
                    }
                })
                .transition(.opacity)
            }
        }
        // Deep links from Spotlight / App Intents / app-wide search results.
        .onChange(of: router.openRequest, initial: true) { _, request in
            handleOpenRequest(request)
        }
        .onChange(of: router.wantsHome) { _, wantsHome in
            guard wantsHome else { return }
            dismissDocument()
            router.wantsHome = false
        }
        // Share sheet: pick up files the share extension staged. This view only exists when the store is usable, so the recovery screen never imports.
        .task { sharedImports.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { sharedImports.drain() }
        }
        // The share extension opens `jservicesmultiscan://shared-import` to bring the app forward.
        .onOpenURL { url in
            if url.scheme == SharedImportInbox.openAppURL.scheme { sharedImports.drain() }
        }
        #if os(macOS)
        // Route that URL to an existing window instead of letting WindowGroup open a new one.
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        #endif
        .alert("Error", isPresented: $sharedImports.errorMessage.isPresent) {
            Button("OK") { }
        } message: {
            Text(sharedImports.errorMessage ?? "")
        }
    }

    /// Switches to the requested project. The review view consumes the request (and page number) once it is showing that project.
    private func handleOpenRequest(_ request: AppRouter.OpenRequest?) {
        guard let request else { return }
        if let current = selectedDocument, current.uuid == request.projectUUID {
            return
        }
        guard let document = ProjectMaintenance.document(uuid: request.projectUUID, context: modelContext) else {
            router.consumeOpenRequest()
            return
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            selectedDocument = document
        }
    }

    /// Routes to the size-class-adaptive layout on iOS; macOS always uses ReviewView.
    @ViewBuilder
    private func documentView(for document: Document) -> some View {
        #if os(iOS)
        AdaptiveReviewView(document: document, onDismiss: dismissDocument)
        #else
        ReviewView(document: document, onDismiss: dismissDocument)
        #endif
    }

    private func dismissDocument() {
        withAnimation(.easeInOut(duration: 0.25)) {
            selectedDocument = nil
        }
    }
}

private extension Optional {
    /// `true` while a value is present; setting `false` clears it.
    var isPresent: Bool {
        get { self != nil }
        set { if !newValue { self = nil } }
    }
}

#Preview("English") {
    ContentView()
        .modelContainer(previewContainer())
        .environment(AppRouter.shared)
        .environment(\.locale, Locale(identifier: "en"))
}

#Preview("es-419") {
    ContentView()
        .modelContainer(previewContainer())
        .environment(AppRouter.shared)
        .environment(\.locale, Locale(identifier: "es-419"))
}
