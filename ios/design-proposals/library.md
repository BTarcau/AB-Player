# Library: telling audiobooks and read-aloud books apart

Scope: the library screen and everything around it: kind distinction, rows, shelf pills, series, sort, search, mini player, empty state and the **+** add flow. The players and Settings are covered in `players.md` and `settings-and-flows.md`.

Two words used throughout this document, and proposed for the app:

- **Audiobook**: recorded audio files, played by the audiobook player.
- **Book** (or **Read-aloud book** where it needs spelling out): an EPUB or PDF that a voice (Kokoro or the iPhone voice) reads in the reader.

The verbs follow from these: you **Listen** to an audiobook and **Read** a book (the reader shows the text *and* speaks it, so "Read" is accurate and stays short). These words come back in the pills, rows, mini player, context menu and add menu so that the user learns them once.

---

## 1. What's wrong today

Seen on a test library in the iPhone 17 Pro Max simulator (two short `say`-generated audiobook folders, three *Kingdom* EPUBs and one PDF). **Screenshot 1, the library at launch:** the "All" pill selected; two audiobook rows with gradient initials tiles ("JD", "TR"), subtitle `<1m · 3 chapters` and no icon; then a "Kingdom · 3 books" series section whose rows show cropped square covers, a tiny outline book glyph and `Start · about 4h 17m · 23 chapters`, plus a `#1` capsule. Nothing on screen says "audiobook" or "read aloud". The only differences are the 11-pt glyph, the word "Start" and the word "about".

### A. Kind is barely signalled

| # | Problem | Where |
|---|---|---|
| A1 | The **only** visual difference between kinds is a `.caption`, `.secondary` SF Symbol (`book` / `doc.richtext`) on the third line, and only for books. Audiobooks have no mark at all, so the user has to notice that an icon is *missing*. The same row puts `speaker.wave.2.fill` (current) and `link` (linked) next to it at the same size and colour, so three unrelated glyphs compete. | `LibraryView.swift:414-421` |
| A2 | The book glyph `book` is also the icon of "Add EPUB or PDF" and close to `books.vertical` (Shelves, empty state). The icon means three different things. | `LibraryView.swift:287, 321`, `:170` |
| A3 | Covers are cropped to a square for both kinds. EPUB covers are portrait, so they lose their top and bottom (in the screenshot "KINGDOM'S DAWN" is cut through the lettering). This also throws away the most natural cue there is: audiobook art is square, book covers are tall. | `Components.swift:30-31` |
| A4 | The fallback tile is the same gradient-and-initials for both kinds, and falls back to "♪" (a music note) for books with no letters. | `Components.swift:16-27, 45` |
| A5 | The subtitles are written differently for each kind in ways that don't explain *why*: books say `Start · about 4h 17m · 23 chapters`, audiobooks say `4h 17m · 23 chapters`. Finished books say `Finished · tap to read again`, finished audiobooks say `Finished`. Nowhere does it say what will speak (narrator vs Kokoro voice). | `Components.swift:62-84` |
| A6 | The book's time estimate uses the global reader speed (`rd.speed`) and an average seconds-per-character figure, but it looks just like the audiobook's exact duration apart from "about". In progress, both kinds read `37% · … · 2h 10m left`, with nothing to say that one is an estimate. | `Components.swift:64, 72` |
| A7 | The context menu's first item is "Play" or "Read Aloud", both with `play.fill`. Tapping a row does something different for each kind: audiobooks open a **sheet** (`PlayerView`), books open a **full-screen cover** (`ReaderView`), and only the context menu starts playback straight away. Nothing on the row says which will happen. | `LibraryView.swift:302-310, 336-346, 139-140` |

### B. Filters and wording assume audio

| # | Problem | Where |
|---|---|---|
| B1 | The **Listening** pill means "in progress" for both kinds, so a half-read EPUB sits under "Listening". This is the biggest source of the "ambiguous" feeling: the app's main filter word belongs to one kind. | `LibraryView.swift:48, 223` |
| B2 | Status pills (All / Listening / New / Finished) and user shelves (Christian, Biography…) share one scrolling row in the same style, with Finished placed *after* the shelves. Status and genre are different axes, and on a phone the shelves push Finished off-screen (in the screenshot "Biography" is already cut off). There's no way to filter by kind. | `LibraryView.swift:219-236` |
| B3 | Sort says **"Recently played"**, which doesn't fit a book being read. | `LibraryView.swift:16` |
| B4 | The search prompt **"Title, author, narrator or series"** offers narrator, which books never have, and there's no way to search by kind or format ("pdf"). | `LibraryView.swift:215, 56-58` |
| B5 | The navigation title is "Lamplight", the app's name, not the screen's. With a kind filter it can say what you're looking at ("Audiobooks", "Books"). | `LibraryView.swift:126` |

### C. Series, shelves and tags

| # | Problem | Where |
|---|---|---|
| C1 | The series tag (`#1`), shelf tags and the "current" state all use the same accent-tinted capsule, so a row can carry `#2 · Christian · Sci-fi` with no hierarchy. | `LibraryView.swift:425-435` |
| C2 | Series grouping is good (and mixes kinds, which is right: someone may own book 1 as audio and book 2 as an EPUB), but the series header doesn't say how the series is held ("2 audiobooks · 1 book"), and the rows inside still look the same. | `LibraryView.swift:190-200` |
| C3 | Series grouping applies under every sort, so with "Recently added" a series is still pulled together, at its most recent member's place. That's fine for "Recent", surprising for "Title". | `LibraryView.swift:93-118` |

### D. Mini player

| # | Problem | Where |
|---|---|---|
| D1 | Only one mini player is shown. If an audiobook *and* a book are both open, the one not last opened has no way back from the library except finding its row. | `LibraryView.swift:120-133` |
| D2 | The two minis look identical (cover, chapter title, book title, two buttons) but the left button differs: the audio mini has **Back 15 s** (`gobackward.15`), the reader mini has **Previous** (`backward.fill`, which jumps a sentence/paragraph). Same place, different meaning, no label. | `LibraryView.swift:486-489`, `Components.swift:143` |
| D3 | Neither mini says which kind is playing or, for books, which voice is reading. | same |

### E. Adding books

| # | Problem | Where |
|---|---|---|
| E1 | The **+** menu is organised by *storage* (linked vs copied) rather than by *what you're adding*. "Add EPUB or PDF" sits in the "Always available offline" section between two audio-copy items; the user has to know that EPUBs are always copied. | `LibraryView.swift:280-297` |
| E2 | **Link Folders** silently copies any EPUB/PDF it finds in the picked folder (books are "always copied in"). Its own footer says "Nothing is copied." | `Library.swift:180-201`, `LibraryView.swift:284` |
| E3 | The menu's label is "Add Book", and "Copy Audio Files into App" adds *one* book from many files; these are not explained in the menu. | `LibraryView.swift:289, 296` |
| E4 | **Other Ways to Add Books** (`HowToAddView`) is written only for audio: the Files-folder section says "audiobook folders (or single M4B/MP3 files)", "From other apps" says "Share an audio file", and Formats lists only audio formats. EPUB, PDF and the watched folder (which lives in Settings › Library) aren't mentioned. | `SettingsViews.swift:55-80` |
| E5 | The empty state is one long paragraph covering both kinds plus linking vs copying, followed by four buttons of nearly equal weight. A first-time user has to understand storage before they've added anything. | `LibraryView.swift:169-178` |
| E6 | The watched folder (an add method) is only reachable from Settings. | `TextLibrary.swift:113-150` |

### Side observation (importer, not library UI)

The test folders `Jane Doe - The Quiet Harbor` have album tags "The Quiet Harbor", yet the rows are titled **"Jane Doe - The Quiet Harbor"** while author shows "Jane Doe", so the author appears twice. Worth a look in `Importer.swift` (folder-name parsing vs tags when imported from the Files folder). Out of scope here.

---

## 2. Recommended design

Four ideas, each small on its own:

1. **One library, with a kind switch at the top**: `All · Audiobooks · Books`. One list keeps series, search, sort and "continue" working across kinds; the switch gives people who think in one kind at a time a clean view.
2. **Each row says its kind in words and in shape**: square covers with a headphones badge for audiobooks; tall (2:3) covers with a speech badge for books; and a kind line in plain words ("Audiobook · Narrated by …" / "Book · Read by Heart (Kokoro)").
3. **Status words that fit both kinds**: "In Progress" instead of "Listening"; "Not Started" instead of "New"; the action verbs Listen / Read appear on the row's button.
4. **Add by kind**: the **+** menu asks "what are you adding?" first, then "link or copy?" only for audio, where it matters.

### 2.1 Library screen

```
┌──────────────────────────────────────────┐
│ ⚙︎                                ⇅   +   │
│ Library                                  │
│ ┌──────────────────────────────────────┐ │
│ │  All  │ Audiobooks │  Books           │ │  ← segmented Picker (kind)
│ └──────────────────────────────────────┘ │
│ (In Progress) (Not Started) (Finished) │ ▾Shelves │   ← status chips + shelf menu
│                                          │
│ CONTINUE                                 │  ← only when ≥1 in progress, under "All"/kind
│ ┌──────────────┐ ┌──────────────┐        │     horizontal cards, most recent first
│ │ ┌────┐       │ │ ┌──┐         │        │
│ │ │ 🎧 │ Night │ │ │📖│ Kingdom's│        │
│ │ └────┘ Train │ │ │  │ Dawn     │        │
│ │ Ch 2 · 12m left│ │ └──┘ 37% · ≈2h left│ │
│ │ [▶︎ Listen]    │ │ [▶︎ Read]        │    │
│ └──────────────┘ └──────────────┘        │
│                                          │
│ ┌──────────────────────────────────────┐ │
│ │ ┌────┐ The Quiet Harbor              │ │
│ │ │ JD │ Jane Doe                      │ │
│ │ │  🎧│ 🎧 Audiobook · 3h 12m · 14 ch  │ │  ← kind line (secondary, with lamp-green glyph)
│ │ └────┘                         ( ▶︎ ) │ │  ← trailing circular Listen button
│ │────────────────────────────────────── │ │
│ │ ┌──┐   Power Healing                 │ │
│ │ │  │   John Wimber                   │ │
│ │ │ 📖│   📖 Book · PDF · ≈6h · 31 ch     │ │
│ │ └──┘                           ( ▶︎ ) │ │
│ └──────────────────────────────────────┘ │
│                                          │
│ KINGDOM                  2 books · 1 🎧   │  ← series header counts by kind
│ ┌──────────────────────────────────────┐ │
│ │ ┌──┐ 1  Kingdom's Dawn               │ │  ← series number moves to a leading numeral
│ │ │  │    Chuck Black                  │ │
│ │ └──┘    📖 Book · 37% · ≈2h 40m left  │ │
│ │         ▬▬▬▬▬▬───────────            │ │
│ │ ┌──┐ 2  Kingdom's Hope               │ │
│ │ ...                                  │ │
│ └──────────────────────────────────────┘ │
│  Christian · Sci-fi   (shelf names shown │
│  as plain secondary text, not capsules)  │
│                                          │
│╭────────────────────────────────────────╮│
││┌──┐ 📖 READING · Heart                  ││  ← mini player with kind eyebrow
│││  │ Chapter 4 · Kingdom's Dawn  ⟲S  ▶︎ ││  ← ⟲S = previous sentence, labelled
││└──┘ ▬▬▬▬▬▬▬───────          ⇅ Night Train││  ← "switch" chip when the other kind is open
│╰────────────────────────────────────────╯│
│  🔍 Search titles, authors, series        │
└──────────────────────────────────────────┘
```

#### Kind switch

- `Picker("Show", selection: $kind) { Text("All"); Text("Audiobooks"); Text("Books") }.pickerStyle(.segmented)`, stored in `@AppStorage("libraryKind")`, placed as the first List row (like the pills today) so it scrolls away with the title.
- Navigation title follows it: **Library** / **Audiobooks** / **Books**.
- The segment shows only when the library has both kinds; someone with only audiobooks never sees it.

#### Status chips and shelves (replacing the pill row)

- Status: **In Progress**, **Not Started**, **Finished**, as toggle chips; tap the selected one again to clear (meaning "all statuses"). "All" is gone from this row because the kind switch already has "All". Wording works for both kinds; "Listening" and "New" are retired.
- Shelves move into one chip: **Shelves ▾**, a `Menu` listing each shelf with a checkmark plus "Edit Shelves…". When a shelf is chosen the chip reads its name ("Christian ✕"). This keeps the row to four chips that fit on a 6.1" screen, and separates "how far along" from "what genre".
- Empty results keep today's footer but with filter-aware text: "No books in progress. Start one from Not Started." / "Nothing on Christian yet. Long-press a book and choose Shelves."

#### Continue section

- A horizontal `ScrollView` of up to 6 in-progress items, newest first, shown when no status chip is selected and search is empty. Respects the kind switch.
- Each card: cover in its kind's shape, title, position (`Ch 2 · 12m left` for audio, `37% · ≈2h left` for books) and a filled button **Listen** or **Read** that resumes and starts playback directly (today only the context menu does this).
- Solves "what was I on?" for people who have one of each going.

#### Row

```
[cover]  Title (headline, 2 lines)
         Author (subheadline, secondary)
         [glyph] Kind · detail · detail          ← caption, secondary; glyph in lamp green
         ▬▬▬▬▬▬▬────────── (only when started)
         Shelf, Shelf (caption2, tertiary)       ← plain text, no capsules
                                         (▶︎)    ← trailing 32-pt circular button
```

- **Cover shape**: `CoverView` gets an `aspect` from the kind: 1:1 for audiobooks, 2:3 for books (same height, 60 pt, so books are 40 pt wide). Rows stay aligned by giving the cover column a fixed 60-pt width and centring. Fallback tiles: audio keeps the gradient with initials; books get a "paper" tile (`ReaderPalette.paper2` with a `lampDark` spine stripe and serif initials) so a coverless EPUB still looks like a book.
- **Corner badge** on the cover (bottom-trailing, 18 pt circle, `.regularMaterial`): **`headphones`** for audiobooks, **`text.book.closed`** for books (the same two glyphs are used in the kind line, context menu and mini player). The badge sits on the art so the kind is readable even with the kind line truncated.
- **Kind line** (all words, no ambiguous verbs):
  - Audiobook, not started: `🎧 Audiobook · 3h 12m · 14 chapters`
  - Audiobook, in progress: `🎧 Audiobook · Ch 6 of 14 · 1h 40m left`
  - Audiobook with narrator, not started: `🎧 Audiobook · Read by Kate Reading · 3h 12m`
  - Book, not started: `📖 Book · EPUB · ≈4h 17m · 23 chapters`
  - Book, in progress: `📖 Book · 37% · ≈2h 40m left`
  - Finished (either): `✓ Finished · Audiobook` / `✓ Finished · Book` (the checkmark replaces the kind glyph; the progress bar is hidden rather than drawn full in green)
  - "≈" (not "about") marks every estimate. "Start ·" and "tap to read again" are dropped: the trailing button says what tapping does.
  - Linked folders add `· Linked` at the end of the kind line instead of a separate `link` glyph. iCloud items not downloaded could later add `· In iCloud`.
- **Trailing button**: a 32-pt circle with `play.fill` (or `pause.fill` / animated waveform when this is the playing book; this replaces the `speaker.wave.2.fill` in the meta line). Accessibility label "Listen to The Quiet Harbor" / "Read Kingdom's Dawn aloud". Tapping the button resumes playback without opening the player; tapping the row opens the player or reader as today.
- **Series rows**: drop the `#2` capsule; show the number as a leading secondary numeral before the cover column (as Apple Books does in series views). Outside a series group, the series goes into the author line: `Chuck Black · Kingdom #2`.
- **Shelves**: plain `caption2`, `.tertiary` text joined with " · ". Shelves are for filtering, not for decoration on every row.

#### Series header

`KINGDOM` (headline) and trailing `3 books · 1 finished`; when the series mixes kinds: `2 books · 1 audiobook`. Tapping the header (later) could collapse it.

#### Sort

Menu: **Recent** (label "Recently opened"), **Title**, **Author**, **Date Added**. "Group Series" moves from Settings into this same menu as a toggle, next to the thing it affects. When sort is Title or Author, series still group but sit where the *series name* sorts.

#### Search

Prompt: **"Titles, authors, series"**. Also match narrator (audio) and format words: typing "pdf", "epub" or "audiobook" filters by kind. Optional `searchScopes` (`All / Audiobooks / Books`) mirroring the kind switch, so searching inside "Books" stays inside books.

#### Mini player

- One bar, with an **eyebrow** line above the title: `🎧 LISTENING · 1.25×` for audio, `📖 READING · Heart` (the Kokoro voice name, from `friendlyVoiceName`) for books. Eyebrow uses `brass` in caption2 small caps, giving each kind its own word in the place people look most.
- Left button gets the same meaning in both: **back** (`gobackward.15` for audio, `backward.end` "Previous sentence" for books, with an accessibility label and, at large Dynamic Type, visible text).
- When **both** an audiobook and a book are open, the bar shows the most recently used one and a small trailing chip `⇅ Night Train` (cover thumbnail + "Switch"). Tapping it swaps the bar (and pauses neither: they already pause each other when one starts). This removes the dead-end in D1.
- Keep the hard-coded toast offset in sync (`LibraryView.swift:136`) or move the toast into the same `safeAreaInset`.

### 2.2 Add flow

**+** opens a `Menu` with the kind first:

```
┌─────────────────────────────────────┐
│ ADD AN AUDIOBOOK                    │
│ 🔗 Link a Folder…                   │
│    Plays from iCloud Drive or Files │
│ ⤓ Copy Folders into Lamplight…      │
│ 🎵 Copy Audio Files as One Book…    │
├─────────────────────────────────────┤
│ ADD A BOOK TO READ ALOUD            │
│ 📖 Add EPUB or PDF…                 │
│ 👁 Watch a Folder…                  │  (or "Watching: Books ✓" when set)
├─────────────────────────────────────┤
│ ? More Ways to Add                  │
└─────────────────────────────────────┘
```

- Menu label: **Add** (accessibility "Add audiobooks or books").
- Section headers carry the kind; footers are dropped from the menu (they're cut off on small phones anyway) and the subtitle text goes into each `Button`'s second line (`Button { } label: { Text("Link a Folder…"); Text("Plays from iCloud Drive or Files") }`, which iOS 17 menus render as a subtitle).
- **Link a Folder** finding EPUBs: after import, the toast says so: "Linked 2 audiobooks. Copied 3 books (EPUB and PDF are always copied in)." (Library.swift's import summary.)
- **Copy Audio Files as One Book** says what it does in its name.
- **Watch a Folder…** is the Settings action, surfaced here.
- **More Ways to Add** (`HowToAddView`) gets two top-level groups, **Audiobooks** and **Books (EPUB, PDF)**, each with: + button, Files › On My iPhone › Lamplight, Share/Open in, and Formats. The Books group explains the watched folder and that books are always copied, with chapters from contents/bookmarks.

### 2.3 Empty state

```
        📚
   Your library is empty

  Lamplight plays audiobooks and reads
  EPUB and PDF books aloud on this iPhone.

  ┌─────────────────────────────┐
  │ 🎧  Add an Audiobook         │   ← .borderedProminent (opens the audio submenu: Link / Copy)
  └─────────────────────────────┘
  ┌─────────────────────────────┐
  │ 📖  Add a Book to Read Aloud │   ← .bordered (opens the EPUB/PDF picker)
  └─────────────────────────────┘
        More ways to add
```

"Add an Audiobook" is a `Menu` with "Link a Folder (plays from where it is)" and "Copy into Lamplight". The storage explanation moves into those items instead of the description paragraph.

Per-kind empty states when the kind switch is on one kind with nothing in it: "No audiobooks yet" + **Add an Audiobook**; "No books yet" + **Add EPUB or PDF**.

### 2.4 Colour

Use the existing palette rather than new colours: kind glyphs and the trailing play button in `lamp` (the accent colour already matches `lamp`), the mini player eyebrow and series numerals in `brass`, book fallback tiles in `paper2`/`lampDark`. Don't colour-code the two kinds with two different hues: it would clash with covers and fail for colour-blind users. Shape (square vs tall) plus words carry the distinction.

---

## 3. Alternatives considered

### 3a. Two tabs (`TabView`: Audiobooks | Books) — not chosen

The cleanest separation, but it splits things that are better together: a series owned partly as audio and partly as EPUB, one search, one Continue row, one mini player, and "what was I last on?" for someone who listens in the car and reads in bed. It also costs a whole extra screen hierarchy (each tab needs its own toolbar, sort, add). The segmented kind switch gives the same "only books" view in one tap without breaking those.

### 3b. Fixed sections in one list ("Audiobooks" header, then "Books") — not chosen

Simple to build, but it breaks "Recently opened" sorting (your current EPUB sinks below every audiobook) and series that mix kinds would have to split. Worse with large libraries: the second section is a long scroll away.

### 3c. Badges only (keep everything, add a big "AUDIO" / "READ ALOUD" tag) — partly used

A coloured text tag on every row is loud and repeats on every line of a mostly-one-kind library. The proposal keeps the idea in a quieter form (kind line + cover badge) and relies on cover shape for the at-a-glance part.

### 3d. Grid of covers (Apple Books style) — later option

Square vs tall covers read even better in a grid, and it suits large libraries. But it loses the progress text people use in an audiobook app ("1h 40m left"). Worth offering later as a View option (List / Grid) in the sort menu; not the default.

---

## 4. Prioritised changes

| # | Change | Fixes | Effort |
|---|---|---|---|
| 1 | Rename status filters: "Listening" → **In Progress**, "New" → **Not Started**; sort "Recently played" → **Recently opened**; search prompt → **"Titles, authors, series"**. | B1, B3, B4 | S |
| 2 | Rewrite `bookSubtitle` as the kind line: `Audiobook · …` / `Book · EPUB · …`, "≈" for estimates, drop "Start ·" and "tap to read again", `· Linked` instead of the link glyph. | A1, A5, A6 | S |
| 3 | Restructure the **+** menu by kind (Add an Audiobook / Add a Book to Read Aloud), subtitles in buttons, add **Watch a Folder…**, rename "Copy Audio Files as One Book". | E1, E3, E6 | S |
| 4 | Update `HowToAddView` with a Books section (EPUB/PDF via +, Files folder, Share, watched folder, formats); toast says when Link copied EPUBs. | E2, E4 | S |
| 5 | Kind-shaped covers: `CoverView(aspect:)` 1:1 vs 2:3, fixed 60-pt cover column, paper-style fallback tile for books, cover-corner kind badge. | A3, A4, A1 | M |
| 6 | Kind switch `All · Audiobooks · Books` (segmented, hidden when only one kind exists) + title follows it + per-kind empty states. | B2, B5 | M |
| 7 | Status chips + **Shelves ▾** menu chip, replacing the single mixed pill row. | B2 | M |
| 8 | Trailing Listen/Read play button on rows (resumes without opening the full screen); replaces the `speaker.wave.2.fill` current marker. Same verbs in the context menu ("Listen" / "Read Aloud" with `headphones` / `text.book.closed`). | A7 | M |
| 9 | Mini player eyebrow (`LISTENING · 1.25×` / `READING · Heart`), consistent labelled back button, and the **Switch** chip when both kinds are open. | D1–D3 | M |
| 10 | Series: leading numerals instead of `#n` capsules, shelves as plain text, header counts by kind; "Group Series" toggle in the sort menu. | C1–C3 | S |
| 11 | Empty state with two kind buttons. | E5 | S |
| 12 | **Continue** row of in-progress items with Listen/Read buttons. | at-a-glance "what was I on" | M |
| 13 | Optional grid view (List / Grid in the sort menu). | large libraries | L |

Suggested order: 1–4 in one pass (wording only, same afternoon, already removes most of the ambiguity); then 5 + 8 (rows); then 6–7 (filters); then 9 (with whoever owns `players.md`, since the mini player borders their area); 10–12 as polish.

### Notes for implementers

- Kind comes from `book.isText` (`Models.swift:119`); format from `book.text?.format`. No model change is needed for any of the above except storing the kind filter (`@AppStorage("libraryKind")`).
- The book's reader voice for the kind line / mini eyebrow is global (`ReaderSettings.currentVoice`), not per book; show it in the mini player only, not on every row, until books get a per-book voice.
- `CoverView` is also used by the players (`MiniPlayer`, `ReaderMiniPlayer`, PlayerView); make `aspect` default to today's 1:1 so other screens don't change unless asked.
