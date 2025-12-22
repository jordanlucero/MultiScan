# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

## Adding New Features

When extending functionality:
1. New data models should be `@Model` classes in separate files
2. Use `@Query` for reactive data fetching in views
3. Access `modelContext` from environment for CRUD operations
4. Follow SwiftUI view composition patterns

## Full Document Text Cache

The `NavigationState` class maintains a cached copy of the full document text:
- `fullDocumentPlainText: String` - Plain text for search/TTS
- `fullDocumentAttributedText: AttributedString` - Rich text with formatting

### Cache Invalidation
The cache is rebuilt when:
- Document selection changes (via `setupNavigation(for:)`)
- Call `rebuildTextCache()` manually after page text edits

### Accessibility Integration
- `fullDocumentPlainText` available via `FocusedValues` for app-level access
- Text selection enabled in `RichTextSidebar` via `.textSelection(.enabled)`
- Note: macOS Edit > Speech menu requires NSTextView in responder chain (not currently implemented to avoid AppKit dependency)

### Future: Search Implementation
To implement document search:
1. Use `fullDocumentPlainText` for search queries
2. Use `String.range(of:)` for matching (AVOID `NSRegularExpression` TO AVOID APPKIT)
3. Map character positions back to page numbers for navigation
4. Consider adding a search index for large documents (100+ pages)
