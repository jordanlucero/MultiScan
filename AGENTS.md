# AGENTS.md

## Project Overview

MultiScan is a macOS SwiftUI application that uses SwiftData for persistence. Currently implements a basic timestamp-based item management system with a master-detail interface.

## Technology Stack

- **Platform**: macOS 26.0+
- **UI Framework**: SwiftUI
- **Persistence**: SwiftData
- **Language**: Swift 6.0+
- **IDE**: Xcode 26.0+

## Architecture

### Core Components

1. **MultiScanApp.swift**: Entry point, configures SwiftData model container
2. **ContentView.swift**: Main UI with NavigationSplitView (sidebar + detail)
3. **Item.swift**: SwiftData model for timestamp-based items

### Data Flow
- SwiftData `@Model` class (Item) for persistence
- `@Query` property wrapper for reactive data fetching
- `modelContext` from environment for data operations

## Development Commands

### Build and Run
```bash
# Open in Xcode
open MultiScan.xcodeproj

# Build from command line
xcodebuild -scheme MultiScan -configuration Debug build

# Run from command line
xcodebuild -scheme MultiScan -configuration Debug -destination 'platform=macOS' build
```

### Clean
```bash
xcodebuild -scheme MultiScan clean
```

## Key Implementation Details

- **App Sandbox**: Enabled with read-only user file access (`com.apple.security.files.user-selected.read-only`)
- **Minimum Deployment**: macOS 26.0
- **SwiftData Container**: Automatically manages SQLite database for Item model
- **Navigation**: Split view pattern suitable for document-based or list-detail interfaces
- **OCR Processing**: `OCRService.processImagesInFolder` now runs work off the main actor and only hops to the main actor for UI-bound state updates (`isProcessing`, `progress`, `currentFile`). Avoid putting long-running OCR/image work back on the main actor or the app will beach-ball again.
- **Progress UI**: OCR progress lives inline in the home project list (linear bar + spinner) with no modal overlay; keep it single-line to avoid layout jumps.
- **Swift 6 readiness**: Directory traversal in `OCRService` now uses `enumerator.nextObject()` (no `makeIterator` in async context), and warnings like unused locals (e.g., `offset` in `TextFormatter`) are cleaned up. Keep async code free of synchronous iteration patterns that are banned under Swift 6 strict concurrency.
- **Concurrency safety**: `SecurityScopedResourceManager` is marked `@unchecked Sendable` with `AccessedResource: Sendable`, and AppKit was removed from that file (Foundation-only). All shared mutable state stays behind a serial queue; keep any new mutable state on the same queue or make the type an actor if you add async APIs.
- **Sendability**: `OCRService` is `final @unchecked Sendable` so it can be captured by background tasks while progress mutations stay on the main actor. Keep state mutations wrapped in `await MainActor.run` to preserve thread safety.
- **OCR task pumps results by ID**: Background OCR work now only captures IDs/URLs/bookmarks and applies results on the main actor via `model(for:)` lookups to avoid sending `Document`/`ModelContext` across executors. Keep future mutations on the main actor and avoid capturing persistent models in detached tasks.
- **Image processing without AppKit**: `OCRService` now uses ImageIO/CoreGraphics for loading, thumbnailing, and JPEG generation (no `NSImage` dependency). `TextFormatter` still needs AppKit for `NSFont` and `NSPasteboard` copy support on macOS.

## Adding New Features

When extending functionality:
1. New data models should be `@Model` classes in separate files
2. Use `@Query` for reactive data fetching in views
3. Access `modelContext` from environment for CRUD operations
4. Follow SwiftUI view composition patterns
