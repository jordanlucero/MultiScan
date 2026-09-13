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

1. **MultiScanApp.swift**: Entry point — the `FocusedValues` entries, the scene tree (main window, macOS Settings window), and the post-load maintenance hook. Deliberately small; the menu bar lives in **MultiScanCommands.swift** (`struct MultiScanCommands: Commands`) and the settings panes in **Views/SettingsView.swift**
2. **HomeView.swift**: Document list with creation/import functionality
3. **ReviewView.swift**: Main document editing UI with NavigationSplitView (macOS + iPad regular size class)
4. **CompactReviewView.swift**: iPhone document editing UI (iOS-only file)
5. **Models.swift**: SwiftData models (`Document`, `Page`)
6. **Views/TextKit/**: The TextKit 2 text engine — platform text views, SwiftUI representables, and the page editing controller (see "TextKit 2 Text Engine")
7. **AppIntents/**: App Intents entities, queries, intents, and App Shortcuts (see "App Intents & Spotlight")
8. **Services/AppModelContainer.swift / ProjectStore.swift / SpotlightIndexer.swift / AppRouter.swift / ProjectImportPipeline.swift**: process-wide container (+ post-load maintenance), read-side model actor, Spotlight reconciler, deep-link router, shared import→OCR pipeline
9. **Services/ExportSettings.swift / NavigationSettings.swift**: `@Observable` UserDefaults-backed preference objects

### Data Models
- **Document**: Container for pages with metadata (name, emoji, storage size). Uses optional `pages` relationship with `unwrappedPages` accessor for CloudKit compatibility.
- **Page**: Individual page with image, rich text, thumbnails, and display settings. All properties have default values for CloudKit sync.
- **2.x additive fields** (no schema-version bump): `Document.uuid`, `Document.lastModified`, `Page.uuid`, `Page.plainText` (stored mirror of the RTF, replaces the old computed decode), `Page.plainTextUpdatedAt`. See "Storage additions (2.x)".

### Data Flow
- SwiftData `@Model` classes for persistence
- `@Query` property wrapper for reactive data fetching
- `modelContext` from environment for CRUD operations
- `NavigationState` (`@Observable`, one per review view) for page navigation state; `AppRouter` (`@Observable`, one per process) for app-level navigation requests (deep links, search)
- **All observation is `@Observable`** — there is no `ObservableObject`/`@Published`/`@ObservedObject`/`@StateObject` anywhere in the project, and none should be reintroduced. Owners use `@State`, consumers take a plain `let`, and two-way access uses `@Bindable`/`Bindable(_:)`.
- `NavigationSettings.shared` is a **single** app-wide instance (the initializer is private). It caches its values in stored properties and only writes through to UserDefaults, so separate instances would silently diverge until relaunch — `NavigationState` and the Settings UI both use `.shared`.
- **`NavigationState.currentPageNumber` is the only copy of the current page.** The thumbnail sidebar, page grid, rotors, and deep links all read it / call `goToPage`; there is no mirrored `selectedPageNumber` `@State` in the review views (there used to be, kept in sync by `onChange` handlers in both directions). Likewise `ReviewView`'s split-view `columnVisibility` is a `Binding` derived from `@AppStorage("showThumbnails")`, not a second piece of state.
- `ContentView` gives the review view `.id(document.persistentModelID)`, so a deep link that switches straight from one open project to another gets fresh `@State` (navigation, controllers) for the new document.
- **`FocusedValues` entries use `@Entry`** (`MultiScanApp.swift`) — the macro synthesizes the key type and accessors. Don't reintroduce hand-written `FocusedValueKey` conformances. Every entry must be `Optional` with no initializer, since a focused value always defaults to `nil`.

## Development Commands

## Xcode Integration

- This is an SwiftUI project with a minimum deployment target of macOS 27 and iOS/iPadOS 27
- Use the Xcode MCP tools for building (`BuildProject`), testing (`RunAllTests`), and previewing (`RenderPreview`)
- Prefer `ExecuteSnippet` to verify unfamiliar Apple APIs before writing implementation code
- Run `DocumentationSearch` before suggesting deprecated APIs


### Build and Run directly when needed
```bash
# Open in Xcode
open MultiScan.xcodeproj

# Build from command line
xcodebuild -scheme MultiScan -configuration Debug build

# Run from command line
xcodebuild -scheme MultiScan -configuration Debug -destination 'platform=macOS' build
```

### Clean directly when needed
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
| Settings | Custom Settings `Window` scene (workaround) | `SettingsSheetView` sheet from the Home gear button → Import & Storage / Viewer panes. All in `Views/SettingsView.swift`; the two panes are shared across platforms |

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
- `aps-environment`: `development` — **iOS/iPadOS** push entitlement
- `com.apple.developer.aps-environment`: `development` — **macOS** push entitlement

Both push keys are present on purpose. They are different entitlements, not aliases, and one shared entitlements file serves all three platforms; each platform's signing step keeps its own key and drops the other (verified against `codesign -d --entitlements`). CloudKit's mirroring relies on silent pushes to a `CKDatabaseSubscription`, so dropping the iOS key downgrades iPhone/iPad to pull-on-launch sync. `Info.plist` carries the matching `UIBackgroundModes: remote-notification`.

**⚠️ The `AddEntitlement` MCP tool silently no-ops on `aps-environment`** — it treats the existing `com.apple.developer.aps-environment` as the same key and reports success without writing. Edit the file directly and verify with `codesign -d --entitlements - --xml <built app>`. A macOS build is not a valid check for the iOS key; build for `Any iOS Device (arm64)` (simulator builds carry no entitlements at all).

### Development Schema Initialization
CloudKit needs the data schema in its development environment before sync works, and initializing it also *validates* the model for CloudKit compatibility. SwiftData has no API for this, so `AppModelContainer.initializeCloudKitSchemaIfRequested(configuration:)` drops to Core Data per Apple's "Syncing model data across a person's devices": load the same store file through `NSPersistentCloudKitContainer` synchronously, call `initializeCloudKitSchema()`, then remove the store before SwiftData opens it (otherwise both frameworks sync the same store).

**It is opt-in**, gated on `#if DEBUG` + iCloud sync enabled + the `-initializeCloudKitSchema` launch argument. It uploads a representative record for every type and field then deletes them — slow, and it blocks other CloudKit operations, so Apple's guidance is not to run it on ordinary launches. Run it after changing the model, not habitually.

**First run setup:**
1. Enable iCloud sync in Settings > Import and Storage, relaunch
2. Run once with `-initializeCloudKitSchema` in the scheme's arguments
3. Verify in CloudKit Console that `CD_Document` and `CD_Page` record types exist

**Production deployment:**
1. In CloudKit Console, promote schema from Development to Production
2. This only needs to be done once before release
3. Schema changes require re-promotion

### Field Encryption
`Page.plainText` is `@Attribute(.allowsCloudEncryption)`. It is the *only* field that needs it: every other text/image blob (`richTextData`, `imageData`, `textExportCache`) is `@Attribute(.externalStorage)`, which mirrors to a `CKAsset`, and **CloudKit encrypts assets automatically** — `encryptedValues` explicitly rejects `CKAsset` for that reason. `plainText` is the one readable plaintext copy of a page's OCR output in a CloudKit field.

Rules that constrain any future change here:
- **CloudKit only accepts encryption on fields new to the schema.** Existing fields (`Document.name`, `Page.thumbnailData`, `Page.originalFileName`, `boundingBoxesData`) can never be converted — that ship sailed when the 1.x schema was promoted. `plainText` was encryptable only because 2.x hadn't been promoted yet.
- **No `#Index` on an encrypted field** — CloudKit rejects indexes it can't read. Encryption is CloudKit-side only, so the local SQLite column is untouched and `#Predicate` search still works.
- If a development-environment schema already has a plain `CD_plainText` from an earlier 2.x build, reset the development environment before re-initializing.

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
- Toggle shows a confirmation alert; on macOS confirming quits the app (`NSApp.terminate`), on iOS the alert asks the user to relaunch

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

**⚠️ The UserDefaults gate must never be lowered.** `SchemaValidationService.recordSuccessfulLoad()` raises the stored version only, and `AppModelContainer` skips calling it entirely when the pre-load check returned `.newerThanApp`. Writing `currentVersion` unconditionally (the original behaviour) overwrote a stored `3` with a `2`, so the "Update Required" screen appeared exactly once and the next launch read "compatible" and let the older build write over newer data — defeating the one gate that's supposed to survive database corruption.

**Key Files:**
- `Services/SchemaVersioning.swift`: Version constants, `SchemaMetadata` model
- `Services/SchemaValidationService.swift`: Pre/post-load validation, integrity checks, self-healing
- `Views/SchemaRecoveryView.swift`: Recovery UI for failures/incompatibilities

### Container Load Flow (`AppModelContainer.swift`, driven from `MultiScanApp.swift`)

```
1. Pre-load check (UserDefaults)
   ├─ newerThanApp? → Show "Update Required" UI
   └─ compatible → Continue

2. Create ModelContainer
   ├─ Success → Continue
   └─ Failure → Show Recovery UI (don't crash!)

3. Post-load validation (AppModelContainer.performPostLoadMaintenance, from the root view's .task)
   ├─ Check SchemaMetadata for CloudKit sync from newer version
   ├─ Run integrity validation (totalPages, pageNumbers, orphans)
   ├─ Self-heal minor issues automatically
   ├─ ProjectMaintenance.backfillIdentityAndPlainText (assign missing uuids, refresh stale plainText)
   └─ SpotlightIndexer.scheduleReconcile (bring the Spotlight index up to date)
```

The container itself lives in `AppModelContainer.shared` (`@MainActor` static) so App Intents, entity
queries, and the indexer reach it outside the SwiftUI environment; `MultiScanApp.init()` forces its
creation first, then registers `AppRouter.shared` / `ProjectStore.shared` with `AppDependencyManager`.

### Integrity Validation & Self-Healing

Minor issues are auto-fixed without user intervention:

| Issue | Detection | Auto-Fix |
|-------|-----------|----------|
| `totalPages` mismatch | `document.totalPages != pages.count` | Recalculate from actual count |
| Page number gaps | Pages not numbered 1,2,3... | Renumber sequentially |
| Orphan pages | `page.document == nil` | Quarantine; delete only after 24 h still orphaned |

Critical issues require user action:
- Data from newer schema version → "Update Required" prompt

**`IntegrityIssue` carries a `PersistentIdentifier`, not a name.** Self-healing resolves the document with `context.model(for:)`. Project names are not unique — two devices both creating "Untitled" is routine with sync on — and the old name lookup (`fetchLimit = 1`) could apply one document's `totalPages` rewrite or full renumber to a different, healthy document sharing its name. Never reintroduce a name-based lookup here.

**⚠️ Orphan pages are quarantined, never deleted on sight** (`deleteQuarantinedOrphanPages`). CloudKit mirrors `Page` and `Document` as separate record types and "the iCloud servers don't guarantee atomic processing of relationship changes" — a page whose record arrives before its document's, or before the link is applied, is indistinguishable from a real orphan at launch. Deleting it there is unrecoverable *and* propagates to every device. Instead, each orphan's uuid and first-seen date go in UserDefaults (`multiScanOrphanPageQuarantine`); it's deleted only once it has stayed orphaned past `orphanQuarantineWindow` (24 h, or 0 when sync is off — no out-of-order delivery to wait for). Entries for reattached pages are pruned each pass, so intermittent orphaning never accumulates toward the deadline. Orphans without a uuid get one assigned here, since the uuid backfill runs *after* this pass.

### Version History

| Version | App Version | Changes |
|---------|-------------|---------|
| 1 | 1.5.1+ | Initial tracked version. Document, Page, SchemaMetadata models. |
| 2 | 2.0 | `Page.richTextData` **format** changed from JSON-encoded `AttributedString` to RTF (TextKit 2 engine). Property name/type unchanged, so the SwiftData/CloudKit schema is identical — but v1 apps decode the blob as JSON and would see (and could save back) empty text, so they must be gated. Migration is lazy: reads accept both formats, writes produce RTF. `SchemaMetadata.recordSuccessfulLoad()` raises the stored version so other devices' gates fire via CloudKit. Additive fields — `Document.uuid`, `Document.lastModified`, `Page.uuid`, `Page.plainText`, `Page.plainTextUpdatedAt` — with lazy backfill at launch. CloudKit production schema must be re-promoted once for the new fields.  |  | |

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
- **Open App Store** (incompatible data only): the way out is updating the app
- **Reset All Data**: Delete database and start fresh (with confirmation); the user relaunches afterwards
- **Report Issue**: Link to GitHub issues

There is no "Try Again": the container is a `static let` created once per process, so an in-process retry can't do anything.

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

Every save also updates `Page.plainText`/`plainTextUpdatedAt` and `Document.lastModified` (via the `attributedText` setter) and, through `ModelContext.didSave`, schedules a Spotlight reconcile.

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

## Storage additions (2.x, additive)

| Field | Purpose |
|-------|---------|
| `Document.uuid: UUID?`, `Page.uuid: UUID?` | Stable, device-independent identity for App Intents entities, Spotlight, and deep links. **This is a public contract** — saved shortcuts and the Spotlight manifest store it, so its serialized form must not change. **Optional on purpose**: a non-optional `UUID()` default can stamp the same value on every existing row during lightweight migration. Backfilled by `ProjectMaintenance.backfillIdentityAndPlainText` (main context) after schema self-healing. `#Index` on both. |
| `Page.plainText: String` | Stored mirror of the RTF, set by the `attributedText` setter and `init`. Replaces the old computed property (which decoded RTF on every call), so the per-document page filters, `#Predicate` full-text search (`localizedStandardContains`), and Spotlight `textContent` never touch external storage. **`@Attribute(.allowsCloudEncryption)`** — see "Field Encryption". Never add `#Index` to it. |
| `Page.plainTextUpdatedAt: Date?` | Staleness guard: if `nil` or older than `lastModified` (a build without the column wrote the RTF), the backfill re-derives `plainText` — from the export cache when it matches, otherwise one RTF decode. |
| `Document.lastModified: Date?` | Bumped on rename/emoji (`DocumentCard`) and by every page text write (`Page.attributedText` setter). `lastModifiedDate` is the max of this, page dates, and `createdAt`. |

Backfill runs per document, decoding `textExportCache` once (no per-page external reads), saving per document with `Task.yield()` between. Two 2.x devices may assign different UUIDs to the same pre-existing row when iCloud sync is on; CloudKit converges (last writer wins) and the Spotlight reconcile self-heals.

## App Intents & Spotlight

Everything lives in `MultiScan/AppIntents/` plus the services listed below. There is no App Intents extension. Intents that touch `AppRouter`, the main `ModelContext`, or the `@MainActor` import pipeline declare `allowedExecutionTargets = .main`; `GetProjectTextIntent` only reads through `ProjectStore`, so it deliberately leaves the default (`.default`) — don't "fix" that asymmetry.

Where an intent runs is declared with `supportedModes` (`IntentModes`). The boolean `openAppWhenRun` is **deprecated** — don't reintroduce it.

### Entities (`AppIntents/Entities/`)
- **`ProjectEntity`** (`IndexedEntity, Transferable`): `id` = `Document.uuid`; `@Property`s with Spotlight `indexingKey`s (`name → displayName`, `createdAt`, `lastModified`, `summary → contentDescription`); 200 px JPEG cover for the display representation; `attributeSet` adds keywords + `domainIdentifier = "project.<uuid>"`. Transferable exports RTF file / RTF data / UTF-8 text, fetched lazily via `ProjectStore.projectText` (the entity carries only metadata).
- **`PageEntity`** (same conformances): `id` = `Page.uuid`; `text → textContent` (from the stored column), 128 px thumbnail; Transferable exports RTF, plain text, and a JPEG of the page (rotation/adjustments applied via `PlatformImage.processedCGImage`).
- **`SyncableEntity` is declarative only.** It adds no requirements beyond `AppEntity`; its real purpose is to pair the entity with a `SyncableEntityIdentifier<LocalID, StableID>`. Both entities keep a bare `UUID` id on purpose — the uuids are CloudKit-synced so they're already stable across devices, and adopting the paired identifier would change the id's serialized form and break saved shortcuts + the Spotlight manifest. The conformance is kept to **document** that these ids cross devices. Don't "complete" it by switching to `SyncableEntityIdentifier`.
- **Queries** (`EntityQueries.swift`): `EntityQuery + EntityStringQuery + IndexedEntityQuery + EntityPropertyQuery` for both; `@Dependency var store: ProjectStore`. Reindex callbacks route to `SpotlightIndexer.reindex(...)` / `reindexAll()`.
  - `entities(for:)` is a **batch** resolve — `ProjectStore.projectEntities(uuids:)` / `pageEntities(uuids:)` issue one fetch for all identifiers. Never reintroduce a per-id loop.
  - `EntityPropertyQuery` powers the Shortcuts **Find Projects/Pages where…** action. The framework only *parses* the filter into `ProjectQueryFilter` / `PageQueryFilter`; `ProjectStore` executes it, honoring `mode`, `sortedBy`, and `limit`. A full-text page term is pushed down into the `FetchDescriptor` (the unbounded case); the rest are field checks in memory. `EnumerableEntityQuery` is deliberately **not** used — it would materialize every page.
  - `properties` / `sortingOptions` must be `nonisolated(unsafe) static let … = QueryProperties { … }`. The metadata extractor requires that literal declaration shape (a computed getter fails extraction), and the builder types aren't `Sendable`.
- Entities are Sendable value snapshots built inside `ProjectStore` (a `@ModelActor`); `@Model` objects never leave it.

### Errors
Every error type that can escape into an intent — `CreateProjectIntent.CreateProjectError`, `ProjectStoreError`, `RichTextExportError` — conforms to **`CustomLocalizedStringResourceConvertible`**. The framework routes thrown errors by *type* and keys on that protocol; `LocalizedError` alone shows the user a generic "something went wrong".

### Intents (`AppIntents/Intents/`)
| Intent | Schema / protocol | Notes |
|--------|-------------------|-------|
| `SearchProjectsIntent` | `@AppIntent(schema: .system.searchInApp)`, `ShowInAppSearchResultsIntent` | `router.showSearch(term)` → Home with the search field presented. (`.system.search` is deprecated in 27.) |
| `OpenProjectIntent` | `@AppIntent(schema: .system.open)`, `OpenIntent` | Spotlight uses it to open project results. |
| `OpenPageIntent` | `OpenIntent` | Opens the project at a page; Spotlight uses it for page results. |
| `CreateProjectIntent` | `LongRunningIntent, CancellableIntent` | "Scan New Project": `[IntentFile]` (images/PDF) → `ProjectImportPipeline` → returns `ProjectEntity`; reports per-page `progress`. Staging the incoming files runs through the nonisolated `stageFiles(_:in:)` so the copy/write loop doesn't block the main actor. |
| `GetProjectTextIntent` | `AppIntent` | Plain text via `ProjectStore.projectText` (RTF comes from Transferable). |
| `DeleteProjectIntent` | `DeleteIntent` | `requestConfirmation` then `ProjectMaintenance.deleteProjects` on the main context. |

`MultiScanShortcuts` (`AppShortcutsProvider`) exposes Search / Open / Scan phrases; phrases are localized in `AppShortcuts.xcstrings`. Call `MultiScanShortcuts.updateAppShortcutParameters()` after creating, renaming, or deleting projects (already done in the pipeline, `DocumentCard`, `HomeView`, `DeleteProjectIntent`). Keep the phrase set small and distinct — near-duplicate wordings *degrade* Siri's match accuracy, since the system already does flexible matching.

### Donation
App Intents does **not** auto-donate actions taken in the app's own UI — the system only donates intents it ran itself. `DocumentCard.openProject()` donates `OpenProjectIntent` after an open so Siri Suggestions and Spotlight prediction learn the pattern. `ProjectMaintenance.deleteDonations(forProjects:)` prunes donations when a project is deleted (called from both `deleteProjects` and `HomeView.deleteDocument`) — the system never prunes them itself, and stale donations degrade prediction. In-app *creation* is deliberately not donated: a `CreateProjectIntent` carries `[IntentFile]`, which a file-picker import can't reproduce, so the donation would be unreplayable.

The `.system` domain has **no entity schemas**, so the entities are plain `AppEntity` types. `@AssistantIntent`/`@AssistantEntity` are deprecated — use `@AppIntent(schema:)` / `@AppEntity(schema:)`.

### Onscreen awareness
`DocumentCard` annotates itself with `.appEntityIdentifier(ProjectEntity)`, and both review views annotate the viewer with the current `PageEntity`, so Siri / Apple Intelligence can resolve "this project" / "this page".

### Deep links: `AppRouter` (`Services/AppRouter.swift`)
`@MainActor @Observable`, one per process, injected via `.environment(AppRouter.shared)` and registered with `AppDependencyManager`. `open(project:page:)` sets an `OpenRequest`; `ContentView` switches `selectedDocument` by uuid; `ReviewView`/`CompactReviewView` consume the page number (`goToPage`) once they show that project. `showSearch(term)` sets `wantsHome` + `searchText` + `isSearchPresented`. macOS multi-window: every window observes the router; the one showing the target navigates (accepted limitation).

### Spotlight indexing: `SpotlightIndexer` (`Services/SpotlightIndexer.swift`)
- Named index `CSSearchableIndex(name: "MultiScan")`; entities donated with `indexAppEntities`, removed with `deleteAppEntities(identifiedBy:ofType:)`.
- **Reconcile, don't hook**: no write site calls the indexer. A local manifest (`Application Support/MultiScan/spotlight-manifest.plist`, uuid → fingerprint string) is diffed against `ProjectStore.fingerprints()`; changed rows are re-donated (projects in one batch, pages in batches of 200, manifest saved after each batch), missing rows deleted first. Page fingerprints include the project name (page results show it as subtitle).
- Triggers: `ModelContext.didSave`, `.NSPersistentStoreRemoteChange`, `scenePhase == .active`, and post-launch backfill — all debounced 2 s; one pass at a time with a "run again" flag. The remote-change observer is the indexer's only Core Data API (SwiftData has no public equivalent) — intentional, keep it.
- No in-app on/off setting: users control MultiScan in Spotlight through the system's own Settings (Siri & Search / Spotlight). Don't add one.
- `ProjectStore` builds entities off the main actor; page thumbnails are downscaled to 128 px JPEG at index time (project cover 200 px) to keep the index small.

### App-wide search UI (`HomeView` + `Views/SearchResultsView.swift`)
- `.searchable(text:isPresented:)` bound to the router. Placement via `DefaultToolbarItem(kind: .search, placement:)`: `.primaryAction` declared *before* the `+` item on macOS and iPad (search sits to its left); `.bottomBar` on iPhone (compact width).
- While a query is present, `SearchResultsView` replaces the grid: `ProjectStore.search(term:)` (debounced 250 ms; `#Predicate` on `Document.name` and `Page.plainText`) returns Sendable hits with ±60-char snippets; matches are bolded; tapping routes through `AppRouter.open(project:page:)`.
- The per-document filters in `ThumbnailSidebar`, `SlideGridView`, and `NavigationState` still use `page.plainText` — now the stored column, so they no longer decode RTF per keystroke.

### Import pipeline (`Services/ProjectImportPipeline.swift`)
`@MainActor @Observable` singleton owning the `OCRService`/`ImageImportService` and the in-flight state (`processingDocumentIDs`, `progress`). `prepare(urls:optimizeImages:onEstimate:)` scans files/folders and renders PDFs; `createProject(named:images:onPageProgress:)` inserts the `Document`, runs OCR, fills pages, builds the export cache, and returns the project `uuid` (deleting the document on failure). `HomeView` and `CreateProjectIntent` both use it, so intent-driven imports show the same progress card.

### Debug aid
Launching a DEBUG build with `-seedSampleProject` inserts a text-only sample project when the store is empty and logs a search self-test (`DebugSampleData`).

## Accessibility & Search

### Accessibility Integration
- The TextKit 2 editor is a real NSTextView/UITextView, so system text accessibility (VoiceOver text navigation, macOS Edit ▸ Speech, dictation, Voice Control) works natively
- **Dynamic Type (iOS)**: attributed strings carry explicit fonts, so they don't rescale automatically. `PageTextView` registers for `UITraitPreferredContentSizeCategory` changes and `PageTextController.dynamicTypeDidChange()` re-normalizes the live content to the new body size (display-only — storage strips sizes, so this never dirties the document)
- **⚠️ Pending on-device verification**: the SwiftUI accessibility custom actions on `PageTextEditor` ("Exit text editor", next/previous page) haven't been VoiceOver-tested since the TextKit 2 migration — actions attached to a representable may not surface on the wrapped text view's accessibility element. Fallback if missing: `accessibilityCustomActions` on `PageTextView`

### Search
App-wide search is implemented (see "App-wide search UI"): `ProjectStore.search(term:)` queries the stored `Page.plainText` column with `#Predicate`. In-page find is native: `PageTextController.presentFindNavigator()`.

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
All order changes flow through one private core, `NavigationState.setPageOrder(_:actionName:)`, which renumbers pages 1…N to match a given array, syncs the export cache in a single write (`TextExportCacheService.renumberEntries`, raw-field copies — no decode/encode), remaps the shuffled visit history, refreshes navigation, and registers undo:
- **Move Up/Down** (context menus, Edit menu ⌘⌥↑/⌘⌥↓): `movePage(_:by:)` swaps one slot — kept as the accessible non-drag path
- **Drag & drop**: thumbnails are draggable via SwiftUI `.reorderable()` + `.reorderContainer(for: Page.self, isEnabled:move:)` in `ThumbnailSidebar` (macOS + iPad) and `SlideGridView` (iPhone); the `ReorderDifference` (sources + before/end destination) is applied by `applyReorder(of:before:)`
- Reordering is disabled while a filter or search is active (`isEnabled:`); Move Up/Down remain filter-safe (operate on actual document order)
- **Selection follows the page, not the slot**: after any reorder the current page keeps showing at its new number. This also keeps `currentPage` identity stable so the text editor never re-attaches (which would clear the undo stack)

### Undo (⌘Z / ⇧⌘Z)
- ReviewView/CompactReviewView wire the environment `\.undoManager` into `NavigationState.undoManager` (weak)
- `setPageOrder` registers an inverse action capturing only `PersistentIdentifier`s (Sendable); undo/redo resolve pages by ID at fire time and no-op if pages were added/deleted since
- Action names: "Move Page Up/Down", "Reorder Pages" (localized)
- macOS caveat: the window undo manager is shared with the text editor, and `PageTextController.attach()` clears it on page switch — so reorder undo history survives reorders (current page identity is stable) but not manual page navigation

### NavigationState Methods
```swift
var canMoveCurrentPageUp: Bool
var canMoveCurrentPageDown: Bool
func moveCurrentPageUp()                 // -> movePage(currentPage, by: -1)
func moveCurrentPageDown()               // -> movePage(currentPage, by: 1)
func movePage(_ page: Page, by offset: Int)
func applyReorder(of pageIDs: [PersistentIdentifier], before targetID: PersistentIdentifier?)
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
All commands live in `MultiScanCommands` (`MultiScanCommands.swift`) and read the focused window through these entries (declared in `MultiScanApp.swift`):
- `navigationState: NavigationState?` — the focused review view's model. The current project and page are *derived* from it (`selectedDocument`, `currentPage`); don't add separate `document`/`currentPage` entries.
- `pageTextController: PageTextController?` — from RichTextSidebar; Format menu (B/I/U/S) and save-before-export go through it
- `imageZoomController: ImageZoomController?` — from ImageViewer; View ▸ Fit/Zoom
- `Binding<Bool>?` toggles: `showExportPanel`, `showAddFromPhotos`, `showAddFromFiles`, `showFindNavigator`, `showDeletePageConfirmation` — a command flips the binding, the owning view presents the sheet/dialog. ReviewView provides all of them; CompactReviewView provides `navigationState` + `showDeletePageConfirmation` (⌘⌫ on a hardware keyboard). The "Delete Page N?" dialog itself is the shared `deletePageConfirmation(isPresented:pageNumber:onDelete:)` modifier in `PageMenuControls.swift`, also used by the thumbnail context menu and the iPhone page grid.

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
    let pageLastModified: Date? // Freshness fingerprint (see below)
}
```

Each entry stores the text **twice on purpose**: export needs formatting (`rtfData`), Smart Cleanup analysis needs only plain text (`plainText`) — so analysis never decodes an attributed string at all. Version 1 caches (JSON AttributedString entries) fail plist decoding → `decodeCache` returns nil → rebuilt from source pages once.

#### ⚠️ Freshness fingerprints — read this before touching the cache

The cache is one blob on `Document`, but the text it mirrors lives on the `Page` records. Under CloudKit those are separate record types with independent last-writer-wins resolution: **if two devices edit different pages of the same project, both page edits merge correctly but only one device's cache blob survives** — leaving a cache that is well-formed, the right length, and wrong. The old `cache.pages.count == pages.count` check can't see this.

So each entry records its source page's `lastModified` at write time, and `isFresh(_:against:)` compares every entry against the live pages.

- **Read-side consumers must use `loadFreshCache(from:)`**, never `loadCache(from:)`. Consumers with a cheap fallback (`TextExporter`) pass `rebuildIfStale: false` and take the slow path; Smart Cleanup's edit paths pass `rebuildIfStale: true` because there is no alternative source. Off-main consumers (`SmartCleanupModel.analyze`, `ProjectStore`) build `fingerprints(of:)` on their own actor and call the `nonisolated isFresh(_:against:)` after decoding.
- **The mutation helpers deliberately keep using the raw `loadCache`.** They run while pages and cache are intentionally out of step (pages already renumbered, cache not yet); a freshness check there would reject a cache that's about to be corrected and force a needless full rebuild.
- **`pageLastModified` is optional, and `nil` means "unverifiable", not "stale".** Caches written before fingerprinting exist on disk and sync; rejecting them would force an N-external-read rebuild of every document on upgrade. Entries gain fingerprints as pages are written, so the gap closes on its own. Don't "tighten" this into a required field without accepting that cost.
- Any new `PageCacheEntry` built from a page write must pass the page's `lastModified` **after** the `attributedText` assignment (the setter bumps it). `renumbered(to:)` carries the fingerprint over unchanged — reordering doesn't touch text.

#### Sync Points
The cache is updated whenever page data changes:

| Event | Cache Action | Location |
|-------|--------------|----------|
| Document created (after OCR) | `buildInitialCache()` | `HomeView.updateDocument()` |
| Page text saved | `updateEntry()` | `PageTextController.saveNow()` |
| Page added to document | `addEntries()` | `ReviewView.addPagesToDocument()` |
| Page deleted | `removeEntry()` | `NavigationState.deleteCurrentPage()`, `ThumbnailSidebar.deletePage()` |
| Page reordered | `renumberEntries()` | `NavigationState.setPageOrder()` (Move Up/Down, drag reorder, undo) |

#### Key Methods
```swift
// Build initial cache (call after OCR while data is in memory)
static func buildInitialCache(for document: Document, from pages: [Page])

// Update single page entry (call after page text edit).
// pageLastModified is the freshness fingerprint — read it off the page AFTER the write.
static func updateEntry(pageNumber: Int, attributedText: NSAttributedString, pageLastModified: Date?, in document: Document)

// Add new page entries (call after adding pages to existing document)
static func addEntries(for pages: [Page], to document: Document)

// Remove page entry (call after page deletion)
static func removeEntry(pageNumber: Int, from document: Document)

// Renumber entries after a reorder (old → new page number mapping, one write)
static func renumberEntries(_ newNumbers: [Int: Int], in document: Document)

// Raw load — mutation helpers only (see freshness note above)
static func loadCache(from document: Document) -> TextExportCache?

// Load for READING page content: nil unless the cache still matches the pages
static func loadFreshCache(from document: Document, rebuildIfStale: Bool = false) -> TextExportCache?

// Freshness primitives for off-main consumers
nonisolated static func fingerprints(of document: Document) -> [Int: Date]
nonisolated static func isFresh(_ cache: TextExportCache, against fingerprints: [Int: Date]) -> Bool
```

Renumbering operations (`insertEntries`, `removeEntry`, `renumberEntries`) use `PageCacheEntry.renumbered(to:)`, which copies raw fields — no decode/encode. `PageCacheEntry.decodedText()` decodes an entry's RTF for removal operations.

#### Cache Resilience
- **Version checking**: Cache includes version number; mismatches (including v1 caches) trigger automatic rebuild
- **Freshness checking**: entry fingerprints vs. page `lastModified` catch a cache that diverged from the pages (CloudKit merge) — see above
- **Fallback**: If cache is invalid, stale, or missing, TextExporter falls back to direct page loading
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
Builds a combined `NSAttributedString` from all pages, returning a `TextExportResult` (`attributedText` for preview + pre-encoded `rtfData`/`plainText` for sharing, exposed as `.richText`). `TextExporter(document:settings:)` reads the export cache when it is fresh (one file) and falls back to the pages' raw `richTextData` otherwise (N external-storage reads). The static `buildResult(from:…)` is `@concurrent` so `ProjectStore` (App Intents / Transferable exports) shares the same combine code off the main actor.

### Export Pipeline (with cache)
```
1. Load document.textExportCache (single file read — fast!)
   → Sendable PageSnapshots (raw RTF bytes + pre-computed stats)

2. Build off the main actor (`@concurrent static buildResult`)
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
- Analysis runs **off the MainActor**: the raw cache `Data` and page fingerprints go to the `@concurrent` `SmartCleanupModel.computeOptions`, which decodes via the nonisolated `TextExportCacheService.decodeCache(from:)`; only the resulting options come back to the main actor. (Off-main work in this project uses `@concurrent nonisolated` functions rather than `Task.detached`; the one remaining `Task.detached` is the fire-and-forget donation cleanup in `ProjectMaintenance`.)

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

Both compute a removal range on plain text (`removalRange(forPageNumberToken:in:)` / `lineRemovalRange(matching:in:stripNumbers:)`) and delete it from an `NSMutableAttributedString` — formatting on surrounding text is preserved automatically (`removePageNumberToken(_:in:)` / `removeLine(matching:in:stripNumbers:)`, both in place).

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
