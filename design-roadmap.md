# ReadBTR — Design Roadmap

Lower-level design document: concrete data models, module layout, screen-by-screen
behavior, and the algorithms tying it together. Where `dev.md` answers *why* and
*what technology*, this file answers *how it's actually structured*. Written to be
handed to an implementing agent directly — Swift signatures here are
design-level (illustrative field lists and function shapes), not final code, but
should be close enough to build from without re-deriving the architecture.

Status: **Design — not yet implemented.** The only code that exists today is the
Readium spikes under `ReadBTR/Spike/` and `ReadBTRTests/ReadiumSpikeTests.swift`
(see `dev.md` §9), which this design builds directly on top of.

Terminology note: this doc renames dev.md's "Single Word Reading" to **RSVP**
and "Highlighted Reading" to **Guided Reading** — same features, tighter names.
Treat them as synonyms when cross-referencing `dev.md`.

---

## 1. Module structure

Per instruction: everything stays in one Xcode target, organized as folders —
no SPM-internal modules yet. Proposed layout under `ReadBTR/`:

```
ReadBTR/
  App/                 — app entry point, root navigation state
  Models/              — SwiftData @Model types + shared Codable value types (§3)
  Persistence/          — ModelContainer setup, AppSettings singleton helper
  Ingestion/            — book import pipeline, Readium open/parse wrapper (§6)
  ReadingEngine/        — position translation layer, word-stream builder (§4)
  ReadingModes/
    Registry/            — ReadingModeDescriptor, mode dispatch (§5)
    RSVP/
    GuidedReading/
    Normal/
  BTR/                  — BTR menu, entity extraction, chapter summaries (§7.6)
  AI/                   — AIProvider protocol, GeminiProvider, prompt builders
  Settings/              — configuration page + view models (§7.2)
  Home/                  — library grid, search, add-book flow (§7.1)
  DesignSystem/          — Catppuccin tokens, shared components (dev.md §10)
  Supabase/              — disabled-by-default sync stub (§9)
  Spike/                 — existing throwaway Readium spikes; superseded
                            incrementally as Ingestion/ReadingEngine land,
                            deleted once nothing references it
```

Folders, not access boundaries — nothing here stops one folder's code from
importing another's. Revisit as real SPM modules only if build times or team
size ever demand it (neither is true today).

---

## 2. Data models

### 2.1 Storage strategy

Two kinds of types throughout this section:

- **`@Model` classes** — SwiftData-persisted entities with real identity and,
  where relevant, relationships: things that form a *collection* (a book has
  many chapter summaries, many entity profiles, many saved quotes) or that
  benefit from independent querying.
- **Plain `Codable` structs** — embedded directly as properties on a `@Model`
  (SwiftData persists `Codable` value types natively). Used for anything that's
  inherently 1:1 with its owner and never queried independently — a book's
  current position, its theme override, its settings override. No relationship
  boilerplate, no cascade-delete rules to get wrong, and it mirrors how
  `Locator` itself is just a serializable value, not an entity.

### 2.2 `Book` — the aggregate root

```swift
@Model
final class Book {
    @Attribute(.unique) var id: UUID
    var title: String
    var author: String?
    var format: BookFormat                    // .epub for MVP (dev.md §0)
    var relativeFilePath: String               // relative to the app's Books
                                                 // directory — see §6.3 for why
                                                 // this must never be absolute
    var relativeCoverImagePath: String?
    var addedAt: Date
    var lastOpenedAt: Date?

    /// Canonical current reading position, shared across all three modes.
    /// See §4 for how each mode reads/writes this.
    var position: BookPosition

    /// Explicitly called out by the product spec as living directly on Book.
    /// When set, the reader UI uses this instead of AppSettings.defaultTheme.
    var themeOverride: ReaderTheme?

    /// Everything else that's overridable per-book (RSVP/Guided/Normal
    /// settings, AI feature flags) — split out per instruction; see §2.5.
    var settingsOverride: BookSettingsOverride?

    @Relationship(deleteRule: .cascade) var chapterSummaries: [ChapterSummary] = []
    @Relationship(deleteRule: .cascade) var entityProfiles: [EntityProfile] = []
    @Relationship(deleteRule: .cascade) var savedQuotes: [SavedQuote] = []
}

enum BookFormat: String, Codable { case epub }
```

`Book` is deliberately thin on its own fields and heavy on composition — it's
the "conglomerate source of truth" the spec asks for, assembled from the pieces
below, not a model that redefines them inline.

### 2.3 `BookPosition` — the canonical position

```swift
struct BookPosition: Codable, Equatable {
    /// A Readium `Locator`, serialized via `Locator.jsonString()` (proven
    /// round-trippable in the phase-1 spike, dev.md §4.1/§9).
    var locatorJSON: String

    /// Denormalized copy of `Locator.href`, so callers can check whether a
    /// cached word array (§4.2) is reusable without decoding JSON first.
    var resourceHref: String

    var updatedAt: Date
}
```

This is the one field every reading mode reads from and writes to. See §4 for
the full translation layer.

### 2.4 `ReaderTheme` — reader-surface appearance

```swift
struct ReaderTheme: Codable, Equatable {
    var backgroundColorHex: String
    var textColorHex: String
    var highlightColorHex: String     // Guided Reading's highlight color
    var fontName: String?             // nil = system default
    var fontSize: Double
    var lineSpacing: Double
    var marginPoints: Double
}
```

Deliberately independent of the app-chrome Catppuccin palette (dev.md §10.2) —
`AppSettings.defaultTheme` holds the global default, `Book.themeOverride`
overrides it per book, and neither has anything to do with the app's own
navigation/settings UI color scheme.

### 2.5 Per-mode settings + `BookSettingsOverride`

```swift
struct RSVPSettings: Codable, Equatable {
    var wordsPerMinute: Int
    var smartTimingEnabled: Bool
    var skipIncrementSmall: Int    // default 5
    var skipIncrementMedium: Int   // default 15
    var skipIncrementLarge: Int    // default 30
}

struct GuidedReadingSettings: Codable, Equatable {
    var wordsPerMinute: Int                       // drives auto-scroll pacing
    var highlightGranularity: HighlightGranularity // see decision log, §10
}
enum HighlightGranularity: String, Codable { case sentence, phrase }

struct NormalModeSettings: Codable, Equatable {
    var layout: NormalModeLayout
}
enum NormalModeLayout: String, Codable { case scrolling, paginated }

struct ReaderSettings: Codable, Equatable {
    var rsvp: RSVPSettings
    var guidedReading: GuidedReadingSettings
    var normalMode: NormalModeSettings
}
```

```swift
struct AIFeatureFlag: Codable, Equatable {
    var key: AIFeatureKey
    var isEnabled: Bool
}

/// The abstract, extensible AI-flag model the spec asks for: adding a new
/// AI feature anywhere in the app means adding one case here — nothing about
/// AppSettings, BookSettingsOverride, or the config page UI has to change,
/// since both iterate `AIFeatureKey.allCases`.
enum AIFeatureKey: String, Codable, CaseIterable {
    case chapterSummary
    case entityExtraction
    case comprehensionCheck
    // dev.md §3 also names summaries/Q&A/comprehension-checks as v1 AI
    // features; entityExtraction is the BTR-menu character/location lookup.
}
```

```swift
struct BookSettingsOverride: Codable, Equatable {
    /// nil = inherit AppSettings.defaultReaderSettings entirely.
    /// When the user edits *any* per-book reading setting for the first
    /// time, the config page clones the current effective ReaderSettings
    /// into this field, then mutates in place — category-level override,
    /// not field-level, matching how `Book.themeOverride` already works.
    var readerSettings: ReaderSettings?

    /// Sparse — only entries the user has explicitly overridden for this
    /// book appear here. Missing key = inherit the global flag.
    var aiFeatureFlagOverrides: [AIFeatureFlag] = []
}
```

Effective-value resolution (used by every reading mode and the config page):

```swift
extension Book {
    func effectiveReaderSettings(_ global: AppSettings) -> ReaderSettings {
        settingsOverride?.readerSettings ?? global.defaultReaderSettings
    }

    func effectiveTheme(_ global: AppSettings) -> ReaderTheme {
        themeOverride ?? global.defaultTheme
    }

    func isAIFeatureEnabled(_ key: AIFeatureKey, _ global: AppSettings) -> Bool {
        guard global.aiProviderIsUsable, global.aiFeaturesMasterToggle else { return false }
        if let override = settingsOverride?.aiFeatureFlagOverrides.first(where: { $0.key == key }) {
            return override.isEnabled
        }
        return global.aiFeatureFlags.first(where: { $0.key == key })?.isEnabled ?? false
    }
}
```

### 2.6 `AppSettings` — global configuration (singleton)

```swift
@Model
final class AppSettings {
    var defaultTheme: ReaderTheme
    var defaultReaderSettings: ReaderSettings
    var aiFeaturesMasterToggle: Bool
    var aiFeatureFlags: [AIFeatureFlag]     // one entry per AIFeatureKey
    var aiProvider: AIProviderKind?          // nil until the user picks one
    var supabaseSyncEnabled: Bool            // default false — §9

    /// Computed, not stored: true only if a provider is selected *and* the
    /// Keychain actually holds a key for it. "If a provider or key is not
    /// given, AI features should be disabled" — this is that rule, enforced
    /// in one place rather than re-checked ad hoc.
    var aiProviderIsUsable: Bool { ... }  // checks AIKeyStore.hasKey(for:)
}
```

SwiftData has no native singleton concept — use a small helper
(`AppSettingsStore.current(in: modelContext)`) that fetches the first row and
inserts a default-constructed one if none exists. Every screen reads/writes
through that helper, never queries `AppSettings` directly.

### 2.7 `AIProviderKind` + Keychain

```swift
enum AIProviderKind: String, Codable, CaseIterable {
    case gemini
    // future: openAI, anthropic, ... — dev.md §3's provider-agnostic
    // interface is what makes adding a case here low-cost
}
```

The API key **never** lives in SwiftData (dev.md §3). A small `AIKeyStore`
service wraps Keychain Services, keyed by `AIProviderKind.rawValue`:

```swift
protocol AIKeyStore {
    func key(for provider: AIProviderKind) -> String?
    func setKey(_ key: String?, for provider: AIProviderKind)
    func hasKey(for provider: AIProviderKind) -> Bool
}
```

### 2.8 `AIProvider` protocol

```swift
protocol AIProvider {
    func generateText(prompt: String, responseSchema: AIResponseSchema?) async throws -> String
}

enum AIResponseSchema {
    case plainText
    case json(schema: [String: Any])   // mirrors Gemini's `responseSchema`
}
```

`GeminiProvider: AIProvider` is the only conformance for MVP. Every AI feature
in §7.6 goes through this one interface — chapter summaries and comprehension
checks use `.plainText`, entity extraction uses `.json(schema:)` for reliable
parsing (see §7.6.4).

### 2.9 `ChapterSummary`

```swift
@Model
final class ChapterSummary {
    var id: UUID
    var chapterHref: String              // Readium resource href — see decision
                                          // log (§10) for why "chapter" ==
                                          // "spine item" for MVP
    var chapterTitle: String?
    var content: String
    var sourceEndLocatorJSON: String     // how far into the chapter this
                                          // summary covers — the staleness key
    var generatedAt: Date
    var book: Book?
}
```

**Cache/staleness rule**: reuse an existing `ChapterSummary` for
`(book, chapterHref)` as long as the reader's current position is at or before
`sourceEndLocatorJSON`'s progression. If they've read further into the same
chapter since the summary was generated, regenerate and overwrite on next
request. This directly satisfies "also save these" while keeping the summary
honest about what it actually covers.

### 2.10 `EntityProfile`

```swift
enum EntityKind: String, Codable { case character, location }

@Model
final class EntityProfile {
    var id: UUID
    var canonicalName: String    // trimmed + lowercased — the dedup key
    var displayName: String      // original casing, for UI
    var kind: EntityKind
    var summary: String
    var firstMentionLocatorJSON: String
    var generatedAt: Date
    var book: Book?
}
```

**Dedup rule**: before firing the second-stage "gather context + summarize"
request (§7.6.4), check `book.entityProfiles` for a `canonicalName` match. If
found, show it immediately — no new API call. This is the direct answer to
"figure out the best way to store this data in the context of the Book model":
a separate `@Model`, cascade-deleted with its book, deduplicated by a
normalized name field. (Known MVP limitation: exact/normalized string match
only — "Alice" and "Alice Liddell" won't merge. Fine to punt on fuzzy matching.)

### 2.11 `SavedQuote`

```swift
@Model
final class SavedQuote {
    var id: UUID
    var text: String              // denormalized, so display doesn't need
                                   // to re-fetch from the publication
    var startLocatorJSON: String
    var endLocatorJSON: String
    var note: String?
    var createdAt: Date
    var book: Book?
}
```

Populated by Guided Reading's multi-word "save quote" action (§7.4).

---

## 3. Reading mode registry

The spec is explicit: no hardcoded per-mode branching scattered through the
app. The list of modes is data; only *dispatch* (turning a mode ID into a view)
needs a single switch, and that's the one contained place a new mode gets wired
in.

```swift
enum ReadingModeID: String, Codable, CaseIterable {
    case rsvp, guidedReading, normal
    // adding a 4th mode: add a case, a descriptor below, and one switch
    // branch in ReadingModeRegistry.makeView — nowhere else.
}

struct ReadingModeDescriptor: Identifiable {
    let id: ReadingModeID
    let displayName: String
    let systemImageName: String
}

enum ReadingModeRegistry {
    static let all: [ReadingModeDescriptor] = [
        .init(id: .rsvp, displayName: "RSVP", systemImageName: "text.word.spacing"),
        .init(id: .guidedReading, displayName: "Guided Reading", systemImageName: "text.line.first.and.arrowtriangle.forward"),
        .init(id: .normal, displayName: "Normal", systemImageName: "book"),
    ]

    @ViewBuilder
    static func makeView(for id: ReadingModeID, book: Book) -> some View {
        switch id {
        case .rsvp: RSVPView(book: book)
        case .guidedReading: GuidedReadingView(book: book)
        case .normal: NormalReadingView(book: book)
        }
    }
}
```

The "choose a mode" sheet on Home (§7.1) is a `ForEach(ReadingModeRegistry.all)`,
not three hardcoded buttons. The exhaustive `switch` in `makeView` is normal,
idiomatic Swift dispatch, not the kind of "hardcoded logic" the spec is warning
against — it's one seam, not duplicated business logic.

---

## 4. Cross-mode position syncing

The core promise: load any book into any mode and it "just works," because
`Book` knows how to resolve its own position for whichever mode is asking.
Implemented as `ReadingEngine/`, exposed as a `Book` extension per instruction.

### 4.1 Why this needs a translation layer at all

- Normal and Guided Reading run on Readium's `EPUBNavigatorViewController` and
  navigate purely in terms of `Locator` (dev.md §4.2, confirmed by the phase-2
  spike).
- RSVP has no navigator — it steps through a materialized array of words, so
  its native position is an **index into that array**, not a `Locator`.
- The phase-1 spike found that word-level `Locator`s share their parent
  paragraph's positional anchor and differ only by `text.highlight`/context
  (dev.md §4.1) — so there's no free lunch turning an arbitrary `Locator` into
  an exact word index. It has to be approximated.

### 4.2 The word stream

```swift
/// Built lazily, per resource (≈ per chapter), never for the whole book at
/// once. Cheap to rebuild — the phase-1 spike parsed and tokenized an entire
/// novel in well under a second — so this is not persisted to disk (§8).
struct WordStream {
    let resourceHref: String
    let words: [TextContentElement.Segment]   // from makeTextContentTokenizer(unit: .word)
}

enum WordStreamCache {
    // in-memory only, keyed by resourceHref, evicted on mode exit
    static func stream(for href: String, in publication: Publication) async -> WordStream
}
```

### 4.3 `Locator` → word index (Normal/Guided → RSVP)

```swift
enum RSVPPositionResolver {
    /// 1. Estimate: `Int((locator.locations.progression ?? 0) * words.count)`.
    /// 2. Refine: search a small window (e.g. ±25) around the estimate for a
    ///    segment whose `text.highlight`/`text.before` matches the locator's
    ///    own text context.
    /// 3. Fall back to the raw estimate if nothing in the window matches —
    ///    approximate beats blocking, and it's rarely far off since
    ///    progression is monotonic within a resource.
    static func wordIndex(for locator: Locator, in stream: WordStream) -> Int
}
```

### 4.4 Word index → `Locator` (RSVP → Normal/Guided)

Trivial, and exact: every word segment already carries its own valid `Locator`
(confirmed in the phase-1 spike). Leaving RSVP just means
`book.updatePosition(from: currentWord.locator)` — no approximation needed in
this direction.

### 4.5 The `Book` API every mode actually calls

```swift
extension Book {
    /// Normal/Guided call this from NavigatorDelegate.locationDidChange.
    /// RSVP calls it with `currentWord.locator` whenever the index changes.
    func updatePosition(from locator: Locator) {
        position = BookPosition(
            locatorJSON: (try? locator.jsonString()) ?? position.locatorJSON,
            resourceHref: locator.href.string,
            updatedAt: .now
        )
    }

    /// What Normal/Guided consume directly.
    var currentLocator: Locator? {
        try? Locator(jsonString: position.locatorJSON)
    }

    /// What RSVP consumes — resolves lazily via §4.3, building/reusing a
    /// WordStream for the current resource.
    func currentRSVPIndex(publication: Publication) async -> (stream: WordStream, index: Int)? { ... }
}
```

Every reading-mode view's job on appear is: read `book.currentLocator` (or
`currentRSVPIndex`), nothing else — the mode itself never has to know how the
user got there.

---

## 5. Book import pipeline

### 5.1 Picking a file

SwiftUI's `.fileImporter(isPresented:allowedContentTypes:onCompletion:)` with
`allowedContentTypes: [.epub]` (a built-in `UTType`) — this is the
`UIDocumentPickerViewController` flow the spec describes, just the SwiftUI-
native wrapper for it. PDF support later just adds `.pdf` to the list
(dev.md §0/§4.1).

### 5.2 The security-scoped resource gotcha

The URL `.fileImporter` hands back points outside the app's sandbox (Files
app, iCloud Drive, another app's document provider) and is
**security-scoped** — reads will silently fail without explicitly bracketing
access:

```swift
guard url.startAccessingSecurityScopedResource() else { throw ImportError.accessDenied }
defer { url.stopAccessingSecurityScopedResource() }
// read now, inside the bracket
```

### 5.3 Copy into the sandbox — and store a *relative* path

Don't keep a security-scoped bookmark to the external file. Copy the bytes
into the app's own container immediately:

```
<Application Support>/Books/<uuid>.epub
```

**Why Application Support, not Documents**: this is app-managed library
content, not something the user should browse/rename/delete via the Files
app — Application Support keeps it out of that surface while still being
included in the default iCloud device backup (so the library survives a
reinstall or device transfer without any Supabase/cloud-sync involvement).

**Why a generated UUID filename, not the original**: avoids collisions
between two different books that happen to share a filename.

**Why `Book.relativeFilePath` must be relative, not absolute**: the app
container's absolute path changes across app updates, device restores, and
reinstalls. An absolute path stored today silently breaks the book at some
unpredictable point later. Always resolve
`FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]`
fresh at read time and append the stored relative path — never persist the
resolved absolute `URL` itself.

### 5.4 Metadata + cover extraction, then the `Book` record

1. Open the freshly-copied file through the same `AssetRetriever` +
   `PublicationOpener` pipeline proven in the phase-1 spike.
2. Pull `publication.metadata.title`/`.authors` for the library entry.
3. Call `publication.cover()` (documented in Readium's Getting Started guide,
   not yet spiked) and write it to
   `<Application Support>/Books/<uuid>-cover.jpg`; store that relative path
   on `Book.relativeCoverImagePath`.
4. Insert the `Book` row with a fresh `BookPosition` at the beginning of the
   publication (progression 0 on the first reading-order resource).

Duplicate detection (same book imported twice) is a nice-to-have, not MVP —
note it here so it isn't forgotten, don't build it yet.

---

## 6. Screen specs

### 6.1 Home

- `ScrollView` + `LazyVGrid` with 3 fixed columns. First grid cell is a
  pinned "add book" tile that triggers the `.fileImporter` flow (§5); the rest
  are `Book` covers, newest-opened-first or however the library is sorted
  (open question — not blocking, pick one and move on).
- Search: a simple in-memory filter over `title`/`author` — library sizes are
  personal-scale, no need for a SwiftData `#Predicate`-backed search index.
- Settings icon (top right) → Configuration page in **global** mode (§6.2).
- Tapping a book → a sheet built from `ReadingModeRegistry.all` (§3) — one
  option per registered mode, not three hardcoded buttons. Selecting a mode
  calls `ReadingModeRegistry.makeView(for:book:)`, which reads
  `book.currentLocator`/`currentRSVPIndex` to land exactly where the user left
  off (§4.5).

### 6.2 Configuration page

One view, two modes of entry:
- From Home's settings icon → editing `AppSettings` directly (global
  defaults).
- From a reading mode's toolbar settings icon → editing `book.settingsOverride`
  (creating one via clone-on-first-edit if it doesn't exist yet, §2.5).

Sections: theme (background/text/highlight color, font, size, spacing,
margins — `ReaderTheme`), per-mode settings (RSVP speed/smart-timing/skip
increments, Guided Reading speed/granularity, Normal layout —
`ReaderSettings`), AI (master toggle, provider picker, API key entry →
`AIKeyStore`, per-feature toggles iterating `AIFeatureKey.allCases`).
"If a provider or key is not given, AI features should be disabled" is
enforced by `AppSettings.aiProviderIsUsable` gating the whole AI section's
interactivity, not just hiding it.

### 6.3 RSVP view

- Opens paused, on `book.currentRSVPIndex`'s word. Playing/paused state is a
  font-color distinction on the centered word, not a separate icon overlay.
- Tap anywhere outside the current word → toolbar appears (and playback
  pauses, if it wasn't already).
- **Toolbar**: settings icon (top right, → §6.2 in per-book mode), exit
  (top left, → Home), chapter select (top right, next to settings — a sheet
  listing `publication.tableOfContents()`, tapping an entry calls
  `book.updatePosition(from:)` with that chapter's start locator). Bottom of
  the toolbar: a horizontally scrolling strip centered on the current word
  with neighbors visible on either side, built with `ScrollView(.horizontal)`
  + iOS 17's `scrollPosition(id:)` bound to the word index from the same
  `WordStream` (§4.2) — scrolling it left/right moves the reading position,
  reusing exactly the data RSVP already has, no separate seek mechanism.

### 6.4 Guided Reading view

- Centered, highlighted text; highlight color and play/pause color are both
  theme-driven (`ReaderTheme.highlightColorHex`).
- Tap the highlighted text → pause/play. Tap outside it → same toolbar as
  RSVP (§6.3), same pause-on-open behavior.
- While paused, vertical scroll moves position back/forward — this maps
  naturally onto `EPUBNavigatorViewController`'s own scroll, with the
  currently-decorated segment (dev.md §4.2/§9 phase 2) following along.

### 6.5 Normal view

- Scrolling or paginated, per `ReaderSettings.normalMode.layout` — this is
  Readium's stock `EPUBNavigatorViewController`, no custom rendering (dev.md
  §4.2).
- Toolbar only appears on a tap at the *top* of the screen, not anywhere on
  the page — the one mode-specific variation in an otherwise shared toolbar
  trigger pattern. Implementation note: the trigger gesture differs per mode
  host view, but all three modes present the *same* `ReadingToolbar`
  component — don't fork the toolbar itself per mode.

### 6.6 The BTR menu

The app's headline feature — an AI-assisted "what/who is this" and
"what happened so far" layer available from every reading mode.

#### 6.6.1 Activation, per mode

- **RSVP**: long-press the current word → tooltip with **Define**,
  **View Surrounding**, and a BTR icon.
  - *Define* → `UIReferenceLibraryViewController` (see decision log, §10) —
    the system "Look Up" panel, no new dependency, offline.
  - *View Surrounding* → a modal presenting `NormalReadingView` (the same
    component from §6.5, reused, not reimplemented) in scrolling mode,
    centered on the current locator. Selecting text there re-triggers the
    tooltip in Normal-view context.
- **Guided Reading**: while paused, long-press a word → the same tooltip,
  plus drag-handles on either end of the selection (Readium's
  `SelectableNavigator` interface, documented but not yet spiked). Selecting
  more than one word swaps *Define* for **Save Quote** (writes a
  `SavedQuote`, §2.11); the BTR icon is available at any selection size.
- **Normal**: native WebView text selection, with the same tooltip appended
  as a custom `EditingAction` on `EPUBNavigatorViewController.Configuration`
  (documented in Readium's SwiftUI guide as exactly this pattern — appending
  actions to the default text-selection menu, not yet spiked but
  low-risk/well-documented).

#### 6.6.2 The BTR menu screen

Tapping the BTR icon opens a vertical split view: top half is `NormalReadingView`
(read-only) centered on the current selection/position; bottom half is the
"BTR options" panel. Back arrow (top left) returns to the originating reading
mode, resuming paused if that mode was paused.

#### 6.6.3 Option 1 — entity extraction (deterministic two-step pipeline)

Per the scoping decision in §10: a fixed, hard-coded pipeline, not a
tool-calling agent loop, for MVP.

**Step 1 — extraction, fires automatically on menu open:**
1. Resolve the current position to a word index (§4.5) and slice ±100 words
   from the same `WordStream` (clamped to the current resource if the window
   would cross a chapter boundary — accepted MVP simplification, see §10).
2. Send one `AIProvider.generateText` call: the sliced text + book title,
   requesting **structured JSON output** (`.json(schema:)`, §2.8) shaped like:
   ```json
   { "entities": [ { "name": "White Rabbit", "kind": "character" } ] }
   ```
   Structured output (not free-text parsing) is the point of using
   `responseSchema` here — reliability over flexibility for a fixed,
   well-defined extraction task.
3. Render each entity as a selectable chip in the BTR options panel.

**Step 2 — summary, fires when the user taps a chip:**
1. Check `book.entityProfiles` for a `canonicalName` match (§2.10). If found,
   display immediately — no API call.
2. Otherwise, gather context: walk `publication.readingOrder` from the start
   up to (and including) the current resource, run each through the Content
   API (proven fast in the phase-1 spike — ~1000 elements for a full novel in
   a fraction of a second), and collect snippets around case-insensitive
   substring matches of the entity's name. (This deliberately mirrors
   dev.md §3's Q&A spoiler-avoidance rule: only text the reader has already
   reached.)
3. One more `AIProvider.generateText` call: the gathered snippets + book
   title + entity name/kind, requesting a plain-text character/location
   summary.
4. Save as a new `EntityProfile`, display it, replacing the loading state.

#### 6.6.4 Option 2 — "summarize since start of chapter" (static option)

1. Range is `[start of current resource, current locator]` — "chapter" ==
   "spine item" for MVP (see decision log, §10).
2. Check for a fresh cached `ChapterSummary` first (§2.9's staleness rule).
3. If none/stale, extract the range's text via the Content API, one
   `AIProvider.generateText` call (`.plainText`), save/overwrite the
   `ChapterSummary`, display it.

Both options follow the same UI shape: selecting an option swaps the bottom
panel for a loading indicator, then swaps that for the result — one shared
"pending → result" component in `BTR/`, not two bespoke implementations.

#### 6.6.5 Comprehension checks and Q&A (dev.md §3)

Both are extra BTR options, shown only when their `AIFeatureKey`
(`.comprehensionCheck`, `.questionAnswering`) is on for the book.

**Comprehension check** ("Check My Understanding"):
1. Range is the same as §6.6.4: `[start of current resource, current
   locator]`, so a check never asks about text the reader hasn't reached.
2. Reuse the newest saved `ComprehensionCheck` for this chapter if it still
   covers the reader's position (same staleness rule as `ChapterSummary`),
   so reopening the menu shows earlier answers. "New Questions" forces a
   fresh set.
3. Otherwise one `generateText` call with `.json(schema:)` asking for 3
   multiple-choice questions (`question`, 4 `choices`, `correctChoiceIndex`,
   `explanation`). Malformed questions are dropped; the rest are saved as a
   new `ComprehensionCheck` row.
4. Tapping a choice locks it in (first answer wins), marks it right/wrong and
   shows the explanation. `completedAt` is set once every question is
   answered, so saved checks can feed a later "review what you've read"
   feature.

**Q&A** ("Ask a Question"):
1. Context is all text from the start of the book up to the anchor locator
   (`BTRReadSoFarTextExtractor`) — dev.md §3's spoiler rule. Capped at
   600k characters (~150k tokens), keeping the most recent text, to bound
   per-question cost on the reader's own key.
2. One `.plainText` call per question. The prompt forbids outside knowledge
   of the book's plot and anything past the given text, and passes the last
   4 exchanges so follow-ups make sense.
3. Exchanges live only for the menu session; they aren't persisted.

---

## 7. Persistence & caching

- **SwiftData schema**: `Book`, `AppSettings`, `ChapterSummary`,
  `EntityProfile`, `SavedQuote` as `@Model` types; everything else in §2 is an
  embedded `Codable` struct. `ModelContainer` assembled once in `App/` at
  launch.
- **Book files**: `<Application Support>/Books/<uuid>.epub` +
  `<uuid>-cover.jpg` (§5.3) — included in default iCloud backup, not exposed
  via Files app.
- **Parsed `Publication`/`WordStream` caching**: intentionally *not*
  persisted to disk for MVP. Re-parsing on demand is fast (proven in the
  phase-1/2 spikes — sub-second for a full novel), so the added complexity of
  a resource-level on-disk cache isn't justified yet. Revisit only if a real
  (large) book proves this wrong.
- **Schema migrations**: not a concern yet — the schema is expected to churn
  during initial build-out. Adopt `VersionedSchema`/`SchemaMigrationPlan`
  once the app has real user data worth preserving across schema changes, not
  before.

---

## 8. Supabase integration (stub only, per instruction to back-burner)

Wired for later, not activated now:

```swift
protocol DailyQuoteSyncClient {
    func registerDeviceToken(_ token: Data) async throws
    func syncCurrentBook(title: String, progress: Double) async throws
}

struct SupabaseDailyQuoteSyncClient: DailyQuoteSyncClient {
    func registerDeviceToken(_ token: Data) async throws { throw Unimplemented() }
    func syncCurrentBook(title: String, progress: Double) async throws { throw Unimplemented() }
}
```

Gated entirely behind `AppSettings.supabaseSyncEnabled` (default `false`) —
nothing calls into this protocol yet; push-notification registration is
deferred along with it. Full design lives in `dev.md` §8; this stub just
reserves the shape so wiring it up later doesn't require touching `Book` or
any reading-mode code.

---

## 9. Package/method decisions surfaced for review

Per instruction, decisions with real downstream consequences were raised
explicitly rather than decided silently:

- **Dictionary lookup**: `UIReferenceLibraryViewController` (system "Look Up"),
  over bundling a third-party dataset or calling an online API — decided,
  confirmed. Offline, zero new dependency, consistent with the app's
  local-first stance. Known limitation: obscure/archaic words in older
  public-domain texts may not resolve — acceptable for MVP.
- **BTR entity-lookup "agent"**: a deterministic two-step pipeline (search →
  one AI call), not a tool-calling LLM agent loop — decided, confirmed.
  Predictable cost/latency; revisit only if the fixed pipeline proves too
  rigid in practice.

## 10. Other decisions made by judgment call (flagged for visibility, not blocking)

- **`BookSettingsOverride` is category-level, not field-level** (§2.5): the
  first per-book settings edit clones the full effective `ReaderSettings`
  rather than tracking individual overridden fields. Simpler data model,
  matches how `Book.themeOverride` already behaves; the cost is a full clone
  on first edit instead of a sparse diff, which is irrelevant at this data
  size.
- **`BookSettingsOverride`/`ReaderTheme` are embedded structs, not
  `@Relationship` models** (§2.1): they're inherently 1:1 with their owning
  `Book` and never queried independently, unlike `ChapterSummary`/
  `EntityProfile`/`SavedQuote`, which are true collections.
- **"Chapter" == Readium spine item/resource**, not a table-of-contents
  entry, for both `ChapterSummary` and the entity-extraction context window
  (§6.6.3, §6.6.4). TOC entries and spine items aren't always 1:1, but
  aligning to the spine is far simpler to implement against
  (`publication.readingOrder`) and close enough for MVP.
- **`ChapterSummary` staleness** is based on comparing the reader's current
  progression to the summary's stored `sourceEndLocatorJSON` — regenerate if
  they've read further into the chapter since the summary was made, otherwise
  reuse. Not specified in the brief; this is the most literal reading of
  "also save these" that still keeps a summary honest about what it covers.
- **Entity-extraction context window is resource-clamped**: if the ±100-word
  window would cross a chapter/resource boundary, it's simply shorter near
  the edges rather than pulling words from an adjacent `WordStream`. Simpler,
  and edge cases here are rare relative to how often the feature fires.
- **Guided Reading's pacing unit is `wordsPerMinute`**, mirroring RSVP,
  rather than a separate "lines per minute" concept — one mental model for
  speed across both timed modes.
