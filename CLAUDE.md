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

## Rich Text Editing Architecture

The app uses an always-editable text model with debounced auto-save to balance responsiveness with storage efficiency.

### EditablePageText (View Model)
Located in `RichTextSidebar.swift`, this `@Observable` class wraps a Page's rich text for editing:
- Initialized when a page is selected, disposed when switching pages
- Applies display-only foreground color (stripped before saving)
- Tracks `hasUnsavedChanges` flag to prevent unnecessary writes

### Debounced Auto-Save (1.5 seconds)
Text changes trigger a debounced save via `scheduleDebouncedSave()`:
- Each keystroke cancels the previous pending save and schedules a new one
- After 1.5 seconds of idle, `saveNow()` persists changes
- Prevents disk writes on every character while saving promptly after typing stops

### Save Protection Layers
Changes are saved in these scenarios:
| Event | Trigger |
|-------|---------|
| User stops typing | Debounce timer (1.5s) |
| User switches pages | `onChange(of: currentPage)` |
| User navigates away | `onDisappear` |
| User quits app (⌘Q) | `willTerminateNotification` + `modelContext.save()` |

All save calls check `hasUnsavedChanges` first - no-op if no edits were made.

### Persistence Flow
1. `saveNow()` assigns cleaned text to `page.richText`
2. Page's `didSet` marks `richTextChanged = true`
3. SwiftData's `willSave` notification triggers `Page.willSave()`
4. Rich text is JSON-encoded to `richTextData` (external storage)
5. SwiftData commits to SQLite

### Important Notes
- No separate "view mode" vs "edit mode" - always editable
- Click outside TextEditor to unfocus (removes cursor)
- Formatting toolbar always visible in header when page selected
- `modelContext.save()` on app quit ensures synchronous disk write before termination

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
