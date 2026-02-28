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
2. **HomeView.swift**: Document list with creation/import functionality
3. **ReviewView.swift**: Main document editing UI with NavigationSplitView
4. **Models.swift**: SwiftData models (`Document`, `Page`)

### Data Models
- **Document**: Container for pages with metadata (name, emoji, storage size). Uses optional `pages` relationship with `unwrappedPages` accessor for CloudKit compatibility.
- **Page**: Individual page with image, rich text, thumbnails, and display settings. All properties have default values for CloudKit sync.

### Data Flow
- SwiftData `@Model` classes for persistence
- `@Query` property wrapper for reactive data fetching
- `modelContext` from environment for CRUD operations
- `NavigationState` (`@Observable`) for UI state management

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
- **CloudKit Sync**: Enabled via `.private("iCloud.co.jservices.MultiScan")` container

## CloudKit Sync Architecture

The app uses SwiftData with CloudKit for automatic iCloud sync across devices.

### ModelContainer Configuration (`MultiScanApp.swift`)
```swift
let modelConfiguration = ModelConfiguration(
    schema: schema,
    isStoredInMemoryOnly: false,
    cloudKitDatabase: .private("iCloud.co.jservices.MultiScan")
)
```

### CloudKit Requirements
All SwiftData properties must have default values, and all relationships must be optional:

**Page model:**
```swift
var pageNumber: Int = 0
var createdAt: Date = Date()
var document: Document?  // Relationship must be optional
```

**Document model:**
```swift
var name: String = ""
var totalPages: Int = 0
var createdAt: Date = Date()
@Relationship(deleteRule: .cascade) var pages: [Page]? = []  // Optional with default
```

### Accessing the Optional Relationship
Use `unwrappedPages` computed property for convenient read access:
```swift
// On Document model
var unwrappedPages: [Page] {
    pages ?? []
}

// Usage in views/services
document.unwrappedPages.filter { $0.isDone }  // Read operations
document.pages?.append(page)                   // Write operations (optional chaining)
```

### Entitlements (`MultiScan.entitlements`)
- `com.apple.developer.icloud-container-identifiers`: `iCloud.co.jservices.MultiScan`
- `com.apple.developer.icloud-services`: `CloudKit`
- `aps-environment`: `development` (for sync notifications)

### Development Schema Initialization
CloudKit requires the data schema to be pushed to iCloud's development environment before sync works. This is handled automatically in DEBUG builds via `NSPersistentCloudKitContainer.initializeCloudKitSchema()`.

**First run setup:**
1. Build and run in DEBUG mode while signed into iCloud
2. The schema is pushed to CloudKit's development environment
3. Verify in CloudKit Dashboard (developer.apple.com/icloud) that `CD_Document` and `CD_Page` record types exist

**Production deployment:**
1. In CloudKit Dashboard, promote schema from Development to Production
2. This only needs to be done once before App Store release
3. Schema changes require re-promotion

The initialization code is wrapped in `#if DEBUG` so it only runs during development.

### Schema Migration Strategies

When making changes to SwiftData models after shipping to the App Store:

| Change Type | Safe? | Effect on Old App Versions |
|-------------|-------|---------------------------|
| Add property with default | ✅ Yes | Old versions ignore the new field |
| Add new @Model class | ✅ Yes | Old versions ignore new record type |
| Rename property | ⚠️ No | Old versions lose data in that field |
| Delete property | ⚠️ No | Old versions may crash or lose data |
| Change property type | ⚠️ No | Sync failures, potential data loss |

**Common strategies for handling version mismatches:**

1. **Additive-Only** (recommended): Only add new properties with defaults. Old apps just ignore fields they don't understand. (Apple Notes, Reminders use this)

2. **Version Gate**: Store a `schemaVersion: Int` in CloudKit. On launch, if cloud version > app version, show "Please update to continue syncing". (Notability does this)

3. **Graceful Degradation**: New features use new fields, core features use old fields. Old apps work but miss new features.

4. **Accept Breakage**: Make breaking changes, old versions stop working. Acceptable for personal tools or when you control all devices.

### iCloud Sync User Setting

Users can toggle iCloud sync in **Settings > Import and Storage**.

**Default: OFF** (users must opt-in)

Reasoning:
- Some users have limited iCloud storage
- Large projects (1000+ pages with images) can use significant space
- Users who want sync can enable it

**Implementation:**
- Setting stored in UserDefaults (`SchemaVersioning.iCloudSyncEnabledKey`)
- Checked at container creation time
- **Requires app restart to change** - SwiftData's `cloudKitDatabase` is configured once
- Toggle shows confirmation alert and quits app when changed

**What happens when toggled:**
- **ON → OFF**: Projects stay on device, stop syncing with other devices
- **OFF → ON**: Existing local projects begin syncing to iCloud

**If user isn't signed into iCloud:**
- Enabling sync has no visible effect - data stays local until they sign in
- No error or crash - SwiftData handles this gracefully

## Schema Versioning System

The app tracks schema versions to gracefully handle data incompatibilities and prevent crashes.

### Architecture

**Version Tracking (dual storage for resilience):**
- `UserDefaults`: Checked BEFORE container loads. Survives database corruption.
- `SchemaMetadata` model: Checked AFTER load. Detects CloudKit sync from newer app versions.

**Key Files:**
- `Services/SchemaVersioning.swift`: Version constants, `SchemaMetadata` model
- `Services/SchemaValidationService.swift`: Pre/post-load validation, integrity checks, self-healing
- `Views/SchemaRecoveryView.swift`: Recovery UI for failures/incompatibilities

### Container Load Flow (`MultiScanApp.swift`)

```
1. Pre-load check (UserDefaults)
   ├─ newerThanApp? → Show "Update Required" UI
   └─ compatible → Continue

2. Create ModelContainer
   ├─ Success → Continue
   └─ Failure → Show Recovery UI (don't crash!)

3. Post-load validation (.task {})
   ├─ Check SchemaMetadata for CloudKit sync from newer version
   ├─ Run integrity validation (totalPages, pageNumbers, orphans)
   └─ Self-heal minor issues automatically
```

### Integrity Validation & Self-Healing

Minor issues are auto-fixed without user intervention:

| Issue | Detection | Auto-Fix |
|-------|-----------|----------|
| `totalPages` mismatch | `document.totalPages != pages.count` | Recalculate from actual count |
| Page number gaps | Pages not numbered 1,2,3... | Renumber sequentially |
| Orphan pages | `page.document == nil` | Delete orphan pages |

Critical issues require user action:
- Data from newer schema version → "Update Required" prompt

### Version History

| Version | App Version | Changes |
|---------|-------------|---------|
| 1 | 1.5.1+ | Initial tracked version. Document, Page, SchemaMetadata models. |

### When to Bump Schema Version

**No bump needed (safe changes):**
- Adding new property with default value
- Adding new `@Model` class

**Bump required (breaking changes):**
- Removing a property
- Renaming a property
- Changing a property type

After bumping:
1. Increment `SchemaVersioning.currentVersion`
2. Update version history table above
3. Add handling in `SchemaValidationService` if migration logic needed

### Recovery UI

When container loading fails or data is incompatible, `SchemaRecoveryView` offers:
- **Try Again**: Retry loading (for transient issues)
- **Reset All Data**: Delete database and start fresh (with confirmation)
- **Report Issue**: Link to GitHub issues

## Adding New Features

When extending functionality:
1. New data models should be `@Model` classes in separate files
2. **CloudKit requirement**: All properties must have default values, all relationships must be optional
3. Use `@Query` for reactive data fetching in views
4. Access `modelContext` from environment for CRUD operations
5. Follow SwiftUI view composition patterns

## Rich Text Storage Architecture

The app uses **native SwiftData storage for AttributedString** (macOS 26+), eliminating the need for manual JSON encoding.

### Page Model (`Models.swift`)
```swift
@Model
final class Page {
    /// Rich text stored natively by SwiftData — no manual encoding needed
    @Attribute(.externalStorage)
    var richText: AttributedString = AttributedString() {
        didSet { lastModified = Date() }
    }

    /// Plain text accessor for search/statistics (computed from richText)
    var plainText: String {
        String(richText.characters)
    }
}
```

**Key points:**
- `AttributedString` stored directly with `@Attribute(.externalStorage)`
- SwiftData handles serialization automatically
- No transient/persistent split, no `willSave` observers, no JSON encoding
- `plainText` is computed on-the-fly for search/filter (independent of storage)

### RichTextSupport (`Services/RichTextSupport.swift`)
Provides formatting helpers and RTF export:
- `toggleBold(in:)`, `toggleItalic(in:)` — formatting mutations
- `isBold(at:)`, `isItalic(at:)` — formatting queries
- `RichText` struct — Transferable wrapper for ShareLink export

**Note:** RTF export bridges to `NSAttributedString` via CoreText (no AppKit). Uses Helvetica Neue 13pt as base font for word processor compatibility.

## Share Sheet / Transferable Architecture

The `RichText` struct conforms to `Transferable` with multiple representations for maximum app compatibility.

### Transfer Representations (Priority Order)
```swift
static var transferRepresentation: some TransferRepresentation {
    // 1. File-based RTF for Finder, Save to Files, Notes, etc.
    FileRepresentation(exportedContentType: .rtf) { ... }
        .suggestedFileName("Exported Text.rtf")

    // 2. Data-based RTF for clipboard operations (Copy)
    DataRepresentation(exportedContentType: .rtf) { ... }

    // 3. Plain text fallback - works everywhere
    ProxyRepresentation { String($0.attributedString.characters) }
}
```

### Why Multiple Representations?
- **FileRepresentation**: Required for apps like Notes, Finder, and "Save to Files" that expect file URLs. Without this, some apps show "empty URL" instead of content.
- **DataRepresentation**: Powers clipboard Copy operations.
- **ProxyRepresentation**: Universal fallback for apps that only accept plain text (e.g., Messages).

### RTF Conversion Pipeline
1. SwiftUI `AttributedString` → Check `inlinePresentationIntent` for bold/italic
2. Fallback: Check `.font` attribute and resolve via `EnvironmentValues().fontResolutionContext`
3. Apply `CTFontSymbolicTraits` (.boldTrait, .italicTrait) via CoreText
4. Convert to `NSAttributedString` with `.underlineStyle` and `.strikethroughStyle`
5. Export via `NSAttributedString.data(documentAttributes: [.documentType: .rtf])`

### Error Handling
```swift
enum RichTextExportError: LocalizedError {
    case rtfConversionFailed  // NSAttributedString → RTF failed
    case emptyContent         // Nothing to export
}
```

The `toRTFDataOrThrow()` method throws proper errors instead of returning empty data silently.

### ShareLink Usage Locations
- `ReviewView.swift` — Toolbar button for single page sharing
- `ExportPanelView.swift` — "Share…" button for full document export
- `MultiScanApp.swift` — Menu bar command (⌘⇧C)

### App Compatibility
| App | Behavior |
|-----|----------|
| Notes | Receives RTF file, renders with formatting |
| TextEdit | Full RTF support |
| Pages | Imports RTF (may simplify formatting) |
| Messages | Plain text only (uses ProxyRepresentation) |
| Finder/Save to Files | Creates .rtf file |

## Rich Text Editing Architecture

The app uses an always-editable text model with debounced auto-save to balance responsiveness with storage efficiency.

### EditablePageText (View Model)
Located in `RichTextSidebar.swift`, this `@Observable` class wraps a Page's rich text for editing:
- Initialized when a page is selected, disposed when switching pages
- Applies display-only foreground color (stripped before saving)
- Tracks `hasUnsavedChanges` flag to prevent unnecessary writes

### Debounced Auto-Save (1 second)
Text changes trigger a debounced save via `scheduleDebouncedSave()`:
- Each keystroke cancels the previous pending save and schedules a new one
- After 1 second of idle, `saveNow()` persists changes
- Prevents disk writes on every character while saving promptly after typing stops

### Save Protection Layers
Changes are saved in these scenarios:
| Event | Trigger |
|-------|---------|
| User stops typing | Debounce timer (1s) |
| User switches pages | `onChange(of: currentPage)` |
| User navigates away | `onDisappear` |
| User opens export panel | `editableText?.saveNow()` before panel opens |
| User quits app (⌘Q) | `willTerminateNotification` + `modelContext.save()` |

All save calls check `hasUnsavedChanges` first — no-op if no edits were made.

### Persistence Flow (Simplified)
1. `saveNow()` strips foreground color and assigns to `page.richText`
2. Page's `didSet` updates `lastModified` timestamp
3. SwiftData automatically persists `AttributedString` to external storage
4. No manual encoding — SwiftData handles serialization natively

### Important Notes
- No separate "view mode" vs "edit mode" — always editable
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

The export system combines all page text into a single document with configurable separators.

### Performance: Text Export Cache

**Problem**: SwiftData's `@Attribute(.externalStorage)` stores each page's `richText` in a separate external file. Loading N pages for export means N sequential disk reads on the main thread, freezing the UI for large documents (500+ pages can take minutes).

**Solution**: A pre-computed cache stores all pages' text data in a single file. Export loads one file instead of N.

### TextExportCacheService (`Services/TextExportCacheService.swift`)

Manages a cached copy of all page text data on the Document model.

#### Cache Structure
```swift
// Stored on Document.textExportCache as JSON-encoded Data
struct TextExportCache: Codable {
    var version: Int  // For future migrations
    var pages: [PageCacheEntry]
}

struct PageCacheEntry: Codable {
    let pageNumber: Int
    let fileName: String?
    let richText: AttributedString
    let wordCount: Int   // Pre-computed for separator metadata
    let charCount: Int
}
```

#### Sync Points
The cache is updated whenever page data changes:

| Event | Cache Action | Location |
|-------|--------------|----------|
| Document created (after OCR) | `buildInitialCache()` | `HomeView.updateDocument()` |
| Page text saved | `updateEntry()` | `EditablePageText.saveNow()` |
| Page added to document | `addEntries()` | `ReviewView.addPagesToDocument()` |
| Page deleted | `removeEntry()` | `NavigationState.deleteCurrentPage()`, `ThumbnailSidebar.deletePage()` |
| Page reordered | `swapPageNumbers()` | `NavigationState.moveCurrentPageUp/Down()`, `ThumbnailSidebar.movePageUp/Down()` |

#### Key Methods
```swift
// Build initial cache (call after OCR while data is in memory)
static func buildInitialCache(for document: Document, from pages: [Page])

// Update single page entry (call after page text edit)
static func updateEntry(pageNumber: Int, richText: AttributedString, in document: Document)

// Add new page entries (call after adding pages to existing document)
static func addEntries(for pages: [Page], to document: Document)

// Remove page entry (call after page deletion)
static func removeEntry(pageNumber: Int, from document: Document)

// Swap page numbers (call after page reorder)
static func swapPageNumbers(_ pageNumber1: Int, _ pageNumber2: Int, in document: Document)

// Load cache for export
static func loadCache(from document: Document) -> TextExportCache?
```

#### Cache Resilience
- **Version checking**: Cache includes version number for future migrations
- **Fallback**: If cache is invalid or missing, TextExporter falls back to direct page loading
- **Recovery**: `rebuildCache(for:)` regenerates cache from source data (triggers N loads, use sparingly)

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
Builds combined `AttributedString` from all pages. Supports two modes:

1. **Cache-based (preferred)**: Initialize with Document to enable fast single-file load
2. **Direct page access (fallback)**: Triggers N external storage loads (slow for large docs)

```swift
// Preferred: Uses cache
let exporter = TextExporter(document: document, settings: settings)

// Fallback: Direct page loading (slow)
let exporter = TextExporter(pages: pages, settings: settings)
```

### Export Pipeline (with cache)
```
1. Load document.textExportCache (single file read — fast!)
   → Decode to TextExportCache with all page entries

2. Build combined string on background thread (Task.detached)
   → Uses pre-computed wordCount/charCount from cache entries
   → Appends separators and page content using AttributedString.append()

3. Return result to main actor for display
```

### Performance Comparison

| Document Size | Without Cache | With Cache |
|---------------|---------------|------------|
| Small (< 50 pages) | Instant | Instant |
| Medium (50-200 pages) | 2-5 seconds | < 1 second |
| Large (500+ pages) | 2-5 minutes (UI freeze) | 1-3 seconds |

**Note**: The O(n²) `AttributedString.append()` issue still exists, but it runs on a background thread and is much faster than N sequential disk reads.

### ExportPanelView (`Views/ExportPanelView.swift`)
Print-panel-style sheet with live preview:
- Accepts `Document` (not pages array) to enable cache-based export
- Left pane: Scrollable preview of exported text (AttributedString in SwiftUI Text)
- Right pane: Options (visual separation toggle, separator style, mods)
- Shows spinner during async export
- Debounces setting changes by 300ms
- **Preview truncation**: Displays max 50,000 characters to avoid SwiftUI rendering freeze on large documents. Full text is still exported via ShareLink.

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
- **Thumbnails**: Always HEIC at 400px max dimension, 0.7 quality

## Smart Cleanup

Detects repeated OCR artifacts (physical page numbers and section/chapter headers) across document pages and offers one-click removal.

### How It Works

Smart Cleanup analyzes all pages via the `TextExportCache` (single file read, no N disk loads) to detect:

1. **Page numbers**: Numerals at the first or last non-empty line of each page. Matches standalone numbers (`42`), `Page X`, `p. X`, and `- X -` patterns. Also detects page numbers embedded in mixed lines (e.g., `"Chapter 1    42"`) via `decomposeHeaderLine()`.
2. **Section headers**: Text in the first 2-3 non-empty lines that repeats across 3+ contiguous pages. Each contiguous run defines a "section" with a page range. Strips trailing/leading page numbers before comparing, so `"Chapter 1  42"` and `"Chapter 1  43"` both match as `"chapter 1"`. Allows alternating left/right page headers (gap of 1 page) — e.g., "Chapter 1" on even pages and "Middletown Lights Up" on odd pages.

All matching uses **normalized comparison** (case-insensitive, whitespace-collapsed, OCR-variant dashes/quotes normalized).

### Key Files
- `Services/TextManipulationService.swift`: Analysis algorithms, data types, line removal logic
- `Views/RichTextSidebar.swift`: Smart Cleanup pane UI, state management, cleanup execution

### Data Types (in `TextManipulationService`)
- **`PageNumberDetection`**: Detected page number with page, detected numeral, line text, position (first/last line)
- **`SectionHeaderDetection`**: Detected header with normalized text, display text, page range, and `affectedPages` (actual pages with the header — may be a subset of the range for alternating headers)
- **`LineComponents`**: Result of `decomposeHeaderLine()` — splits a line into core text and optional trailing/leading page number
- **`SmartCleanupResult`**: All detections from a document analysis
- **`CleanupOption`**: Actionable cleanup options (per-page, per-range, or document-wide removal)

### Analysis Pipeline
```
TextExportCache → analyzeForSmartCleanup() → SmartCleanupResult
SmartCleanupResult + currentPageNumber → buildOptions() → [CleanupOption]
```

### UI Location
Bottom of `RichTextSidebar` inspector, below the Statistics pane. Toggled via:
- `@AppStorage("showSmartCleanup")` (default: OFF)
- View menu: "Show Smart Cleanup" (⌘⇧K)

### UI States
| State | Menu Appearance |
|-------|-----------------|
| Analyzing (3s linger + analysis) | `ProgressView` + "Checking..." (disabled) |
| No suggestions | "No suggestions" (disabled) |
| Suggestions available | "\(count) suggestions" with chevron (enabled dropdown) |

### Cleanup Options (per current page)
1. "Remove page number (42) from this page" — single page
2. "Remove "Chapter 1" from this page" — single page
3. "Remove "Chapter 1" from pages 50–65" — range
4. "Remove detected page numbers from the entire document" — all pages
5. "Remove detected section headers from the entire document" — all pages

### Timing
- Analysis runs after user lingers on a page for **3 seconds** (debounces rapid page flips)
- Only runs when the Smart Cleanup pane is visible
- After a cleanup action, re-analyzes immediately (no 3s delay)

### Removal Behavior
- Executes immediately (no confirmation dialog)
- Removes the **entire line** containing the detected text (including newline)
- Uses `AttributedString.removeSubrange()` to preserve formatting on surrounding text
- **Single-page**: Modifies `editableText.text` directly (triggers auto-save)
- **Batch (range/document-wide)**: Loads cache once, modifies all entries in memory, writes each page's `richText`, saves cache once (avoids O(N^2) decode/encode)
- After batch modification of current page, re-initializes `EditablePageText` to refresh the editor

### Line Removal (`TextManipulationService.removeLine`)
1. Splits `AttributedString` into lines via plain text
2. Finds first line whose normalized content matches the target
3. Calculates character offsets (including newline) and maps to `AttributedString.Index`
4. Calls `removeSubrange` — preserves all formatting attributes on remaining text

Supports `stripNumbers: Bool` parameter (default `false`). When `true`, strips trailing/leading page numbers from each line before comparing — used for section header removal so `"chapter 1"` matches a line containing `"Chapter 1  42"`.

### Mixed Header+Number Lines (`decomposeHeaderLine`)
Handles lines like `"Chapter 1    42"` that combine a section header with a page number:
- Splits normalized text by spaces, checks if first/last token is purely numeric
- Returns `LineComponents(coreText:, pageNumber:, fullNormalized:)`
- Only strips edge numbers — `"chapter 1 of 3 42"` → core: `"chapter 1 of 3"`, number: `42`
- Used by both page number detection (to find embedded numbers) and section header detection (to group lines ignoring varying page numbers)

### Alternating Left/Right Page Headers
Books commonly alternate headers: left pages show the chapter number, right pages show the chapter title. Detection uses a gap tolerance of 2 (allows one skipped page) when finding contiguous runs, so headers appearing on every other page still form detectable sections. `SectionHeaderDetection.affectedPages` stores only the pages that actually have the header (not every page in the range), preventing false modifications during batch removal.
