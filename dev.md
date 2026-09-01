# ReadBTR — Dev Notes

Living design document. This is not a spec frozen in stone — update it as decisions
get made or reversed. Right now we are in the *discussion* phase: no reading-engine
code has been written yet, just the bare SwiftUI/XcodeGen skeleton.

Status: **Discovery / architecture decisions**
Last updated: 2026-08-12

---

## 1. The pitch

An iOS app for importing your own books (EPUB, PDF, ...) and reading them with a
choice of three guided reading modes, plus optional BYOK AI features layered on top.
Book content and reading itself is local-first — no accounts, no book sync. There
is one deliberate exception: a small optional Supabase-backed companion service for
things a phone can't reliably do on its own while the app is closed (a daily
scheduled push notification). See §8.

## 0. MVP scope (v1 target)

Concrete cut line for a first working version, so "later" ideas don't quietly creep
into v1:

- **Format**: EPUB only. PDF comes later via a simpler text-extraction path (§4.1).
- **Reading modes**: all three (Single Word, Highlighted, Normal).
- **AI**: Google Gemini only, behind a provider-agnostic interface. Features:
  summaries, Q&A, comprehension checks.
- **Cloud companion**: Supabase cron + Edge Function calling Gemini server-side
  for an AI-generated, personalized "daily quote" push (title + progress synced
  for personalization); "where you left off" is a local-only notification (§8) —
  no server round-trip needed for it.
- **Distribution**: personal use / sideloaded via Xcode or personal TestFlight.
  App Store is a "maybe later," not a v1 requirement (§6.4).
- **Visual design**: bubbly-modern, animated/flowy app chrome in Catppuccin;
  reader surface themed independently and highly customizable (§10).

## 2. The three reading modes

All three modes should operate on the *same underlying book position* so a user can
switch modes mid-book without losing their place. That shared position (chapter +
offset, or similar) is one of the more important shared abstractions to get right
early — see §5.

### 2.1 Single Word (RSVP)
- One word, centered on screen, at a time.
- WPM adjustable.
- "Smart" timing toggle: longer words / punctuation (commas, sentence ends) get
  extra time on screen. This is the classic RSVP approach (Spritz-style).
- Tap to pause/play.
- Configurable skip increments (5/15/30 words back or forward — user-adjustable,
  not fixed to those three values).

Open sub-questions worth deciding early:
- Optical Recognition Point (ORP) alignment — Spritz-style readers bias the
  word slightly left and highlight/pin one letter so your eye doesn't have to
  hunt for a fixed point. Worth doing from the start since it's cheap and it's
  most of what makes RSVP comfortable at speed.
- Does "smart timing" also slow down at paragraph/chapter boundaries, or only
  at the word level?

### 2.2 Highlighted Reading
- Highlights a line at a time, auto-scrolling, "engaged reading" style
  (karaoke-style progressive highlight).
- Configurable highlight color.
- Configurable speed.

**Implementation status (2026-08-12): built, revised twice — see §9 Phase 4.**
What shipped highlights a real, currently-rendered on-screen *line*, computed
live off the DOM, matching "a line at a time" literally — not the
sentence/phrase `Decoration` approach §4.2/§4.3 originally planned and spiked;
that shipped first, didn't hold up under real use, and was replaced. §4.3 has
the corrected account.

### 2.3 Normal Mode
- Plain reflowing/paginated reading, Kindle-style.
- Standard configuration: font, size, margins, theme (light/dark/sepia), tap zones,
  page-turn vs continuous scroll.

**Implementation status (2026-08-12): built — see §9 Phase 5.** As
anticipated, genuinely simple: Readium's stock `EPUBNavigatorViewController`,
no custom rendering layer, `EPUBPreferences.scroll` toggle (shared with Guided
Reading via `EPUBThemePreferences`) for continuous vs. paginated per
`NormalModeSettings.layout`.

## 3. AI features (BYOK)

- Fully toggle-able from a dedicated settings/config screen — a global kill switch,
  plus per-feature toggles (summaries / Q&A / comprehension checks can each be
  turned off independently).
- User supplies their own API key. Key(s) must live in the **Keychain**, never in
  UserDefaults or plain files.
- **v1 provider: Google Gemini.** Architected behind a provider-agnostic protocol
  (something like `AIProvider` with `summarize`, `answer`, `generateQuiz` methods,
  or a lower-level "send this prompt, get structured output back" primitive) so
  OpenAI/Anthropic/others are a new conforming type later, not a rewrite. Model
  choice/config (model name, temperature, etc.) should live in per-provider config,
  not be hardcoded to Gemini's current model lineup.
- Needs explicit privacy messaging: any AI feature sends book text to a third-party
  API. That should be opt-in and clearly disclosed, not a buried setting.
- **v1 features: summaries, Q&A, comprehension checks.** All three are "grounded in
  the book text" features, which raises a design question worth deciding early:
  - Gemini's context windows are large (millions of tokens on current models),
    which means for a lot of books we can likely just stuff the relevant chapter
    (or even the whole book) directly into the prompt rather than building a
    RAG/embeddings pipeline. Much simpler to build and ship, at the cost of
    sending more tokens per request (the user's own key/cost, given BYOK).
    Worth defaulting to this "just pass the text" approach for v1 and only reaching
    for retrieval/embeddings later if it turns out to be necessary (huge books,
    cost concerns, etc).
  - Summaries: scoped to "this chapter" / "since I last opened the book" / a
    user-selected range.
  - Q&A: scoped to what's been read so far (avoid spoiling ahead — the request
    should only include text up to the reader's current position).
  - Comprehension checks: generate N questions from the just-finished
    chapter/section; results stored locally (SwiftData) so they could feed a
    "review what you've read" feature later.

## 4. Core technical hurdles

### 4.1 EPUB/PDF ingestion → one normalized text model
EPUB (reflowable HTML/CSS in a zip) and PDF (fixed layout) are fundamentally
different beasts. To make all three reading modes work over both formats, we need
an ingestion step that normalizes both into a common internal representation:
an ordered sequence of words/lines/paragraphs with positional metadata (chapter,
offset, maybe original source rect for PDF), independent of how it's rendered.

Build options:
- **Readium Swift Toolkit** (readium/swift-toolkit, EDRLab, actively maintained,
  used by production reading apps): handles EPUB + PDF (+ CBZ) parsing, has a
  `Publication`/`Locator` model for exactly this "where am I in the book,
  format-independent" problem, and already has word-level highlighting support
  built for its accessibility/TTS read-aloud feature — which is very close to what
  Highlighted Reading mode needs.
- **Roll our own parser**: unzip EPUB, parse OPF/NCX/XHTML ourselves; use PDFKit
  (native) for PDF text extraction. More control, much more work, and we'd be
  re-solving problems Readium has already solved (encodings, malformed EPUBs,
  footnotes, embedded fonts, RTL, etc).

**Decision: Readium, confirmed by spike.** Spiked in `ReadBTRTests/ReadiumSpikeTests.swift`
against a real, imperfect real-world EPUB2 (a Project Gutenberg *Alice's
Adventures in Wonderland*, `ReadBTRTests/Fixtures/alice.epub`), pinned to
`readium/swift-toolkit` 3.11.0 via SPM. All four spike tests pass. Verified,
not assumed:
- Opens the file cleanly via `AssetRetriever` + `PublicationOpener`; correct
  title/language/14-item reading order/16-entry table of contents extracted.
- `publication.content()` walks the whole book as 1065 semantic
  `ContentElement`s (headings, paragraphs, etc.), each with its own `Locator`.
- **Word-level tokenization works, and doesn't need the TTS/audio engine.**
  Running a `TextContentElement` through `makeTextContentTokenizer(...,
  textTokenizerFactory: { makeDefaultTextTokenizer(unit: .word, language:
  $0) })` explodes a paragraph into one segment per word, each carrying its
  own `Locator` — confirming this is a standalone building block usable
  directly for our own RSVP engine, not something bolted onto
  `PublicationSpeechSynthesizer`/AVSpeech.
- **Important nuance found empirically, not in the docs**: word-level
  locators all share the *same* positional anchor (href + CSS selector +
  progression) as their parent paragraph — what's actually distinct per word
  is `locator.text.highlight` (the word itself) plus its before/after context
  snippet, not a character offset. In other words, Readium gives us
  word-level *text + context*, anchored at paragraph granularity, not a
  true random-access per-word position. Fine for RSVP (we materialize our
  own word array up front and drive seeking off our own index, not off
  `locator.locations`) and fine for "resume mid-paragraph" (fuzzy
  text-context matching — the same technique Readium's own TTS highlighting
  relies on), but worth knowing going in so we don't design around a
  per-word locator that doesn't actually exist.
- **`Locator` round-trips through JSON** via its built-in
  `.jsonString()` / `Locator(jsonString:)` (it conforms to
  `JSONValueEncodable`/`JSONValueDecodable`) — exactly the shape we'd store
  in a SwiftData `String` column for reading position (§4.5). One gotcha:
  strict `Locator == Locator` after a round-trip can fail, because
  `JSONSerialization` loses a few bits of precision on the
  `progression`/`totalProgression` `Double` fields (observed:
  `0.012048192771084338` → `0.01204819277108434`). Any "has the position
  actually changed" check needs a tolerance comparison on progression, not
  exact equality — structural fields (href, media type, text) round-trip
  exactly.
- **Integration cost**: depending on just `ReadiumShared` + `ReadiumStreamer`
  still resolves the toolkit's full package graph — 11 packages total,
  including `SQLite.swift`/`SQLCipher`/`CryptoSwift` which only
  `ReadiumLCP` (DRM, out of scope, §4.6) actually needs. First resolve +
  clean build succeeded with zero compile errors on Xcode 16.4 / iOS 17
  target. Not a blocker, just a real weight data point.

Not yet spiked: the `DecorableNavigator`/`Decoration` API that Readium's own
TTS highlighting uses (relevant to §4.2/Highlighted mode) and true line-rect
extraction — both require standing up `ReadiumNavigator`'s WebView, which is
a bigger lift than the Shared/Streamer content model tested here. Tracked as
the next spike phase in §9.

**PDF (later, post-MVP)**: rather than trying to preserve PDF's fixed layout, plan
is to extract plain text (PDFKit's native text extraction) and run it through the
*same* normalized word/line pipeline built for EPUB — i.e. PDFs get reflowed like
EPUB text once ingested, we don't try to replicate original page layout in any of
the three reading modes. This sidesteps most of the fixed-layout/multi-column
headaches in §4.3 at the cost of not preserving the PDF's original visual
formatting. Good enough tradeoff for a personal reading app; revisit if it turns
out badly for a real PDF in practice.

### 4.2 Rendering engine choice
This is the biggest architectural fork, and it's downstream of §4.1. Normal
mode and Highlighted mode are now settled by the phase 2 Navigator spike
(§9); Single Word mode's renderer is still open (it was never really in
question — a WebView is the wrong tool for flashing single centered words at
400+ wpm — but nothing has been built yet):

- **WKWebView-based** (what Readium's own Navigator uses for EPUB): high fidelity
  to embedded CSS/fonts/images, reuses a lot of Readium's built-in
  pagination/TTS-highlight machinery. Weaker for pixel-precise custom RSVP
  rendering (webview isn't really where you want to be flashing single words at
  400+ wpm) and for fully custom highlight-scroll animation timing.
- **Custom TextKit 2 renderer**: parse the normalized text model into
  `AttributedString`, lay out with `NSTextLayoutManager` ourselves. Full control
  over line rects, word boundaries, and pagination — at the cost of
  building/maintaining a renderer instead of using one. Now only needed for
  Single Word mode (see below).
- **Decision, confirmed by spike**: Readium's `EPUBNavigatorViewController`
  (WebView-based) handles **both** Normal mode and Highlighted mode. Custom
  TextKit rendering is only needed for Single Word mode. Verified in
  `ReadBTR/Spike/ReadiumNavigatorSpikeView.swift` +
  `ReadBTRUITests/ReadiumNavigatorSpikeUITests.swift`: opened the same
  `alice.epub` fixture in a real `EPUBNavigatorViewController`, located the
  opening sentence of Chapter I via the phase-1 Content API, tokenized it to
  sentence granularity, applied it as a `Decoration` (`.highlight(tint:
  .systemYellow)`) via `DecorableNavigator.apply(decorations:in:)`, and
  captured a simulator screenshot. Result: the whole sentence highlights
  correctly and **wraps naturally across all 6 lines it spans**, exactly like
  a browser rendering a `<mark>` span — no custom line-rect geometry
  involved anywhere. Practical notes from getting it working:
  - No HTTP server needed. Older Readium docs/examples wire up
    `ReadiumAdapterGCDWebServer` to serve the WebView's content locally; as
    of 3.11.0 that constructor is deprecated with *"The HTTP server is no
    longer needed for the EPUB navigator"* — `EPUBNavigatorViewController(publication:initialLocation:)`
    is enough. One fewer dependency than §9 originally assumed.
  - Under Swift 6 strict concurrency (this project's `SWIFT_VERSION: 6.0`),
    calling Readium's async APIs from `@MainActor` SwiftUI code needs
    `@preconcurrency import ReadiumShared`/`ReadiumStreamer` — Readium's core
    model types (`Publication`, `Asset`, ...) aren't `Sendable`-annotated yet,
    which otherwise hard-errors the moment a result crosses back onto the
    main actor. Worth planning for when this stops being a spike and becomes
    real app code.
  - A `Decoration` is safe to `apply()` before the WebView has finished its
    initial render — the navigator queues it — but for anything time-critical
    (like live highlight-following in Highlighted mode) budget for the
    WebView's own load/render latency, not just network/parse time.

### 4.3 Line-level layout for Highlighted mode
**Reopened after real usage — the original "resolved" conclusion below was
wrong in practice (2026-08-12, §9 Phase 4).** The phase 2 spike concluded
Highlighted mode never needs true line-rect geometry: highlight a *segment*
(sentence) `Locator` via `Decoration` and let the WebView's own CSS wrapping
render it, however many visual lines it spans. That shipped first, and didn't
hold up as "Highlighted Reading" once actually used: a sentence commonly spans
2-3 wrapped lines, all lit up together at once — not the karaoke-style *line*
highlight §2.2 asks for — and `Decoration` + `go(to:)` navigation gave
jump-style scrolling between sentences, not a smooth line-by-line advance.

Rebuilt on real line-rect geometry after all — the paragraph below, originally
written as "why this looked like a hard problem before the spike ran," turned
out to describe the actual final mechanism, not a superseded concern:

Reflowable EPUB text has no fixed "lines" until it's laid out at a specific
font size/width, so line boundaries are computed at render time, off the
*rendered DOM*, not derived from the book's text model ahead of time (the way
`GuidedTextTokenizer`'s sentence/phrase tokenizer — since deleted — did for
the first version). Concretely: `GuidedReadingHighlighter.js`, injected via
`EPUBNavigatorDelegate.navigator(_:setupUserScripts:)`, walks the DOM's text
nodes and calls `Range.getClientRects()` — the exact primitive Readium's own
`decorator.js`/`rect.js` (`getClientRectsNoOverlap`) uses internally to size
its own highlight boxes — then draws its own highlight overlay `<div>` and
drives its own line-to-line auto-scroll (discrete, not continuous — the
highlight sits on one line, then the view scrolls to bring the next line to a
fixed anchor position and stops). None of that goes through `Decoration` or
`go(to:)` anymore; those are narrowed to what they're actually good at —
coarse, whole-resource jumps (chapter select, crossing into the next
resource) — while `locationDidChange`/position persistence keep working
unchanged, since `EPUBSpreadView` tracks position off the WebView's own
`UIScrollView`, indistinguishably from a JS-driven scroll or a user's own.

This is EPUB-only for v1, same as before. Once PDF support lands via the
extract-and-reflow approach (§4.1), it inherits the same reflow-based line
computation as EPUB.

Two real bugs found only by actually running the app (not caught by unit
tests — see §9 Phase 4 for the full account):
- A SwiftUI mounting deadlock: the navigator's view only gets laid out once
  actually mounted, but `GuidedReadingViewModel.loadState` could only reach
  `.ready` *after* that layout happened (`onViewReady`) — and the view was
  only mounted once `loadState == .ready`. Fixed by keeping the navigator
  mounted regardless of `loadState`, overlaying loading/error state on top of
  it instead of switching it out of the view tree.
- ReadiumCSS applies its own broad `!important` background-color reset to
  defeat publisher styles, which was *also* silently discarding our injected
  highlight's plain (non-`!important`) inline `background-color` — the
  element existed with exactly correct geometry, just fully transparent.
  Fixed by setting every highlight style via
  `el.style.setProperty(property, value, "important")` instead of plain
  assignment.

### 4.4 Smooth, accurate timing
RSVP timing at high WPM and highlight auto-scroll both need frame-accurate timing,
not just a repeating `Timer` (which drifts and jitters under load). `CADisplayLink`
or similar is probably necessary once WPM gets high.

### 4.5 Local storage & data model
- Book files: app's local file system (Documents or Application Support), imported
  via the system document picker (Files app / iCloud Drive source, local copy made
  on import).
- Metadata: SwiftData (native for a fresh iOS 17+ SwiftUI project) for library
  entries, per-book reading progress/position, per-book settings overrides
  (e.g. this book's highlight color), and global app settings.
- Reading position needs to be stored as a locator that's meaningful across all
  three modes (see intro of §2) and survives re-import/re-parse.

### 4.6 DRM
No DRM support planned — EPUB/PDF must be DRM-free. Worth stating explicitly
somewhere user-facing so it's not a surprise when an Adobe-DRM'd library book
fails to import.

### 4.7 Accessibility
VoiceOver and rapid-flashing single-word RSVP mode are in tension. Not a blocker,
but worth deciding intentionally (e.g. disable/alter RSVP presentation when
VoiceOver is running) rather than discovering it late.

## 5. Suggested architecture shape (conceptual, not final)

- **Ingestion**: file import + EPUB (later PDF) parsing → normalized `Document`
  model.
- **Text engine**: tokenization, locator model, (re)computed line/word layout.
- **Reading modes**: three SwiftUI feature modules (RSVP, Highlight, Normal), each
  a view + view-model pair, all consuming the text engine and sharing the locator
  model for position.
- **Persistence**: SwiftData — library, book, reading progress, settings.
- **AI**: a small provider-agnostic protocol (Gemini as the first conforming
  type), Keychain-backed key storage, per-feature flags surfaced in a config
  screen.
- **Cloud companion**: thin Supabase client used for push-token registration and
  syncing the minimal "what am I reading" metadata (title + progress) that
  powers personalized, AI-generated daily-quote copy — see §8. Everything else
  stays device-only.
- **Settings/Config**: global settings + the AI on/off screen + notification
  preferences.

## 6. Open questions for Colby

1. ~~Format priority~~ — **answered**: EPUB-first, PDF later via extract-and-reflow.
2. ~~AI provider(s)~~ — **answered**: Gemini first, provider-agnostic interface.
3. ~~First AI feature(s)~~ — **answered**: summaries, Q&A, comprehension checks.
4. ~~Distribution intent~~ — **answered**: personal use to start; paid Apple
   Developer Program membership already in place, so remote push (§8.2) is
   unblocked from day one, not gated on Apple account setup.
5. ~~Readium spike~~ — **answered**: sequenced first, standalone, ahead of app
   shell / SwiftData scaffolding — the ingestion/rendering question is the actual
   first milestone, not parallel work. See §9 for the concrete spike plan.
6. ~~Daily quote source~~ — **answered**: AI-generated (Gemini, called
   server-side from Supabase), personalized to current book + progress. See §8.2
   for the resulting design (server-side key, minimal synced metadata, generation
   cadence).
7. ~~Design reference~~ — **answered**: app chrome is bubbly-modern, animated,
   flowy, themed with Catppuccin. The reader surface itself is explicitly *not*
   locked to that theme — it needs to be highly customizable independent of the
   app shell. See §10.

## 7. Non-goals (for now)

- Book *content* sync, multi-device reading, or a real account/login system.
- DRM'd file support.
- Library/social features (annotations sharing, discovery, etc.) beyond basic
  personal reading.
- Server-side storage of book text/files, or any book text/content leaving the
  device — the Supabase companion (§8) only ever sees small metadata (push
  token, current book title, rough progress), never file contents or extracted
  text.

## 8. Cloud companion service (Supabase)

Everything above is local-first by design. This section is the one deliberate
exception, scoped as narrowly as possible: iOS apps can't reliably run their own
code on a daily schedule while closed (no persistent background process, and
`BGAppRefreshTask` is opportunistic/unreliable, not a real cron), so a "daily
quote" notification needs *something* server-side to trigger it. Supabase (cron +
Edge Functions, generous free tier) is the pick for that.

### 8.1 "Where you left off" — no backend needed
On reflection this doesn't actually need Supabase at all: the device already
knows its own reading position. Plan is a **local notification**
(`UNUserNotificationCenter`, e.g. a daily `UNCalendarNotificationTrigger`)
rescheduled/updated whenever the app is backgrounded, built from purely local
state. No token, no server round-trip, no data leaves the device for this one.

### 8.2 "Daily quote" — the one feature that needs a server
- **Trigger**: Supabase `pg_cron` fires on a schedule (daily, at either a fixed
  UTC time or per-user local time if we store a timezone) and invokes a Supabase
  Edge Function.
- **Content**: AI-generated, not a static list — the Edge Function calls Gemini
  server-side to produce a quote/blurb personalized to the current book +
  progress ("a line to pull you back into Chapter 12 of *Dune*"). This needs its
  own server-side Gemini key living in Supabase as a secret — separate from the
  user's on-device BYOK key used for in-app AI features (§3). Two distinct keys,
  two distinct trust boundaries: the on-device key never leaves the device, the
  Supabase key never touches the device.
- **Synced metadata (the actual privacy trade-off)**: for personalization to
  work, the device has to push current book title + rough progress (e.g.
  chapter/percent) to a small Supabase table whenever it changes. This is the one
  place in the whole app where book-related data leaves the device — scoped
  intentionally to "title + progress," never full text/content. Worth a plainly
  worded privacy note in-app about this, same spirit as the AI-feature disclosure
  in §3.
- **Delivery**: the Edge Function sends a remote push via APNs (HTTP/2 APNs API,
  auth'd with an APNs key, also a Supabase-side secret). Requires the app to
  register for remote notifications (unblocked — paid Apple Developer account
  confirmed, §6.4) and store its device token alongside the book/progress row.
- **Auth**: single-user for now, so no real account system needed — a
  device-scoped identifier plus an insert/update-only anon-key RLS policy for the
  token + book-state row is enough. Worth revisiting if this ever becomes
  multi-user/App-Store-distributed.
- **Generation cadence**: worth deciding later whether the Gemini call happens
  fresh every single day (simplest, but N users × 365 calls/yr against the
  Supabase-side key) or is cached/reused for some window — not a v1 blocker at
  single-user scale, just a cost-shape thing to keep in mind if this ever goes
  multi-user.

## 9. Readium spike plan

Sequenced as the actual first milestone, ahead of app-shell/SwiftData
scaffolding (§6.5) — everything in §4.1/§4.2 (ingestion model, rendering engine
split) is downstream of what this spike finds, so it's not worth scaffolding
around a guess.

### Phase 1 — Shared/Streamer content model: done

Landed in `ReadBTRTests/ReadiumSpikeTests.swift`, fixture at
`ReadBTRTests/Fixtures/alice.epub`. Run with:

```
xcodegen generate
xcodebuild test -project ReadBTR.xcodeproj -scheme ReadBTR \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -skip-testing:ReadBTRUITests
```

Answered, with real findings folded back into §4.1:
- ✅ Word-level addressing — yes, via `Content` + a word-unit
  `ContentTokenizer`, independent of the TTS engine, with the paragraph-anchor
  nuance noted in §4.1.
- ✅ Locator persistence — yes, `Locator` round-trips through JSON natively;
  gotcha on float-precision equality noted in §4.1.
- ✅ Integration cost — resolves 11 packages, zero compile errors against our
  toolchain (Xcode 16.4, iOS 17 target).

### Phase 2 — Navigator/Decoration: done

Landed in `ReadBTR/Spike/ReadiumNavigatorSpikeView.swift` (debug-only screen,
reachable from a "Readium Navigator Spike" button on `ContentView` in DEBUG
builds) and `ReadBTRUITests/ReadiumNavigatorSpikeUITests.swift` (drives to that
screen and captures a screenshot, since this is a visual question a unit test
can't answer on its own). `ReadiumNavigator` was added to the **app** target's
dependencies in `project.yml` (unlike phase 1's Shared/Streamer, which stayed
test-only — Navigator needs a real screen to render into). Run with:

```
xcodegen generate
xcodebuild test -project ReadBTR.xcodeproj -scheme ReadBTR \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:ReadBTRUITests/ReadiumNavigatorSpikeUITests
# then pull the screenshot attachment out of the resulting .xcresult with
# `xcrun xcresulttool export attachments`
```

Answered, with real findings folded back into §4.2/§4.3:
- ✅ **Highlighted mode does not need a custom TextKit renderer.** Applying a
  sentence-level `Locator` (from phase 1's tokenizer, `.sentence` unit this
  time instead of `.word`) as a `Decoration` via
  `DecorableNavigator.apply(decorations:in:)` renders a correct highlight in
  Readium's stock EPUB `WKWebView` navigator, wrapping naturally across all 6
  lines the sentence spanned in testing — confirmed visually via simulator
  screenshot, not just inferred from source.
- ✅ Normal mode and Highlighted mode both now resolve to "use
  `EPUBNavigatorViewController`" — only Single Word (RSVP) mode still needs a
  from-scratch renderer (custom SwiftUI view, no WebView involved, driven by
  the word+locator stream from phase 1).
- ✅ No HTTP server dependency needed — `ReadiumAdapterGCDWebServer` (assumed
  necessary when this phase was planned) turned out to be unneeded as of
  toolkit 3.11.0; that constructor path is deprecated upstream.
- 📝 Real integration friction found running the app target under this
  project's Swift 6 strict concurrency setting: Readium's core model types
  aren't `Sendable` yet, so consuming them from `@MainActor` SwiftUI code
  needs `@preconcurrency import ReadiumShared`/`ReadiumStreamer`. Worth
  carrying into real (non-spike) integration.

### Phase 3 — done

- ✅ Real Single Word (RSVP) renderer built — a plain SwiftUI view
  (`RSVPView`/`RSVPViewModel`), no Readium Navigator involved, driven by the
  phase-1 word+locator stream (`WordStream`/`WordStreamCache`).
- ✅ `NavigatorDelegate.navigator(_:locationDidChange:)` +
  `Locator.jsonString()`/`Locator(jsonString:)` wired into real SwiftData
  persistence (`Book.updatePosition(from:)`), used by RSVP, Guided Reading,
  and Normal reading alike.
- ❌→✅ **"Decide phrase- vs. sentence-level granularity for Highlighted
  mode's default"** — overtaken by events: neither. Phase 4 replaced
  sentence/phrase segmentation with real per-line highlighting, so there's no
  granularity choice left to make (or to expose as a setting) — see §4.3 and
  Phase 4 below.
- PDF (out of MVP scope, §0) and visual/theming work beyond the reader-surface
  pieces already needed for §10.2 remain out of scope.

### Phase 4 — Guided Reading, real implementation: done, revised once

**First pass (built, then replaced):** sentence/phrase `Decoration`-based
highlighting, exactly as the phase 2 spike concluded — `GuidedTextTokenizer`
(word-stream-derived sentence/phrase segments), `GuidedSegmentStream`/
`GuidedSegmentStreamCache`/`GuidedSegmentPositionResolver` (mirroring RSVP's
`WordStream` family), applied via `DecorableNavigator.apply(decorations:in:)`
and navigated between via `go(to:)`. Landed, then explicitly reopened after
real use (not a unit-test finding — see §4.3): a "line" highlight that's
actually a whole sentence, lit up all at once across 2-3 wrapped lines, with
jump-style (not smooth) scroll between them, isn't what "Highlighted Reading"
(§2.2) asks for. All four of those types are now deleted.

**Second pass (current):** real line-rect highlighting, fully custom, built
directly on the rendered DOM rather than approximated from the book's text
model ahead of time — see §4.3 for the technical account of *why*/*how*.
Landed in:
- `ReadBTR/ReadingModes/GuidedReading/Resources/GuidedReadingHighlighter.js`
  — the injected script: line-rect computation (`Range.getClientRects()` +
  binary search per rect to find each line's text boundaries), highlight
  overlay rendering, line-to-line auto-scroll, tap classification
  (on-highlight vs. elsewhere), and a `debugSnapshot()` introspection hook
  (kept, not stripped — see below).
- `GuidedReadingNavigatorController.swift` — hosts
  `EPUBNavigatorViewController`, injects the script + a `WKScriptMessageHandler`
  (behind a weak-proxy wrapper to avoid a `WKUserContentController` retain
  cycle) via `setupUserScripts`, bridges to the JS via `evaluateJavaScript`,
  and reports `onViewReady`/`onViewResized` off `viewDidLayoutSubviews` (see
  the mounting-deadlock bug below).
- `GuidedReadingViewModel.swift` — line-by-line playback/pacing
  (`wordsPerMinute` against each line's own word count, same mental model as
  RSVP), resource-crossing, and paused-manual-scroll re-sync, all driven off
  real lines instead of a precomputed segment stream.
- `GuidedReadingViewModelTests.swift` — needs `ReadiumNavigator` in the
  **test** target's dependencies (added to `project.yml`; the app target
  already had it), and needs a real `UIWindow` stood up around the
  navigator's view before `load()` can settle — Guided Reading is the one
  reading mode whose "ready" state genuinely depends on real on-screen
  layout, so a bare unit-test host process (no window, no real layout pass)
  isn't enough on its own for it the way it is for RSVP/Normal.
- `GuidedReadingViewUITests.swift` — real end-to-end verification, screenshot
  captured via `xcrun xcresulttool export attachments`.

Two real bugs, found only by actually running the app (both detailed in
§4.3's bug list, repeated here for the spike-log record):
1. A SwiftUI mounting deadlock between `loadState` and the navigator's view
   layout. Fixed in `GuidedReadingView.swift` by keeping the navigator
   mounted regardless of `loadState`, instead of switching it out of the
   view tree during `.loading`.
2. ReadiumCSS's own `!important` background-color reset silently defeating a
   plain inline `background-color` on the injected highlight element — found
   by comparing `element.style.*` (what we set) against
   `getComputedStyle(element)` (what actually paints) via a debug JS bridge,
   not visible from geometry alone. Fixed by setting every highlight style
   via `setProperty(property, value, "important")`.

**Debugging method worth recording**, since it's the reason bug 2 was findable
at all: `xcrun simctl spawn <udid> log stream --predicate 'process ==
"ReadBTR"'` running in the background while driving the app via
`xcodebuild test -only-testing:...UITests`, capturing `NSLog` output from a
temporary debug bridge (`GuidedReadingNavigatorController.debugHighlightSnapshot()`
→ `GuidedReadingHighlighter.js`'s `debugSnapshot()`) straight from the real
simulator process — a screenshot alone showed *that* the highlight was
invisible, not *why*. The `debugHighlightSnapshot()` bridge itself was kept
(not stripped after diagnosis) and backs a permanent regression test,
`GuidedReadingViewModelTests.highlightLineActuallyPaintsANonTransparentBackground`,
that asserts computed style directly rather than just inline style.

`GuidedReadingSettings.highlightGranularity` (sentence/phrase) is gone from
the model — "line" isn't a granularity choice, it's the only option now.

### Phase 5 — Normal reading mode: done

Built as design-roadmap.md §6.5/dev.md §2.3 anticipated: genuinely simple,
because it's *just* Readium's stock `EPUBNavigatorViewController` — no
injected JS, no custom highlighting layer, no polling for the WebView to lay
out before anything can proceed. `NormalReadingViewModel.loadState` reaches
`.ready` synchronously once the publication opens and the navigator
constructs, unlike Guided Reading.

- `EPUBThemePreferences.swift` (new, `ReadingEngine/`) — the
  `ReaderTheme` → `EPUBPreferences` mapping factored out of
  `GuidedReadingNavigatorController` and shared with
  `NormalReadingNavigatorController`, so it's not duplicated a third time
  once there are two EPUB-navigator-hosting modes.
- Scrolling vs. paginated is `EPUBPreferences.scroll`, driven directly by
  `NormalModeSettings.layout` — no custom logic needed.
- Toolbar trigger is "tap the top of the screen" (design-roadmap.md §6.5),
  via `VisualNavigatorDelegate.navigator(_:didTapAt:)` checked against a
  fixed top zone (80pt) — the one part of this mode that wasn't quite as
  simple as expected:
  - **Found via UI test, not assumed**: a tap in roughly the top ~2% of the
    screen (~18pt) never reaches `didTapAt` at all — confirmed by temporarily
    widening the tap zone and logging every call, which showed zero calls
    for a near-the-edge tap but a real one for a tap at screen-center. Most
    likely the status bar/Dynamic Island's own touch handling intercepting a
    *synthesized* XCUITest tap specifically (not necessarily a real-finger
    issue) — but the test taps a safer point further down, still well inside
    the 80pt zone, either way.
  - **Hiding the toolbar isn't a second top-tap.** Once visible, the
    navigation bar physically occupies that same top zone and intercepts the
    tap before it ever reaches the WebView — confirmed the same way (zero
    `didTapAt` calls while the bar was shown). Instead, the toolbar hides on
    the next real navigation (scroll/page-turn), mirroring how RSVP/Guided
    Reading auto-hide their own toolbar when playback resumes.

## 10. Visual design & theming

Two separate theming surfaces, deliberately decoupled:

### 10.1 App chrome
Library view, settings, navigation, AI config screen, etc. — "bubbly-modern,"
animated and flowy, built around a **Catppuccin** palette (Latte for light,
one of Frappé/Macchiato/Mocha for dark — worth picking one dark flavor as the
default rather than exposing all three as a v1 option). Implementation notes:
- Catppuccin's palette is just color tokens — cleanest as a Swift enum/struct of
  named colors (or an Asset Catalog with light/dark appearances wired to the
  chosen flavors), not hardcoded hex scattered through views.
- "Animated and flowy" points at SwiftUI's native spring/interpolating
  animations rather than linear/mechanical transitions — worth establishing a
  couple of shared animation presets (e.g. a standard spring for
  navigation/sheet transitions, a gentler one for in-place state changes) early
  so it's consistent across screens rather than tuned per-view.

### 10.2 The reader surface
Explicitly **not** locked to Catppuccin or the app-chrome theme — this needs to
be highly customizable on its own terms, independent of the shell around it
(this is consistent with what §2 already calls for per-mode: highlight color in
§2.2, theme/font/margins in §2.3). Concretely this means the reader's color/font
system should be its own independent settings domain — e.g. a reader could
reasonably be set to a plain white/black "paper" look while the rest of the app
around it is Catppuccin Mocha. Worth designing the reader's theme model
(background, text color, accent/highlight color, font, spacing) as a
self-contained, user-editable value from the start rather than retrofitting it
after building the reading modes.
