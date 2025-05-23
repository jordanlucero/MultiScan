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
    }
}
