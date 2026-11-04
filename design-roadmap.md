# ReadBTR — Design Roadmap

Lower-level design document: concrete data models, module layout, screen-by-screen
behavior, and the algorithms tying it together. Where `dev.md` answers *why* and
*what technology*, this file answers *how it's actually structured*. Written to be
handed to an implementing agent directly — Swift signatures here are
design-level (illustrative field lists and function shapes), not final code, but
should be close enough to build from without re-deriving the architecture.

Status: **Built, and kept current as the design changes.** Last major revision
2026-11-04: the BTR menu became the **BTR chat** (§6.6), comprehension checks
were removed from the app, and **book collections** were added (§2.12, §6.1.1).

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
  BTR/                  — BTR chat: chat screen, context agent, passage builder (§6.6)
  AI/                   — AIProvider protocol, GeminiProvider, prompt builders
  Settings/              — configuration page + view models (§7.2)
  Home/                  — library grid, search, add flow, collections (§6.1)
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
  many saved quotes, and many places in book collections) or that benefit
  from independent querying.
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

    @Relationship(deleteRule: .cascade) var savedQuotes: [SavedQuote] = []
    /// This book's places in collections (§2.12). Deleting the book
    /// removes it from every collection; the collections stay.
    @Relationship(deleteRule: .cascade) var collectionEntries: [CollectionEntry] = []
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
    case btrChat      // the BTR chat (§6.6) — currently the only AI feature
}
```

**Legacy keys.** Builds before 2026-11-04 stored `chapterSummary`,
`entityExtraction`, `questionAnswering` and `comprehensionCheck`. Saved settings
must keep decoding, so `AIFeatureKey`/`AIFeatureFlag` decode those raw values
too: the three old BTR menu features map to `.btrChat` (keeping their on/off
state, "on if any was on"), and `comprehensionCheck` is decoded as a *retired*
flag that's dropped. `[AIFeatureFlag].normalized` collapses the result to one
flag per key, and `AppSettingsStore.current` writes the cleaned array back.
Never encode a legacy key; never remove a raw value from this mapping while
old stores might exist.

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
        if let override = settingsOverride?.aiFeatureFlagOverrides.flag(for: key) {
            return override.isEnabled
        }
        return global.aiFeatureFlag(for: key)?.isEnabled ?? false   // via .normalized
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
    /// Multi-turn chat with standing instructions (the BTR chat, §6.6).
    func generateChatReply(systemPrompt: String, messages: [AIChatMessage]) async throws -> String
}

enum AIResponseSchema {
    case plainText
    case json(schema: [String: Any])   // mirrors Gemini's `responseSchema`
}

struct AIChatMessage { var role: Role /* .user, .assistant */; var text: String }
```

`GeminiProvider: AIProvider` is the only conformance for MVP. It maps
`generateChatReply` onto Gemini's native `systemInstruction` plus alternating
`user`/`model` `contents`. A protocol extension provides a fallback
`generateChatReply` that flattens the conversation into one `generateText`
prompt, so a future provider only has to implement `generateText` to work.
The BTR chat's retrieval plan (§6.6.3) uses `.json(schema:)`; replies are
free-form Markdown.

### 2.9 / 2.10 Removed: `ChapterSummary`, `EntityProfile` (and `ComprehensionCheck`)

These were caches behind the old BTR menu's fixed options (chapter summary,
character/location lookup) and the comprehension-check feature. The BTR chat
(§6.6) answers those questions on demand instead, and comprehension checks are
no longer part of the app. The models were dropped from the schema on
2026-11-04; SwiftData removes their tables in a lightweight migration the first
time the new schema opens an older store (`Persistence/AppSchema.swift`).

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

### 2.12 `BookCollection` + `CollectionEntry`

```swift
@Model
final class BookCollection {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    @Relationship(deleteRule: .cascade) var entries: [CollectionEntry] = []
}

@Model
final class CollectionEntry {
    var position: Int             // 0-based reading order, kept dense
    var collection: BookCollection?
    var book: Book?
}
```

A named, **ordered** group of books — usually a series. A book can be in any
number of collections and always still appears in the library on its own.
Membership lives on `CollectionEntry` rows rather than a plain
`[Book]` relationship because SwiftData doesn't preserve the order of a
to-many relationship, and the order is load-bearing: it's what the BTR chat's
spoiler rule runs on (§6.6.3). Deleting a collection deletes its entries, never
its books; deleting a book deletes its entries, never the collection.

Helpers on `BookCollection`: `orderedBooks`, `append(_:in:)` (no duplicates),
`remove(_:in:)` and `move(fromOffsets:toOffset:)` (SwiftUI `onMove`
semantics), all renumbering positions densely.

**Spoiler scope** — `Book.earlierBooksInCollections`: for every collection
the book is in, the books *before* it in that collection's order, combined
across collections in collection-name order, de-duplicated, excluding the book
itself. Books *after* it in a collection are never included. If the same two
books are in opposite orders in two collections, each counts as "earlier" for
the other — the reader's own ordering is taken at its word.

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
  pinned **Add** tile; then one tile per collection (a fanned stack of its
  first covers, with its name and book count); then every `Book` cover,
  most-recently-opened first.
- **Add** asks, in a confirmation dialog, whether to **Add Book** (the
  `.fileImporter` flow, §5) or start a **New Collection** (§6.1.1).
- Long-pressing a book offers **Add to Collection ▸** (each collection, with a
  checkmark on ones it's already in — tapping toggles membership — plus
  **New Collection…**, which starts a collection with that book in it) and
  **Delete Book**.
- Search: a simple in-memory filter over `title`/`author`, and collections by
  name or by any of their books' titles — library sizes are personal-scale, no
  need for a SwiftData `#Predicate`-backed search index.
- Settings icon (top right) → Configuration page in **global** mode (§6.2).
- Tapping a book → a sheet built from `ReadingModeRegistry.all` (§3) — one
  option per registered mode, not three hardcoded buttons. Selecting a mode
  calls `ReadingModeRegistry.makeView(for:book:)`, which reads
  `book.currentLocator`/`currentRSVPIndex` to land exactly where the user left
  off (§4.5).

#### 6.1.1 Collections

- **New Collection** sheet: a name field, then "Books, in reading order" —
  **Add Books from Library** opens a multi-select picker that numbers books in
  the order they're tapped; the list can be dragged to reorder and swiped to
  remove before creating. A footer explains that order is what keeps the BTR
  chat spoiler-free.
- **Collection screen** (tapping a collection tile pushes it): the books as a
  numbered list in reading order with covers. Tapping a book opens the same
  reading-mode picker as the library. **Add Books ▸ From Library / Import
  EPUB** (an import is added to the end of the collection as well as the
  library). **Reorder** toggles edit mode for drag handles; swipe a row to
  **Remove** it from the collection (the book stays in the library). The
  **⋯** menu has **Rename** and **Delete Collection** (books are kept).

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
`AIKeyStore`, per-feature toggles iterating `AIFeatureKey.allCases` — today
just **BTR Chat**).
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

### 6.6 The BTR chat

The app's headline feature: from any reading mode, ask any question about the
book — who someone is, what just happened, what a passage means — and get an
answer that never spoils anything ahead. Gated on `AIFeatureKey.btrChat` via
`Book.isAIFeatureEnabled` (master toggle, provider + key, the flag, any
per-book override): `BTRChatViewModel.make(...)` returns `nil` and
`isAvailable(for:modelContext:)` hides the BTR entry point in every mode when
it's off.

(Replaces the old BTR menu — a fixed menu of entity chips, "summarize since
start of chapter", comprehension checks and Q&A — on 2026-11-04. Those
questions are now just things you can ask; the chat offers a few as starter
suggestions.)

#### 6.6.1 Activation, per mode

Unchanged from the BTR menu — the BTR icon simply opens the chat:

- **RSVP**: long-press the current word → tooltip with **Define**,
  **View Surrounding**, **Save Quote** and **BTR**.
  - *Define* → `UIReferenceLibraryViewController` (see decision log, §10) —
    the system "Look Up" panel, no new dependency, offline.
  - *View Surrounding* → a modal presenting `NormalReadingView` (the same
    component from §6.5, reused, not reimplemented) in scrolling mode,
    centered on the current locator.
- **Guided Reading**: while paused, long-press a word → the same tooltip;
  selecting more than one word swaps *Define* for **Save Quote** (§2.11); the
  BTR icon is available at any selection size.
- **Normal**: native WebView text selection, with **Save Quote** and **BTR**
  appended as custom `EditingAction`s.

Each mode keeps the open `BTRChatViewModel` for as long as the full-screen
cover is shown, so a re-render of the reading view can't reset the
conversation.

#### 6.6.2 The chat screen

Full-screen cover, title "BTR Chat", back arrow top left (returns to the
reading mode exactly as paused as it was).

1. **Passage strip** (top): the word the chat was opened from plus the
   **10 words before and 10 after**, laid out like text (`FlowLayout`). Each
   word is a tappable chip; the anchor word(s) start selected. Tapping toggles
   a word's selection, so the reader can point the question at a name or
   phrase ("who is *she*?"). For a Guided/Normal multi-word selection, the
   whole selection is the anchor (capped at 30 words). Built by
   `BTRContextWords` from the anchor's `WordStream`: the anchor run is the
   occurrence of the selection's words nearest its progression estimate, and
   punctuation is restored from each word segment's `text.after`. A caption
   explains selection, and says when earlier books in a collection are being
   drawn on.
2. **Conversation**: reader messages right-aligned; replies left-aligned and
   rendered as **Markdown** (`MarkdownText`). While a reply is pending, its
   bubble shows a spinner and the agent's status ("Reading "Book One"…",
   "Searching what you've read…", "Thinking…"). Failed replies show the error
   and **Try Again**. Empty state: a one-line explanation plus starter
   suggestions ("Summarize this chapter so far", "Who are the main characters
   so far?", "What does this passage mean?").
3. **Input bar**: multi-line text field + send button.

The conversation lives only as long as the chat is open; it isn't persisted.

#### 6.6.3 The context agent — spoiler-free, across a collection

`BTRChatContextAgent` gathers the book text each question is answered from.
**What it may read** (the spoiler rule):

| Book | Readable text |
|---|---|
| Earlier in any collection the open book is in (`Book.earlierBooksInCollections`, §2.12) | the whole book |
| The open book | from the start up to the anchor position the chat was opened at |
| Later in a collection, or in no shared collection | nothing |

Text comes from `BTRBookTextExtractor`: each readable resource walked through
the Content API (`BTRChapterTextExtractor.textPieces`), as paragraph-level
`BTRTextPassage`s labelled with their TOC chapter title. Earlier books are
opened on demand with `PublicationLoader`; their full text is kept in an
in-memory `BTRBookTextCache` (8 books) since it never changes. The open book's
text is extracted once per chat session. An earlier book that can't be opened
is skipped and left out of the system prompt.

**How much it sends:**

- **≤ 400k characters (~100k tokens) readable in total** → everything, grouped
  under book and chapter headers. This is the common case (one book, or a
  short series) and needs no planning call — dev.md §3's "just pass the text".
- **More than that** (a long series) → two steps:
  1. *Plan*: one `generateText` call with `.json(schema:)`
     (`PromptBuilder.retrievalPlanPrompt`) — the question, the selected words,
     the last few chat turns and the book titles, but **no book text** —
     returns up to 8 `searchTerms`. If planning fails, terms fall back to the
     selection and the question's longer non-filler words.
  2. *Retrieve*: score every readable paragraph outside the recent window by
     whole-word term hits (multi-word terms weigh more), and take the best
     paragraphs, each with the one before it, up to 80k characters; always add
     the open book's most recent 60k characters before the reader's position.
     Output keeps reading order, with `[…]` marking gaps.

  The search only ever runs over readable text, so even a search term the
  model drew from its own knowledge of the series can't surface a spoiler.

#### 6.6.4 Prompts

- **System prompt** (`PromptBuilder.chatSystemPrompt`, sent as Gemini's
  `systemInstruction`): BTR's role; what the reader has read (earlier titles in
  order, the current book up to their position); the spoiler rules (answer only
  from the excerpts, no outside knowledge of these books' plots, never hint at
  anything later, say plainly when they haven't got there yet or the excerpts
  don't say); and **formatting**: GitHub-flavored Markdown, `**bold**` names,
  short paragraphs, lists for several points, `###` headings only for longer
  answers, `>` blockquotes for short quotes, no wrapping code fence.
- **Each question** (`PromptBuilder.chatTurn`): the excerpts, the passage the
  chat was opened from and the selected words, then the question. Earlier turns
  go along as plain question/answer messages (last 10 messages); only the
  newest turn carries excerpts, so history stays cheap.
- Prompts are deliberately general for now; question-specific prompts come
  later.

#### 6.6.5 Markdown rendering

`MarkdownText` (DesignSystem/) parses replies into blocks with a small
`MarkdownParser` — headings, paragraphs, bullet and numbered lists (nested by
indent), blockquotes, fenced code, tables, dividers — and styles each block's
inline text (bold, italic, code, links, strikethrough) with Foundation's
`AttributedString(markdown:)`. No third-party dependency. Replies are
text-selectable. A reply the model wrapped in a ```markdown fence is unwrapped
before display.

---

## 7. Persistence & caching

- **SwiftData schema**: `Book`, `AppSettings`, `SavedQuote`,
  `BookCollection`, `CollectionEntry` as `@Model` types, listed once in
  `AppSchema.models` (used by the app, previews and tests); everything else in
  §2 is an embedded `Codable` struct.
- **Book files**: `<Application Support>/Books/<uuid>.epub` +
  `<uuid>-cover.jpg` (§5.3) — included in default iCloud backup, not exposed
  via Files app.
- **Parsed `Publication`/`WordStream` caching**: intentionally *not*
  persisted to disk for MVP. Re-parsing on demand is fast (proven in the
  phase-1/2 spikes — sub-second for a full novel), so the added complexity of
  a resource-level on-disk cache isn't justified yet. Revisit only if a real
  (large) book proves this wrong.
- **Schema migrations**: still SwiftData's automatic lightweight migration
  (adding/removing models and optional or defaulted properties). The
  2026-11-04 change — dropping `ChapterSummary`/`EntityProfile`/
  `ComprehensionCheck`, adding collections — was verified by installing over a
  store written by the previous build. Codable enums inside stored values are
  the sharp edge: a removed case makes old rows fail to decode, so retired raw
  values stay decodable (§2.5's legacy keys). Adopt
  `VersionedSchema`/`SchemaMigrationPlan` once a change needs more than that.

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
- **BTR chat context "agent"**: a fixed pipeline, not a tool-calling LLM loop
  — send all readable text when it fits; otherwise one planning call for
  search terms, then local keyword retrieval (§6.6.3). Predictable
  cost/latency and spoiler-safe by construction (the model never chooses what
  text it may see). Revisit with embeddings or tool calls only if keyword
  retrieval proves too weak on long series.
- **Markdown rendering**: in-house block parser + `AttributedString` for
  inline styling, over a package like MarkdownUI — small, testable, and covers
  what chat replies use.

## 10. Other decisions made by judgment call (flagged for visibility, not blocking)

- **`BookSettingsOverride` is category-level, not field-level** (§2.5): the
  first per-book settings edit clones the full effective `ReaderSettings`
  rather than tracking individual overridden fields. Simpler data model,
  matches how `Book.themeOverride` already behaves; the cost is a full clone
  on first edit instead of a sparse diff, which is irrelevant at this data
  size.
- **`BookSettingsOverride`/`ReaderTheme` are embedded structs, not
  `@Relationship` models** (§2.1): they're inherently 1:1 with their owning
  `Book` and never queried independently, unlike `SavedQuote`/
  `CollectionEntry`, which are true collections.
- **"Chapter" == Readium spine item/resource** for text extraction; the BTR
  chat labels passages with the TOC title for that resource where one exists
  (resources missing from the TOC inherit the previous title).
- **The BTR chat's passage strip is resource-clamped**: near the start or end
  of a resource it's simply shorter rather than pulling words from an
  adjacent `WordStream`.
- **Collections are many-to-many** (a book can be in a series and a broader
  "universe" collection at once), and a book in a collection still shows in
  the library on its own — collections are views onto the library, like
  playlists, not folders.
- **Guided Reading's pacing unit is `wordsPerMinute`**, mirroring RSVP,
  rather than a separate "lines per minute" concept — one mental model for
  speed across both timed modes.
