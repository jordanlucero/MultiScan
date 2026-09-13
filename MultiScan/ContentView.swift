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
    @State private var selectedDocument: Document?

    var body: some View {
        Group {
            if let document = selectedDocument {
                documentView(for: document)
                    // A deep link can switch straight from one project to another; new identity gives the review view fresh `@State` (navigation, controllers) for the new document.
                    .id(document.persistentModelID)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                HomeView(onDocumentSelected: { document in
                    withAnimation(.easeInOut(duration: 0.25)) {
                        selectedDocument = document
                    }
                })
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
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
