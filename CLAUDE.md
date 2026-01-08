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

## Image Display & Transformation Architecture

Images are stored as `Data` with `@Attribute(.externalStorage)` in the Page model. All transformations are **non-destructive** - stored as Page properties and applied at display time.

### Page Image Properties
```swift
var rotation: Int = 0              // Degrees: 0, 90, 180, 270
var increaseContrast: Bool = false // Applies .contrast(1.3) modifier
var increaseBlackPoint: Bool = false // Applies .brightness(-0.1) modifier
```

### PlatformImage Helper (`Services/PlatformImage.swift`)
Cross-platform image loading that combines EXIF orientation with user rotation:
- `from(data:userRotation:)` - Creates SwiftUI Image with combined orientation
- `dimensions(of:userRotation:)` - Returns apparent dimensions accounting for rotation
- `combinedOrientation(exif:userRotation:)` - Lookup table merging EXIF + user rotation

### Display Pipeline
1. `PlatformImage.from(data:userRotation:)` creates rotated SwiftUI Image
2. `.contrast()` and `.brightness()` modifiers applied based on Page properties
3. Same transforms applied to both `ImageViewer` (main view) and `ThumbnailView` (sidebar)

### Rotation Change Detection
`ImageViewer` observes `navigationState.currentPage?.rotation` via `.onChange()` and reloads the image when rotation changes.

## Page Reordering

Pages are ordered by their `pageNumber: Int` property (NOT array indices). All views sort dynamically by pageNumber.

### Reordering Mechanism
- **Move Up**: Swap pageNumbers with page at `pageNumber - 1`
- **Move Down**: Swap pageNumbers with page at `pageNumber + 1`
- Filter-safe: Operations work on actual document order, not filtered view order

### NavigationState Methods
```swift
var canMoveCurrentPageUp: Bool
var canMoveCurrentPageDown: Bool
func moveCurrentPageUp()
func moveCurrentPageDown()
func refreshPageOrder()  // Call after any reorder to update internal arrays
```

### Animation
- `NavigationState.pageOrderVersion` increments on reorder
- `ThumbnailSidebar` uses `.animation(.easeInOut, value: pageOrderVersion)`
- Pages use `persistentModelID` for stable identity (enables smooth position animation)

## Page Deletion

### Delete Flow
1. Decrement `pageNumber` for all pages after deleted page
2. Remove from `document.pages` array
3. Update `document.totalPages`
4. Call `modelContext.delete(page)`
5. Refresh navigation state
6. Navigate to adjacent page if deleted page was current

### Safeguards
- Confirmation dialog required before deletion
- Cannot delete if document has only one page
- Warning that deletion is permanent (not moved to trash)

### NavigationState Method
```swift
func deleteCurrentPage(modelContext: ModelContext)
```

## Thumbnail Context Menu

Right-click on any thumbnail in `ThumbnailSidebar` shows context menu with:

| Section | Options |
|---------|---------|
| **Header** | "Page X of Y" + filename (non-interactive) |
| **Rotation** | Rotate Clockwise, Rotate Counterclockwise |
| **Adjustments** | Increase Contrast (toggle), Increase Black Point (toggle) |
| **Reordering** | Move Up, Move Down |
| **Delete** | Delete Page… (with confirmation) |

## Menu Bar Commands

### Image Menu (new)
| Command | Shortcut |
|---------|----------|
| Rotate Clockwise | ⌘R |
| Rotate Counterclockwise | ⌘⇧R |
| Increase Contrast | (toggle) |
| Increase Black Point | (toggle) |

### Edit Menu (page operations)
| Command | Shortcut |
|---------|----------|
| Move Page Up | ⌘⌥↑ |
| Move Page Down | ⌘⌥↓ |
| Delete Page… | (none) |

### FocusedValues for Menu Bar
- `currentPage: Page?` - Exposed from ReviewView for menu commands
- Menu commands use `focusedNavigationState` for move/delete operations

## Text Export Architecture

The export system combines all page text into a single document with configurable separators. Optimized for large documents (500+ pages).

### ExportSettings (`Services/ExportSettings.swift`)
`@Observable` class with UserDefaults persistence:
```swift
var createVisualSeparation: Bool  // false = inline (pages flow together)
var separatorStyle: SeparatorStyle  // .lineBreak or .hyphenatedDivider
var includePageNumber: Bool
var includeFilename: Bool
var includeStatistics: Bool
```

**Important**: Uses manual UserDefaults sync with `didSet` (not `@AppStorage`) to ensure `@Observable` reactivity works correctly.

### TextExporter (`Services/TextExporter.swift`)
Two export methods:
- `buildCombinedText()` - Synchronous, for small documents
- `buildCombinedTextAsync()` - Async with parallel processing, for large documents

### Performance Optimizations
The async pipeline addresses several bottlenecks for large documents:

| Optimization | Implementation |
|--------------|----------------|
| Parallel JSON decoding | `TaskGroup` decodes page rich text off main thread |
| O(n) string building | Uses `NSMutableAttributedString` instead of repeated `AttributedString.append()` |
| Settings snapshot | `ExportSettingsSnapshot` struct captures settings for thread-safe access |
| Debounced preview | 300ms delay prevents rapid rebuilds when clicking options |
| Duplicate observer guard | `observerRegistered` flag in Page prevents multiple notification registrations |

### ExportPanelView (`Views/ExportPanelView.swift`)
Print-panel-style sheet with live preview:
- Left pane: Scrollable preview of exported text
- Right pane: Options (visual separation toggle, separator style, mods)
- Shows spinner during async export
- Debounces setting changes by 300ms

### Separator Logic
- **Inline** (createVisualSeparation = false): Single space between pages
- **Line Break**: Double newline + optional `[Page X of Y | filename | stats]`
- **Hyphenated Divider**: 40 hyphens + metadata below

First page special case: Line break style with no mods returns empty separator (no leading whitespace).

### Localization
Exported text respects user's system language via `String(localized:)`:
```swift
// Automatically uses Spanish for es-419 users:
// "Page 1 of 5" → "Página 1 de 5"
// "245 words, 1234 characters" → "245 palabras, 1234 caracteres"
String(localized: "Page \(pageNumber) of \(totalPages)")
String(localized: "\(words) words, \(chars) characters")
```

Translations stored in `Localizable.xcstrings` (Xcode String Catalog format).

## PDF Import Architecture

PDFs can be imported alongside images via the unified file picker. Each PDF page is rendered to an image and processed through the existing OCR pipeline.

### Import Flow
```
PDF File → PDFImportService → [HEIC images per page] → OCRService → Page objects
```

1. User selects PDF via file picker (accepts `.image`, `.pdf`, `.folder`)
2. `ImageImportService` detects PDF and returns URL in `ImportResult.pdfURLs`
3. Page count is read immediately via `PDFImportService.pageCount(for:)` for VoiceOver announcement
4. `PDFImportService.renderPDF(at:)` renders pages to images in parallel
5. Rendered images feed into existing `OCRService.processImages()` pipeline
6. Each PDF page becomes a `Page` with thumbnails and OCR text

### PDFImportService (`Services/PDFImportService.swift`)

Key methods:
```swift
static func isPDF(url: URL) -> Bool           // Check if URL is a PDF
static func pageCount(for url: URL) -> Int    // Quick page count without rendering
func renderPDF(at url: URL, dpi: CGFloat = 300) async throws -> [(data: Data, fileName: String)]
```

### Rendering Details
- **Resolution**: 300 DPI (letter-size page ≈ 2550×3300 pixels)
- **Output Format**: Always HEIC at 0.8 quality (regardless of "optimize images" setting)
- **Parallel Processing**: Uses `TaskGroup` with concurrency limited to CPU core count (max 6)
- **Memory Management**: `autoreleasepool` around each page render
- **Thread Safety**: `SendablePDFDocument` wrapper for Swift 6 concurrency compliance

### Error Handling
```swift
enum PDFImportError: LocalizedError {
    case cannotLoad           // PDF file couldn't be opened
    case passwordProtected    // Encrypted PDFs not supported
    case noPages              // PDF has zero pages
    case renderingFailed(page: Int)  // Specific page failed to render
}
```

### UI Feedback
- **Spinner**: "New Project" card shows spinner with "Preparing…" during PDF rendering
- **VoiceOver**: Announces "Processing X pages" immediately after file picker closes (uses quick page count)
- **Progress**: Once OCR starts, document card shows standard progress indicator

### HomeView Integration
The `processFileURLs()` method handles mixed imports:
1. Scans files via `ImageImportService.processFileURLs()`
2. Counts PDF pages immediately for accessibility announcement
3. Renders PDFs via `PDFImportService`
4. Combines all images and starts OCR processing

### Image Compression Notes
- **Imported images**: Use HEIC only if "Optimize images on import" is enabled
- **PDF pages**: Always rendered to HEIC (since we're creating new images, not preserving originals)
- **Thumbnails**: Always HEIC at 200px max dimension, 0.7 quality
