//
//  ContentView.swift
//  MultiScan
//
//  Created by Jordan Lucero on 5/23/25.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var selectedDocument: Document?

    var body: some View {
        Group {
            if let document = selectedDocument {
                documentView(for: document)
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
        .environment(\.locale, Locale(identifier: "en"))
}

#Preview("es-419") {
    ContentView()
        .modelContainer(previewContainer())
        .environment(\.locale, Locale(identifier: "es-419"))
}
