# AGENTS.md

## Project Overview

MultiScan is a macOS SwiftUI application that uses SwiftData for persistence. Currently implements a basic timestamp-based item management system with a master-detail interface.

## Technology Stack

- **Platform**: macOS 26.0+
- **UI Framework**: SwiftUI
- **Persistence**: SwiftData
- **Language**: Swift 5.9+
- **IDE**: Xcode 15.0+

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

## Adding New Features

When extending functionality:
1. New data models should be `@Model` classes in separate files
2. Use `@Query` for reactive data fetching in views
3. Access `modelContext` from environment for CRUD operations
4. Follow SwiftUI view composition patterns
