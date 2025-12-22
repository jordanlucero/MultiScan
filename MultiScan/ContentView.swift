//
//  ContentView.swift
//  MultiScan
//
//  Created by Jordan Lucero on 5/23/25.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    var body: some View {
        NavigationStack {
            HomeView()
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
