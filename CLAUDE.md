# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MultiScan is a multiplatform SwiftUI application (macOS, iOS, iPadOS) that uses SwiftData for persistence. It imports images/PDFs, runs OCR, and provides a review/edit/export workflow for the recognized text.

## Technology Stack

- **Platforms**: macOS 27.0+, iOS/iPadOS 27.0+ (single app target, `SUPPORTED_PLATFORMS = iphoneos iphonesimulator macosx`)
- **UI Framework**: SwiftUI
- **Persistence**: SwiftData
- **Language**: Swift 6.0+
- **IDE**: Xcode 27.0+

## Architecture

### Core Components

1. **MultiScanApp.swift**: Entry point, configures SwiftData model container
2. **HomeView.swift**: Document list with creation/import functionality
3. **ReviewView.swift**: Main document editing UI with NavigationSplitView (macOS + iPad regular size class)
4. **CompactReviewView.swift**: iPhone document editing UI (iOS-only file)
5. **Models.swift**: SwiftData models (`Document`, `Page`)
6. **Views/TextKit/**: The TextKit 2 text engine — platform text views, SwiftUI representables, and the page editing controller (see "TextKit 2 Text Engine")

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
- **Minimum Deployment**: macOS 27.0, iOS/iPadOS 27.0
- **SwiftData Container**: Automatically manages SQLite database for Item model
- **Navigation**: Split view pattern suitable for document-based or list-detail interfaces
- **CloudKit Sync**: Enabled via `.private("iCloud.co.jservices.MultiScan")` container

## Multiplatform Architecture (2.0)

One app target builds for macOS, iPadOS, and iPhone. Platform differences are handled with `#if os(iOS)` / `#if os(macOS)` conditionals in shared files, plus a small set of iOS-only view files. **Guiding principle: the Mac experience stays as-is; iOS branches adapt around it.**

### Layout Routing

```
ContentView
├─ macOS ──────────────► ReviewView (NavigationSplitView + inspector)
└─ iOS ─► AdaptiveReviewView (routes by horizontalSizeClass)
          ├─ regular (iPad) ─► ReviewView (same split view as Mac, iOS toolbar)
          └─ compact (iPhone) ─► CompactReviewView
```

Size classes (`\.horizontalSizeClass`, `\.verticalSizeClass`) don't exist on macOS — any use must be wrapped in `#if os(iOS)`.

### iOS-Only View Files (entire file wrapped in `#if os(iOS)`)

| File | Purpose |
|------|---------|
| `Views/AdaptiveReviewView.swift` | Size-class router between ReviewView and CompactReviewView |
| `Views/CompactReviewView.swift` | iPhone layout: NavigationStack + full-screen ImageViewer + persistent RichTextSidebar bottom sheet (`presentationDetents`, background interaction enabled) + "More" menu toolbar |
| `Views/SlideGridView.swift` | Searchable page-grid sheet for iPhone: navigate, add pages before/after a position, reorder, delete |

CompactReviewView presents the text sheet with `interactiveDismissDisabled()` and swaps it out temporarily when the page grid or export panel opens (`onChange` handlers toggle `showTextSheet`). It also runs its own Smart Cleanup analysis (the sidebar's panes are hidden via `hideBottomPanels`).

### Platform Behavior Differences in Shared Views

| View | macOS | iOS/iPadOS |
|------|-------|------------|
| `ReviewView` toolbar | Discrete icon buttons (nav / review / progress / inspector) | Prev/Next + "More" (ellipsis) menu containing review, image, panel, export actions; progress popover attaches to the view root (can't anchor to a menu item) |
| `ThumbnailSidebar` | Existing context menu | Adds "Insert Pages Before/After" context-menu section (insert-at-position is deliberately iOS-only) |
| `RichTextSidebar` header | Page # + copy button, B/I/U/S + remove-line-breaks toolbar | Page # + copy button only (see formatting note below); Remove Line Breaks moves into the Smart Cleanup pane (iPad) or the More menu (iPhone) |
| `ExportPanelView` | Two-pane HStack (preview left, options right), radio-group picker | Vertical NavigationStack sheet (preview top, options below), segmented picker, share/dismiss in the nav bar |
| `HomeView` | Bare content in the window toolbar | Wrapped in NavigationStack, "MultiScan" title, gear (Settings) + plus toolbar; grid is fixed 2 columns on iPhone portrait, adaptive otherwise |
| `DocumentCard` | Double-click opens | Single tap opens |
| Settings | Custom Settings `Window` scene (workaround) | `SettingsSheetView` sheet from the Home gear button → Import & Storage / Viewer panes (defined in the iOS branch of MultiScanApp.swift) |

### ⚠️ Text Formatting on iOS — Do Not "Fix"

The iOS text panel header intentionally has **no Bold/Italic/Underline/Strikethrough buttons**. This is not apparent from the code: the editor's `UITextView` has `allowsEditingTextAttributes = true`, so the **system provides formatting controls in the edit menu / keyboard bar** (and the Format menu commands work for iPad hardware keyboards via `FocusedValues.pageTextController`). Do not add in-app formatting buttons on iOS.

### Undo

Typing undo is native to the platform text views on **both** platforms (macOS `allowsUndo`; iOS automatic, including shake-to-undo and three-finger swipe). Programmatic edits (formatting, Remove Line Breaks, Smart Cleanup) register snapshot undo through `PageTextController.performEdit`, joining the same undo stack. Undo history is cleared when a page loads into the editor.

### Insert Pages at Position (iOS only)

`ReviewView.addPagesToDocument` and CompactReviewView support inserting after a specific page number: existing pages/cache entries at or beyond the insertion point are shifted, then `TextExportCacheService.insertEntries(for:in:shiftingFrom:by:)` updates the cache in memory (no external-storage rebuild). Appending (the only path reachable on macOS) still uses `addEntries` as before.

### Save Protection on iOS

In addition to the shared debounce/page-switch/disappear saves, iOS adds `UIApplication.willTerminateNotification` (RichTextSidebar) and a `scenePhase == .background` save (CompactReviewView), since iOS apps are rarely quit explicitly.

### Menu Commands on iPadOS

The `.commands` block is shared across platforms — iPadOS renders them in its menu bar and hardware-keyboard shortcuts work. Only the Settings command/window is macOS-gated.

### Project Configuration Notes

- iPhone orientations: portrait + landscape (`INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone`); iPad supports all four
- Launch screen is generated (`INFOPLIST_KEY_UILaunchScreen_Generation = YES`) — there is no storyboard
- One shared entitlements file (iCloud + aps only); macOS sandbox comes from the `ENABLE_APP_SANDBOX` build setting, which iOS ignores
- The `MultiScan.icon` Icon Composer file provides the app icon for all platforms

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
| 2 | 2.0 | `Page.richTextData` **format** changed from JSON-encoded `AttributedString` to RTF (TextKit 2 engine). Property name/type unchanged, so the SwiftData/CloudKit schema is identical — but v1 apps decode the blob as JSON and would see (and could save back) empty text, so they must be gated. Migration is lazy: reads accept both formats, writes produce RTF. `SchemaMetadata.recordSuccessfulLoad()` raises the stored version so other devices' gates fire via CloudKit. |

### When to Bump Schema Version

**No bump needed (safe changes):**
- Adding new property with default value
- Adding new `@Model` class

**Bump required (breaking changes):**
- Removing a property
- Renaming a property
- Changing a property type
- Changing the **encoding format inside a `Data` blob** that older versions decode (this is what v2 did)

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

## TextKit 2 Text Engine (2.0)

Text handling is built directly on **TextKit 2** with `NSAttributedString` as the canonical text model end-to-end. SwiftUI remains the app framework, but text editing/rendering is real AppKit/UIKit hosted via representables. SwiftUI `AttributedString` and `TextEditor` are gone from the pipeline (the only remaining `AttributedString` use is decoding the legacy storage format).

### File Map
| File | Role |
|------|------|
| `Services/RichTextArchiver.swift` | Persistence format (RTF), legacy migration, font normalization, `PageTextStyle` fonts |
| `Services/RichTextSupport.swift` | `RichText` Transferable wrapper (Sendable, pre-encoded RTF + plain text) |
| `Views/TextKit/PageTextView.swift` | `NSTextView`/`UITextView` subclasses on an explicit TextKit 2 stack |
| `Views/TextKit/PageTextEditor.swift` | `NSViewRepresentable`/`UIViewRepresentable` hosting the editor |
| `Views/TextKit/PageTextController.swift` | `@Observable` editing controller (load/save/format/cleanup/find/statistics) + `TextStatistics` |
| `Views/TextKit/RichTextPreview.swift` | Read-only TextKit 2 view for large-document preview |

### The TextKit 2 Stack
The macOS editor constructs the stack explicitly; iOS uses `UITextView(usingTextLayoutManager: true)`, which assembles the same layers:

```
NSTextContentStorage   (storage layer — attributed string → NSTextParagraphs)
        │
NSTextLayoutManager    (layout layer — produces NSTextLayoutFragments)
        │
NSTextContainer        (geometry the viewport lays out into)
        │
PageTextView           (view layer — NSTextView / UITextView subclass)
```

Viewport-based layout means only the fragments intersecting the visible viewport are laid out and rendered, so huge documents stay responsive (this is what allowed removing the export preview's 50k character cap).

**⚠️ Never touch `layoutManager` (macOS) on these views** — reading the TextKit 1 property silently downgrades the view to the compatibility text engine.

**Future extension points** (per the "Elevate your app's text experience" session): the framework text views conform to `NSTextViewportLayoutControllerDelegate`, so `PageTextView` subclass overrides can add line numbers, collapsible ranges, or attachment view-provider reuse. Inline table support will use `NSTextTableBlock`, which flows through the RTF storage format with no schema change.

## Rich Text Storage Architecture

Page text is persisted as **RTF `Data` with `@Attribute(.externalStorage)`**, exposed via a computed `attributedText: NSAttributedString` property. RTF is `NSAttributedString`'s native document format: encode/decode is one framework call, and it round-trips fonts, B/I/U/S, paragraph styles, and (macOS) `NSTextTable`/`NSTextTableBlock`. It's still a plain `Data` blob, so CloudKit external storage (CKAsset) and the SwiftData schema are unchanged.

### Page Model (`Models.swift`)
```swift
@Model
final class Page {
    /// RTF data (current) or legacy JSON-encoded AttributedString (pre-2.0)
    @Attribute(.externalStorage)
    var richTextData: Data?

    var attributedText: NSAttributedString {
        get { RichTextArchiver.attributedString(from: richTextData) }
        set {
            richTextData = RichTextArchiver.rtfData(from: newValue)
            lastModified = Date()
        }
    }

    /// Plain text accessor for search/statistics
    var plainText: String {
        RichTextArchiver.plainText(from: richTextData)
    }
}
```

**Key points:**
- Stored property is still `richTextData: Data?` — same name/type as 1.x, so the SwiftData/CloudKit schema did not change. The **format** inside the blob changed, which is why `SchemaVersioning.currentVersion` is 2.
- `lastModified` updates in the `attributedText` setter, so it only fires on local writes — remote CloudKit sync writes directly to `richTextData` and won't bump the timestamp. `init` encodes directly into `richTextData` for the same reason.
- Callers snapshot `attributedText` once per page (`PageTextController` does this) rather than reading it repeatedly — decode happens on every get.

### RichTextArchiver (`Services/RichTextArchiver.swift`)
The single owner of the persistence format:
- `rtfData(from:)` — encode via `NSAttributedString.data(from:documentAttributes:)`
- `attributedString(from:)` — **format-sniffing decode**: RTF data always starts with `{\rtf`; anything else goes through the legacy JSON path
- `decodeLegacyJSON(_:)` — decodes pre-2.0 Codable `AttributedString` and maps old SwiftUI attributes (`inlinePresentationIntent`, SwiftUI `Font` bold/italic, underline/strikethrough) onto platform fonts/attributes
- `normalizedForStorage(_:)` / `normalizedForDisplay(_:)` — font normalization (below)

### Legacy Migration (pre-2.0 JSON → RTF)
Migration is **lazy**: reads accept both formats forever; every write produces RTF. No migration pass runs at startup. Because old app builds decode `richTextData` as JSON and would see empty text (and could overwrite it), the schema version gate (v2) blocks old builds from using new data — see Schema Versioning System.

### Font Normalization
Fonts are normalized at the pipeline boundaries so content is portable and each platform's editor feels native:
- **Storage/export font**: Helvetica Neue 13pt (`PageTextStyle.storageFont`) — resolvable by every word processor; system fonts would encode as private names (".SFNS") other apps can't resolve.
- **Display font**: platform body font (`PageTextStyle.displayFont`), applied when loading text into the editor.
- `RichTextArchiver.normalizing(_:to:)` swaps each run's font for the base font carrying that run's bold/italic traits, strips display-only colors (pasted content!), and passes every other attribute through untouched.

## Share Sheet / Transferable Architecture

`RichText` (`Services/RichTextSupport.swift`) conforms to `Transferable`. It is a **Sendable value**: RTF is encoded eagerly at init (`RichText(_: NSAttributedString)`) or supplied pre-encoded (`RichText(rtfData:plainText:)`), so the wrapper can cross actor boundaries and export from Transferable's async closures without touching a live `NSAttributedString`.

### Transfer Representations (Priority Order)
```swift
static var transferRepresentation: some TransferRepresentation {
    // 1. File-based RTF for Finder, Save to Files, Notes, etc.
    FileRepresentation(exportedContentType: .rtf) { ... }
        .suggestedFileName("Exported Text.rtf")

    // 2. Data-based RTF for clipboard operations (Copy)
    DataRepresentation(exportedContentType: .rtf) { ... }

    // 3. Plain text fallback - works everywhere
    ProxyRepresentation { $0.plainText }
}
```

### Why Multiple Representations?
- **FileRepresentation**: Required for apps like Notes, Finder, and "Save to Files" that expect file URLs. Without this, some apps show "empty URL" instead of content.
- **DataRepresentation**: Powers clipboard Copy operations.
- **ProxyRepresentation**: Universal fallback for apps that only accept plain text (e.g., Messages).

### Error Handling
```swift
enum RichTextExportError: LocalizedError {
    case rtfConversionFailed  // NSAttributedString → RTF failed
    case emptyContent         // Nothing to export
}
```
`rtfDataOrThrow()` throws at share time if encoding failed; the plain text fallback still works.

### ShareLink Usage Locations
- `ThumbnailSidebar.swift` — Context menu single-page export
- `ExportPanelView.swift` — "Export…"/share button for full document export (uses `TextExportResult.richText`)
- `MultiScanApp.swift` — File menu "Export Page Text…"

### App Compatibility
| App | Behavior |
|-----|----------|
| Notes | Receives RTF file, renders with formatting |
| TextEdit | Full RTF support |
| Pages | Imports RTF (may simplify formatting) |
| Messages | Plain text only (uses ProxyRepresentation) |
| Finder/Save to Files | Creates .rtf file |

## Rich Text Editing Architecture

The app uses an always-editable text model with debounced auto-save. The editor is a TextKit 2 `PageTextView` hosted by `PageTextEditor`, driven by a `PageTextController`.

### PageTextController (`Views/TextKit/PageTextController.swift`)
`@MainActor @Observable` controller, one per selected page (created on page switch by `RichTextSidebar`):
- `init(page:)` decodes the page text once and normalizes it to the display font
- `attach(_:)` loads content into the platform text view (called by the representable; the view instance is reused across page switches, only the controller changes)
- `textDidChange()` (from the view delegate) refreshes the authoritative snapshot + live `wordCount`/`charCount`, schedules the debounced save
- `detach()` saves and severs the view link — **a late debounce can never read another page's storage**
- Formatting (`toggleBold/Italic/Underline/Strikethrough`): empty selection flips `typingAttributes`; otherwise applies platform font traits over the selected range
- `saveNow()` normalizes to the storage font, writes `page.attributedText`, and syncs the export cache entry
- `presentFindNavigator()` — find bar (macOS `performTextFinderAction`) / find navigator (iOS `UIFindInteraction`); the Edit ▸ Find… command reaches it through the `showFindNavigator` focused binding
- Exposed to menu commands via `FocusedValues.pageTextController`

### Undo
Typing undo is **native** to NSTextView/UITextView on both platforms (`allowsUndo` on macOS; automatic on iOS including shake-to-undo and three-finger swipe). Programmatic edits (formatting, Remove Line Breaks, Smart Cleanup) register snapshot-based undo on the view's UndoManager via `performEdit(actionName:_:)`, so they join the same stack. Undo history is cleared when a page loads (`attach`). macOS gained full undo in 2.0 (it had none before).

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
| User switches pages | `onChange(of: currentPage)` → `detach()` |
| User navigates away | `onDisappear` → `detach()` |
| User opens export panel | `pageTextController?.saveNow()` before panel opens |
| User quits app (⌘Q) | `willTerminateNotification` + `modelContext.save()` |

All save calls check `hasUnsavedChanges` first — no-op if no edits were made.

### Persistence Flow (Simplified)
1. `saveNow()` normalizes the snapshot to the storage font (strips display colors) and assigns to `page.attributedText`
2. The setter RTF-encodes to `richTextData` and updates `lastModified`
3. SwiftData persists `richTextData` to external storage (and CKAsset, if iCloud sync is enabled)
4. `TextExportCacheService.updateEntry(pageNumber:attributedText:in:)` keeps the export cache in sync

### Important Notes
- No separate "view mode" vs "edit mode" — always editable
- **Colors are display-only, never stored.** Platform text views render runs *without* a `.foregroundColor` attribute in default black regardless of appearance (view-level `textColor` only covers text present when it's set, plus typing attributes). So every display path stamps the dynamic label color via `RichTextArchiver.applyingDisplayColor(_:)` — `normalizedForDisplay` does it for the editor, `RichTextPreview` does it for the export preview — and `normalizedForStorage` strips it on save
- Formatting toolbar always visible in header when page selected (macOS only — iOS uses the system-provided controls; see Multiplatform Architecture)
- `modelContext.save()` on app quit ensures synchronous disk write before termination (`NSApplication`/`UIApplication` `willTerminateNotification` per platform; iPhone also saves on `scenePhase == .background`)

## Full Document Text Cache

The `NavigationState` class maintains `fullDocumentPlainText: String` (for TTS/search/FocusedValues). It is built from the text export cache when valid (one external-storage read) and falls back to per-page decodes otherwise. The old `fullDocumentAttributedText` was removed — nothing consumed it.

### Cache Invalidation
The cache is rebuilt when:
- Document selection changes (via `setupNavigation(for:)`)
- Call `rebuildTextCache()` manually after page text edits

### Accessibility Integration
- `fullDocumentPlainText` available via `FocusedValues` for app-level access
- The TextKit 2 editor is a real NSTextView/UITextView, so system text accessibility (VoiceOver text navigation, macOS Edit ▸ Speech, dictation, Voice Control) works natively
- **Dynamic Type (iOS)**: attributed strings carry explicit fonts, so they don't rescale automatically. `PageTextView` registers for `UITraitPreferredContentSizeCategory` changes and `PageTextController.dynamicTypeDidChange()` re-normalizes the live content to the new body size (display-only — storage strips sizes, so this never dirties the document)
- **⚠️ Pending on-device verification**: the SwiftUI accessibility custom actions on `PageTextEditor` ("Exit text editor", next/previous page) haven't been VoiceOver-tested since the TextKit 2 migration — actions attached to a representable may not surface on the wrapped text view's accessibility element. Fallback if missing: `accessibilityCustomActions` on `PageTextView`

### Future: Search Implementation
To implement document search:
1. Use `fullDocumentPlainText` (or per-entry `plainText` in the export cache) for queries
2. Map character positions back to page numbers for navigation
3. In-page find is already native: `PageTextController.presentFindNavigator()`
4. Consider adding a search index for large documents (100+ pages)

## Image Display & Transformation Architecture

Images are stored as `Data` with `@Attribute(.externalStorage)` in the Page model. All transformations are **non-destructive** - stored as Page properties and applied at display time.

### Page Image Properties
```swift
var rotation: Int = 0              // Degrees: 0, 90, 180, 270
var increaseContrast: Bool = false // CIColorControls contrast 1.3 (viewer) / .contrast(1.3) (thumbnails)
var increaseBlackPoint: Bool = false // CIColorControls brightness -0.1 (viewer) / .brightness(-0.1) (thumbnails)
```

### PlatformImage Helper (`Services/PlatformImage.swift`)
Cross-platform image loading that combines EXIF orientation with user rotation:
- `from(data:userRotation:)` - Creates SwiftUI Image with combined orientation (thumbnails)
- `processedCGImage(from:userRotation:increaseContrast:increaseBlackPoint:)` - CGImage with rotation + adjustments baked in via CIFilter (main viewer)
- `dimensions(of:userRotation:)` - Returns apparent dimensions accounting for rotation
- `combinedOrientation(exif:userRotation:)` - Lookup table merging EXIF + user rotation

### Main Viewer Pipeline (`ImageViewer` → `ZoomableImageView`)
1. `ImageViewer` builds an `ImageRequest` (page persistentModelID + rotation + adjustments) from `navigationState.currentPage`; `.task(id: imageRequest)` decodes off the main actor via `PlatformImage.processedCGImage` and auto-cancels stale loads
2. The result is a `ProcessedPageImage` (CGImage + `ContentID`). The `ContentID` (pageID + rotation) tells the platform view when to reset zoom: page switch/rotation → re-fit; contrast/black point tweak → swap pixels in place, zoom and scroll preserved
3. Thumbnails (`ThumbnailSidebar`, `SlideGridView`) still use `PlatformImage.from` + SwiftUI `.contrast()`/`.brightness()` modifiers

## Zoomable Image Viewer (`Views/ZoomableImageView.swift`)

Platform-native zoom/pan built on scroll-view **subclasses** (`MacZoomableScrollView: NSScrollView`, `IOSZoomableScrollView: UIScrollView`), hosted by thin representables. Design rules:

- **All fit-to-window logic runs synchronously in the platform layout pass** (`setFrameSize`/`layout` on macOS, `layoutSubviews` on iOS). Sidebar/inspector/window resizes re-fit frame-by-frame during the animation — no NotificationCenter frame observers, no async races. The fit invariant: at fit → stay at fit through resizes; zoomed in → preserve absolute zoom, re-clamp to new limits. Nothing ever touches magnification mid-gesture (gestures don't change the viewport).
- **Zoom commands flow through `ImageZoomController`** (`@Observable`, one per `ImageViewer`): the scroll view registers as its `ImageZoomTarget`; on-screen buttons and accessibility actions call it directly; menu bar/⌘+/⌘−/⌘0 reach it via `FocusedValues.imageZoomController` (scene-scoped, so multiple windows don't cross-zoom). The old global zoom notifications are gone.
- **Zoom level reporting** goes controller-ward (`reportZoomLevel`, relative to fit, 1.0 = fit) — never through a SwiftUI `Binding`, which previously re-entered `updateNSView` and caused zoom resets.
- **Bounce/elasticity**: iOS `bouncesZoom` + `alwaysBounceVertical/Horizontal`; macOS scroll elasticity `.allowed`, `usesPredominantAxisScrolling = false` (free 2D pan), native pinch rubber-banding (no mid-gesture clamps).
- **Conventions**: double-tap (iOS) / double-click (macOS) toggles fit ↔ 2.5× fit at the pointer; ⌘+scroll wheel zooms at the cursor (macOS); smart magnify is native NSScrollView behavior. `maximumZoomScale = max(fit × 10, 1.0)`.
- **Safe-area insets** from SwiftUI (`GeometryReader` + `.ignoresSafeArea()`) are applied as content insets so the image renders behind the glass toolbar panels but fits/centers within the visible area. macOS `CenteringClipView` converts point-space insets into document space (divide by magnification) before centering — don't "simplify" that division away.
- **HDR is fully system-managed**: `PlatformImage.processedCGImage` decodes with `kCGImageSourceDecodeToHDR` (gain-map iPhone photos would otherwise decode SDR-only; the CI adjustment path renders `.RGBAh` into the source color space when the decode came back >8 bits per component to keep the headroom). Display is toggled purely via `preferredImageDynamicRange` (`.high` ↔ `.standard`, the system does the tone mapping) on the platform image views — `@AppStorage("viewerShowsHDR")`, Image ▸ Show HDR. Toggling never re-decodes. No custom HDR pipeline — keep it that way.

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
| Show HDR | (toggle, app-wide viewer preference — not a page edit; macOS + iPadOS menu bar only, iPhone always uses the stored value, default ON) |

### Edit Menu (page operations)
| Command | Shortcut |
|---------|----------|
| Move Page Up | ⌘⌥↑ |
| Move Page Down | ⌘⌥↓ |
| Delete Page… | (none) |

### FocusedValues for Menu Bar
- `currentPage: Page?` - Exposed from ReviewView for menu commands
- `pageTextController: PageTextController?` - Exposed from RichTextSidebar; Format menu (B/I/U/S) and save-before-export go through it
- Menu commands use `focusedNavigationState` for move/delete operations

## Text Export Architecture

The export system combines all page text into a single document with configurable separators.

### Performance: Text Export Cache

**Problem**: SwiftData's `@Attribute(.externalStorage)` stores each page's text in a separate external file. Loading N pages for export means N sequential disk reads on the main thread, freezing the UI for large documents (500+ pages can take minutes).

**Solution**: A pre-computed cache stores all pages' text data in a single file. Export loads one file instead of N.

### TextExportCacheService (`Services/TextExportCacheService.swift`)

Manages a cached copy of all page text data on the Document model.

#### Cache Structure (version 2)
```swift
// Stored on Document.textExportCache as binary-plist-encoded Data
struct TextExportCache: Codable, Sendable {
    var version: Int  // currentVersion = 2
    var pages: [PageCacheEntry]
}

struct PageCacheEntry: Codable, Sendable {
    let pageNumber: Int
    let fileName: String?
    let rtfData: Data     // Same RTF format as Page.richTextData — for export
    let plainText: String // Pre-extracted — Smart Cleanup analyzes this, no decoding
    let wordCount: Int    // Pre-computed for separator metadata
    let charCount: Int
}
```

Each entry stores the text **twice on purpose**: export needs formatting (`rtfData`), Smart Cleanup analysis needs only plain text (`plainText`) — so analysis never decodes an attributed string at all. Version 1 caches (JSON AttributedString entries) fail plist decoding → `decodeCache` returns nil → rebuilt from source pages once.

#### Sync Points
The cache is updated whenever page data changes:

| Event | Cache Action | Location |
|-------|--------------|----------|
| Document created (after OCR) | `buildInitialCache()` | `HomeView.updateDocument()` |
| Page text saved | `updateEntry()` | `PageTextController.saveNow()` |
| Page added to document | `addEntries()` | `ReviewView.addPagesToDocument()` |
| Page deleted | `removeEntry()` | `NavigationState.deleteCurrentPage()`, `ThumbnailSidebar.deletePage()` |
| Page reordered | `swapPageNumbers()` | `NavigationState.moveCurrentPageUp/Down()`, `ThumbnailSidebar.movePageUp/Down()` |

#### Key Methods
```swift
// Build initial cache (call after OCR while data is in memory)
static func buildInitialCache(for document: Document, from pages: [Page])

// Update single page entry (call after page text edit)
static func updateEntry(pageNumber: Int, attributedText: NSAttributedString, in document: Document)

// Add new page entries (call after adding pages to existing document)
static func addEntries(for pages: [Page], to document: Document)

// Remove page entry (call after page deletion)
static func removeEntry(pageNumber: Int, from document: Document)

// Swap page numbers (call after page reorder)
static func swapPageNumbers(_ pageNumber1: Int, _ pageNumber2: Int, in document: Document)

// Load cache for export
static func loadCache(from document: Document) -> TextExportCache?
```

Renumbering operations (`insertEntries`, `removeEntry`, `swapPageNumbers`) use `PageCacheEntry.renumbered(to:)`, which copies raw fields — no decode/encode. `PageCacheEntry.decodedText()` decodes an entry's RTF for removal operations.

#### Cache Resilience
- **Version checking**: Cache includes version number; mismatches (including v1 caches) trigger automatic rebuild
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
Builds a combined `NSAttributedString` from all pages, returning a `TextExportResult` (`attributedText` for preview + pre-encoded `rtfData`/`plainText` for sharing, exposed as `.richText`). Supports two modes:

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
   → Sendable PageSnapshots (raw RTF bytes + pre-computed stats)

2. Build on background thread (Task.detached)
   → Decode each page's RTF, append into NSMutableAttributedString — O(n),
     the old SwiftUI AttributedString.append() O(n²) issue is gone
   → RTF-encode the combined result there too

3. Return TextExportResult to main actor for display/sharing
```

In the fallback mode only the raw `richTextData` bytes are read on the main actor; decoding still happens on the background thread (and handles legacy-format pages via `RichTextArchiver`).

### Performance Comparison

| Document Size | Without Cache | With Cache |
|---------------|---------------|------------|
| Small (< 50 pages) | Instant | Instant |
| Medium (50-200 pages) | 2-5 seconds | < 1 second |
| Large (500+ pages) | 2-5 minutes (UI freeze) | 1-3 seconds |

### ExportPanelView (`Views/ExportPanelView.swift`)
Print-panel-style sheet with live preview:
- Accepts `Document` (not pages array) to enable cache-based export
- Preview pane: **`RichTextPreview`** — a read-only TextKit 2 view. Viewport-based layout means the **full document displays without truncation** (the old 50,000-character SwiftUI Text cap is gone)
- Options pane: visual separation toggle, separator style, mods
- Shows spinner during async export
- Debounces setting changes by 300ms
- ShareLink uses the pre-encoded `TextExportResult.richText` (no re-encoding at share time)

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

Smart Cleanup analyzes all pages via the `TextExportCache` (single file read, no N disk loads). Analysis operates purely on the cache entries' pre-extracted `plainText` — no attributed string is ever decoded during analysis. It detects three types of artifacts:

1. **Page numbers (first/last line)**: Numerals at the first or last non-empty line of each page. Matches standalone numbers (`42`), `Page X`, `p. X`, `- X -` patterns, and comma-formatted numbers (`1,234`). Also detects page numbers embedded in mixed lines (e.g., `"Chapter 1    42"`) via `decomposeHeaderLine()`. Numbers must be ≤ 5 characters (digits + commas). No adjacent-page verification required.
2. **Section headers**: Any non-empty line (anywhere in the page text) that repeats across 2+ near-contiguous pages. Lines must be at least 3 characters after normalization to avoid false positives on short OCR artifacts. Strips trailing/leading page numbers before comparing. Allows gaps of up to 5 pages between occurrences. Uses **OCR-aware fuzzy matching**: applies `ocrNormalize()` (maps `1`→`l`, `0`→`o`) then merges groups within Levenshtein edit distance ≤ 2 (≤ 1 for strings < 5 chars). Displays the most common text variant in the UI, so OCR errors like "Rile in the Rain" merge with "Rite in the Rain" and the correct spelling is shown. Removal also uses fuzzy matching so the correct line is found regardless of per-page OCR variation. Full-text scanning enables detection of headers from two-page book spreads scanned as a single image, where headers appear in the middle of the OCR text.
3. **Consecutive numbers (anywhere in text)**: Numbers found anywhere in the interior text (not first/last line) that form consecutive integer series across adjacent project pages. Requires cross-page adjacency verification: each number must have at least one adjacent project page (±1) with a number from the same consecutive run.

All matching uses **normalized comparison** (case-insensitive, whitespace-collapsed, OCR-variant dashes/quotes normalized). Number parsing uses `parseNumericToken()` which handles digits and thousands-separator commas with a 5-character limit.

### Key Files
- `Services/TextManipulationService.swift`: Analysis algorithms, data types, removal logic
- `Views/RichTextSidebar.swift`: Smart Cleanup pane UI, state management, cleanup execution (`applyEdit(toPage:)` / `applyBatchEdit(toPages:)` for non-current pages)
- `Views/TextKit/PageTextController.swift`: Current-page removal with undo (`removePageNumberTokens`, `removeLine`)

### Data Types (in `TextManipulationService`)
- **`PageNumberDetection`**: Detected page number with page, detected numeral, `numberText` (exact text for token removal), line text, position (first/last line)
- **`SectionHeaderDetection`**: Detected header with normalized text, display text, page range, and `affectedPages` (actual pages with the header — may be a subset of the range for alternating headers)
- **`ConsecutiveNumberGroup`**: Group of consecutive integers found across adjacent pages, with `pageMapping` (project page → number texts), sorted `numbers`, and `pageRange`
- **`LineComponents`**: Result of `decomposeHeaderLine()` — splits a line into core text and optional trailing/leading page number
- **`SmartCleanupResult`**: All detections from a document analysis (page numbers, section headers, consecutive numbers)
- **`CleanupOption`**: Actionable cleanup options (per-page, per-range, or document-wide removal)

### Analysis Pipeline
```
TextExportCache → analyzeForSmartCleanup() → SmartCleanupResult
SmartCleanupResult + currentPageNumber → buildOptions() → [CleanupOption]
```

### UI Location
Bottom of `RichTextSidebar` inspector, below the Statistics pane (macOS + iPad). Toggled via:
- `@AppStorage("showSmartCleanup")` (default: OFF)
- View menu: "Show Smart Cleanup" (⌘⇧K)

On iPhone, the sidebar's panes are hidden (`hideBottomPanels`); Smart Cleanup instead lives in CompactReviewView's "More" menu and is always active there.

### UI States
| State | Menu Appearance |
|-------|-----------------|
| Analyzing (3s linger + analysis) | `ProgressView` + "Checking..." (disabled) |
| No suggestions | "No suggestions" (disabled) |
| Suggestions available | "\(count) suggestions" with chevron (enabled dropdown) |

### Cleanup Options (per current page)
1. "Remove page number (42) from this page" — single page, first/last line
2. "Remove "Chapter 1" from this page" — single page, section header
3. "Remove "Chapter 1" from pages 50–65" — range, section header
4. "Remove 349, 350 from this page" — single page, consecutive numbers
5. "Remove consecutive page numbers from pages 5–7" — range, consecutive numbers
6. "Remove detected page numbers from the entire document" — all pages (includes both first/last line AND consecutive)

Note: Document-wide section header removal was removed (too many false positives). Only per-page and per-range options are offered for section headers.

### Timing
- Analysis runs after user lingers on a page for **3 seconds** (debounces rapid page flips)
- Only runs when the Smart Cleanup pane is visible (macOS/iPad); always runs on iPhone (More menu)
- After a cleanup action, re-analyzes immediately (no 3s delay)
- Analysis runs **off the MainActor**: the raw cache `Data` is handed to a detached task, decoded via the nonisolated `TextExportCacheService.decodeCache(from:)`, and only the resulting options are applied back on the main actor

### Removal Behavior

**Page numbers** (first/last line and consecutive): Token-level removal via `removePageNumberToken()`.
- Removes only the number text (≤ 5 chars) + adjacent whitespace, NOT the entire line
- Prefers removing preceding whitespace; falls back to following whitespace
- If the remaining line content is empty, collapses the entire line (including newline)
- Example: `"Chapter 1    42"` → removes `"    42"` → leaves `"Chapter 1"`
- Example: standalone `"42"` → line empty → collapses line

**Section headers**: Full line removal via `removeLine()`.
- Removes the entire line containing the header text (including newline)
- Supports `stripNumbers: true` for matching mixed header+number lines

Both compute a removal range on plain text (`removalRange(forPageNumberToken:in:)` / `lineRemovalRange(matching:in:stripNumbers:)`) and delete it from an `NSMutableAttributedString` — formatting on surrounding text is preserved automatically. In-place (`removePageNumberToken(_:in:)`) and non-mutating (`removingPageNumberToken(_:from:)`) variants exist for each.

- **Current page**: Goes through `PageTextController.performEdit` — applied in the live editor **with undo**, then saved
- **Other single page**: `RichTextSidebar.applyEdit(toPage:)` decodes the cache entry (no page external-storage load), writes page + cache entry
- **Batch (range/document-wide)**: `applyBatchEdit(toPages:)` loads the cache once, modifies all entries in memory, writes each page's `attributedText`, saves the cache once
- After batch modification of the current page, re-initializes `PageTextController` to refresh the editor

### Number Parsing (`parseNumericToken`)
Handles digits and thousands-separator commas with a 5-character limit:
- `"42"` → 42, `"1,234"` → 1234, `"9,999"` → 9999
- Rejects: `"100000"` (6 chars), `"1,23,4"` (invalid commas), `"abc"` (non-numeric)
- Used by `extractPageNumber()`, `decomposeHeaderLine()`, and `extractStandaloneNumbers()`

### Consecutive Number Detection (`detectConsecutiveNumbers`)
Finds physical page numbers embedded anywhere in OCR text by detecting cross-page consecutive series:
1. `extractStandaloneNumbers()` scans each page's interior text (excluding first/last non-empty lines) for standalone numeric tokens ≤ 5 chars
2. Builds value-to-pages mapping across all pages
3. Finds maximal consecutive integer runs
4. Verifies cross-page adjacency: each (value, page) pair must have at least one adjacent project page (±1) with a number from the same run
5. Groups surviving pairs into `ConsecutiveNumberGroup` objects

Per-page options are deduplicated against first/last line detections to avoid duplicate suggestions.

### Mixed Header+Number Lines (`decomposeHeaderLine`)
Handles lines like `"Chapter 1    42"` that combine a section header with a page number:
- Splits normalized text by spaces, checks if first/last token is numeric via `parseNumericToken()`
- Returns `LineComponents(coreText:, pageNumber:, fullNormalized:)`
- Only strips edge numbers — `"chapter 1 of 3 42"` → core: `"chapter 1 of 3"`, number: `42`
- Used by both page number detection (to find embedded numbers) and section header detection (to group lines ignoring varying page numbers)

### Alternating Left/Right Page Headers
Books commonly alternate headers: left pages show the chapter number, right pages show the chapter title. Detection uses a gap tolerance of 5 pages when finding contiguous runs, so headers appearing on every other page, or even with a few missing pages, still form detectable sections. `SectionHeaderDetection.affectedPages` stores only the pages that actually have the header (not every page in the range), preventing false modifications during batch removal.
