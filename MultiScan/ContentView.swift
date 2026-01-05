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
                ReviewView(document: document, onDismiss: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        selectedDocument = nil
                    }
                })
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
}

#Preview("English") {
    ContentView()
        .modelContainer(for: [Document.self, Page.self], inMemory: true)
        .environment(\.locale, Locale(identifier: "en"))
}

#Preview("es-419") {
    ContentView()
        .modelContainer(for: [Document.self, Page.self], inMemory: true)
        .environment(\.locale, Locale(identifier: "es-419"))
}
