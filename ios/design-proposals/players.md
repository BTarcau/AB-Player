# Players: the audiobook player and the book reader

*Design proposal, no code changed. Scope: the two playback screens, the mini player at the bottom of the library, switching between an audiobook and a book, and the lock screen. The library and settings have their own proposals (`library.md`, `settings-and-flows.md`).*

Written from reading the code (paths below are relative to `ios/ABPlayer/`). I didn't run the app for this pass, so the wireframes are drawn from the view code, not from screenshots.

---

## TL;DR

- **One family, two rooms.** Both players get the same layout: a header saying what kind of thing is playing, a middle that's different (the cover, or the text), the same transport row, and the same tool row: **Speed · Sleep · Bookmark · AirPlay · More**. The audiobook player keeps system styling and the reader keeps paper/lamp/brass. Same layout, different look.
- **Every skip button says what it skips.** Seconds in one player, sentence or paragraph in the other, written under the icon. Chapter buttons use the same glyph (`backward.end` / `forward.end`) in both. The reader's current ⏪/⏩ icons (`backward.fill` / `forward.fill`) mean "rewind / fast-forward" everywhere else on iOS, so they go.
- **Close the feature gaps**: a sleep timer, bookmarks and AirPlay in the reader, and per-book speed for both. Both players share one Speed sheet and one sleep timer.
- **One mini player that follows whatever plays.** Today it can show a paused audiobook while a book is still reading aloud. The bar should show the session that owns the lock screen, carry a kind icon (headphones or lines of text), and offer "Switch to …" for the other session.
- **The lock screen tells the truth.** In the reader the "15"/"30" lock-screen skip buttons should go back about 15 s, rounded to whole sentences, not exactly one sentence. The subtitle should say "Read aloud · Heart" or "Narrated by …".

---

## 1. Problems found

### A. Which mode am I in, and what does this button do?

| # | Problem | Where |
|---|---|---|
| A1 | The reader's skip buttons use `backward.fill` / `forward.fill`, the system's rewind/fast-forward glyphs, but they move one sentence or paragraph. The only clue to which unit is the VoiceOver label. Sighted users can't tell sentence from paragraph without going into Settings. | `Reader/ReaderView.swift:158`, `:172`; setting at `Reader/ReaderSettingsViews.swift:38` |
| A2 | The audiobook player's skip buttons (`gobackward.15` / `goforward.30`) move seconds, and its chapter buttons are `backward.end.fill` / `forward.end.fill`. So the same position in the row means seconds in one player and a sentence in the other, with similar-looking icons. | `PlayerView.swift:104-130` vs `Reader/ReaderView.swift:158-173` |
| A3 | The two mini players look identical: same cover, title and capsule. One has a `gobackward.15` button and the other `backward.fill` (labelled just "Previous"). Nothing says "audiobook" or "read aloud". | `LibraryView.swift:469-507`, `Components.swift:128-170` (label at `:145`) |
| A4 | The lock screen in the reader shows the system 15/30-second skip buttons (intervals set from the audiobook settings), but pressing one moves exactly one sentence or paragraph, whatever the interval. The same goes for AirPods double/triple tap and CarPlay. | `Player.swift:490-494`, `Reader/ReaderPlayer.swift:685` |
| A5 | The audiobook header says "Now Playing", which takes space and says nothing. The reader header says "Chapter 3 of 12 · tap for contents". Neither says what kind of book it is. | `PlayerView.swift:91`, `Reader/ReaderView.swift:83` |
| A6 | Different words for the same thing: "Chapters and bookmarks" (audiobook) vs "Contents" (reader). And "Back to library" / chevron.down in a full-screen cover vs "Close player" in a sheet that can also be swiped down. | `PlayerView.swift:96`, `ChaptersView.swift:19-22`, `Reader/ReaderView.swift:76-79`, `LibraryView.swift:139-140` |

### B. Feature gaps

| # | Gap | Where |
|---|---|---|
| B1 | **No sleep timer in the reader.** `SleepMenu` reads `Player` from the environment and `Player` owns the timer, so it can't pause the reader. Read-aloud at bedtime is probably the most common sleep-timer case. | `PlayerView.swift:165-192`, `Player.swift:441-473` |
| B2 | **No bookmarks in the reader.** `Bookmark` only stores a `time`, and `addBookmark` is on `Player`. | `Player.swift:476-481`, `ChaptersView.swift:73-114` |
| B3 | **No AirPlay/route button in the reader**, so you can't pick the car or a speaker from the reading screen. | `PlayerView.swift:151` (audiobook only) |
| B4 | **Speed works differently.** Audiobook: per book, 0.5–3.5×, presets 0.8/1/1.2/1.5/1.75/2, "Saved for this book.", shown as `1.25×`. Reader: global, 0.6–2.0×, presets 0.8/1/1.2/1.5/2, shown with `%.1f×`, so 1.25 shows as "1.2×" and 1.75 as "1.8×". Settings uses `%.2g×`, which drops the last digit the same way. The lock-screen rate menu uses yet another set (0.75–2). | `PlayerView.swift:194-224`, `Player.swift:350`; `Reader/ReaderSheets.swift:203-214`, `Reader/ReaderView.swift:152`, `Reader/ReaderSettingsViews.swift:35`, `Reader/ReaderPlayer.swift:694`; `Reader/RemoteRouter.swift:52` |
| B5 | **The reader shows no whole-book progress.** `positionInfo` already works out `bookFraction` and `bookSecLeft`, but no view uses them. The audiobook player shows "42% · 3 h 10 m left in book". | `Reader/ReaderPlayer.swift:119-131`; `PlayerView.swift:157-162` |
| B6 | The voice can only be changed from the reader (chip) or Settings. Per-book voice isn't possible. That's fine for now, but the chip is the only place you see which voice is reading. | `Reader/ReaderView.swift:175-180` |
| B7 | The audiobook player has no text. That's expected. The reverse gap is that the reader has no "just listening" layout for a phone in a pocket or on a car mount: the controls are small and sit under a wall of text. | `Reader/ReaderView.swift:150-181` |

### C. Switching between an audiobook and a book

| # | Problem | Where |
|---|---|---|
| C1 | **The mini player follows "last opened", not "playing".** `showsReaderMini` uses `lastOpenedText`. `Player.open(_:)` doesn't start playback (no `autoplay` from the library), so it doesn't take over `RemoteRouter`. So: read a book aloud → open an audiobook from the library → close its sheet without pressing play. The book is still reading aloud, but the bar shows the paused audiobook, and the library has nothing that pauses the reader. | `LibraryView.swift:32`, `:120`, `:335-346`; `Player.swift:114-120`; `Reader/RemoteRouter.swift:22-25` |
| C2 | Only one mini player shows even when both sessions are loaded. The hidden one has no way back except finding its row in the library. | `LibraryView.swift:128-133` |
| C3 | Starting one silently pauses the other (`RemoteRouter.activate`). That's correct, but there's no feedback. A toast like "Paused *The Hobbit*" would explain where the audiobook went. | `Reader/RemoteRouter.swift:22-25` |

### D. Lock screen / Now Playing

| # | Problem | Where |
|---|---|---|
| D1 | The reader omits `MPNowPlayingInfoPropertyChapterNumber`/`ChapterCount` and `DefaultPlaybackRate`, which the audiobook sets. | `Reader/ReaderPlayer.swift:660-674` vs `Player.swift:496-517` |
| D2 | Neither lock screen says what kind of playback it is. Artist is the author in both. A synthetic voice reading an EPUB looks the same as a narrated audiobook. | `Reader/ReaderPlayer.swift:665`, `Player.swift:504` |
| D3 | The reader builds a new `MPMediaItemArtwork` from the cover on every chapter change and every jump, including every tap on a sentence. The audiobook caches it by book id. | `Reader/ReaderPlayer.swift:672` vs `Player.swift:513-516` |
| D4 | Lock-screen speed (`changePlaybackRateCommand`) offers 0.75/1/1.25/1.5/1.75/2. That doesn't match either in-app preset list. | `Reader/RemoteRouter.swift:52` |

### E. Other things in each player

| # | Problem | Where |
|---|---|---|
| E1 | The reader's scrubber only acts on `onEnded`. There's no thumb, no live time and no preview while dragging, and a tap anywhere on it jumps. The audiobook has a real `Slider`. | `Reader/ReaderView.swift:128-142` |
| E2 | The reader's speed chip and voice chip both open the same "Voice & speed" sheet. Two targets, one destination. | `Reader/ReaderView.swift:151`, `:175` |
| E3 | The slider icon in the reader's top bar opens the whole app's `SettingsView` (library, backup, audiobook skip intervals…) on top of the book. | `Reader/ReaderView.swift:93-96`, `:67` |
| E4 | The NOW line repeats the sentence that is already highlighted on screen. It earns its space only when you've scrolled away, which is also when the "Back to where it's reading" pill appears. | `Reader/ReaderView.swift:120-125`, `:45-57` |
| E5 | The card's height is hard-coded as `230` in three places (pill padding, text inset, visibility check). It breaks with Dynamic Type or a two-line status. | `Reader/ReaderView.swift:56`, `:230`, `:362` |
| E6 | "Hear the selected voice" pauses reading and doesn't resume it. | `Reader/ReaderSheets.swift:222-224`, `Reader/ReaderPlayer.swift:617-620` |
| E7 | Audiobook: the chapter title isn't tappable (in the reader it opens Contents), and the bookmark button gives no visual feedback beyond a toast. | `PlayerView.swift:29`, `:146` |

---

## 2. Recommended design: one family, two rooms

**Principle:** the controls you use without looking (play, skip, chapter, speed, sleep, AirPlay) are in the **same place with the same meaning** in both players. What's on screen (cover or text) and the look (system or paper) stay different, so you always know which room you're in.

### 2.1 Shared rules

1. **Header = kind + book.** A small capsule on the left says what's playing:
   - Audiobook: `🎧 Audiobook` (SF Symbol `headphones`)
   - Book: `≡ Read aloud` (SF Symbol `text.alignleft`, or `book.pages` on iOS 18+)
   Under it, the book title, then "Chapter 3 of 12". Tapping the title block opens **Contents** in both players.
2. **The transport row is the same in both:**
   `[⏮ chapter]  [↺ back]  [▶︎ play]  [↻ forward]  [⏭ chapter]`
   - Chapter buttons: `backward.end.fill` / `forward.end.fill` in both. The reader gains chapter buttons it doesn't have today.
   - Back/forward: circular arrows in both, **always with a caption under them**:
     - Audiobook: `gobackward.15` / `goforward.30` with captions **"15 s"** / **"30 s"**. The number is already in the glyph; the caption is there so both players look the same.
     - Reader: `arrow.counterclockwise` / `arrow.clockwise` with captions **"Sentence"** / **"Sentence"** (or **"Paragraph"**). Long-press either one for a menu: **Skip by: Sentence ✓ / Paragraph**. The unit is switched right there, not only in Settings.
3. **The tool row is the same in both:** `Speed · Sleep · Bookmark · AirPlay · More (…)`
   - **Speed** uses one shared sheet (§2.4) and is saved per book in both.
   - **Sleep** uses one `SleepTimer` service that pauses whichever player owns `RemoteRouter`. "End of chapter" works in both: the reader stops at the end of its chapter.
   - **Bookmark** adds one at the current place. In the reader that's the current sentence, stored as chapter + sentence, and the label shows the start of the sentence instead of a time.
   - **AirPlay** is `AVRoutePickerView` in both.
   - **More (…)**: Reader: *Voice…*, *Display (Aa)…*, *Skip by ▸*, *Reading settings…*. Audiobook: *Skip intervals…*, *Smart rewind ✓*, *Edit book…*.
4. **Contents** is one sheet layout in both: segmented **Chapters | Bookmarks**, with a search field for text books. Same title ("Contents"), same "current" marker (speaker icon + `glow` row), same "read" / % labels.
5. **Progress line** in both, under the transport: `42% · 3 h 10 m left in book` (reader: "about 3 h 10 m", since it's an estimate).
6. **Look:** the audiobook player stays system-styled but uses Lamplight's lamp-green as its accent tint, so it feels like part of the same app. The reader keeps `ReaderPalette` throughout, including in its sheets.

### 2.2 Audiobook player (sheet)

```
┌───────────────────────────────────────────┐
│ ⌄                ─────                  ≡ │   ⌄ "Close player"   ≡ "Contents"
│  ╭─────────────╮                          │
│  │🎧 Audiobook │                          │   kind capsule (secondary fill)
│  ╰─────────────╯                          │
│        ┌───────────────────────┐          │
│        │                       │          │
│        │         COVER         │          │
│        │                       │          │
│        └───────────────────────┘          │
│                                           │
│        Chapter 7: Riddles in the Dark     │   tap → Contents
│       The Hobbit · J.R.R. Tolkien         │
│         Narrated by Andy Serkis           │   only if narrator known
│                                           │
│  ●━━━━━━━━━━━━━━━━○──────────────────────│
│  12:04        Chapter 7 of 19      -18:31 │
│                                           │
│   ⏮      ↺        ( ▶ )        ↻      ⏭   │
│ Chapter  15 s                  30 s Chapter│   captions, caption2, secondary
│                                           │
│      42% · 6 h 10 m left in book          │
│                                           │
│  1.25×     ☾ Sleep    🔖 Mark    ⌁    …    │   Speed · Sleep · Bookmark · AirPlay · More
└───────────────────────────────────────────┘
```

Labels: tool row captions **"1.25×"** (the speed is the label), **"Sleep"** / **"23:41"** / **"End of ch."**, **"Mark"**, the AirPlay glyph, and **"More"** as the accessibility label for `…`.

### 2.3 Reader (full screen, paper palette)

The card shrinks to two zones. The NOW line only appears when the current sentence is off screen. It replaces the separate "Back to where it's reading" pill and works as the pill: tap NOW to scroll back.

```
┌───────────────────────────────────────────┐
│ ⌄  ╭──────────────╮  The Hobbit      Aa … │   ⌄ "Back to library", Aa Display, … More
│    │≡ Read aloud  │  Ch. 7 of 19 · Riddles│   tap title block → Contents
│    ╰──────────────╯                       │
│───────────────────────────────────────────│
│ THE HOBBIT                                │
│ Riddles in the Dark                       │
│                                           │
│ Deep down here by the dark water lived    │
│ old Gollum, a small slimy creature. ░░░░░ │
│ ░░He was Gollum—as dark as darkness,░░░░░ │   current sentence (glow)
│ except for two big round pale eyes in     │
│ his thin face.                            │
│                                           │
│╭─────────────────────────────────────────╮│
││ NOW  He was Gollum—as dark as dark… ⌄   ││   only when off-screen; tap = catch up
││  ●━━━━━━━━━━━○──────────────────────── ││   real slider with thumb + live preview
││  4:12   Ch. 7 of 19 · about 6 h left -9:30││
││                                         ││
││   ⏮      ↺        ( ▶ )        ↻     ⏭  ││
││ Chapter Sentence            Sentence Chapter│
││                                         ││
││  1.25×   ☾ Sleep   🔖 Mark   ⌁   Heart ▾ ││   last chip = voice → Voice sheet
│╰─────────────────────────────────────────╯│
└───────────────────────────────────────────┘
```

- The voice chip takes the "More" position in the tool row: **"Heart ▾"**. It opens the Voice sheet only. Speed has its own chip and the shared Speed sheet, which fixes E2. The `…` in the top bar holds *Skip by ▸*, *Reading settings…* (the reader section of Settings only, which fixes E3), and *Bookmarks*.
- While dragging the scrubber, the NOW line shows the sentence under the thumb: **"Jump to: Gollum had a little boat…"**. On release, it seeks there.
- Buffering (`status.line`) appears in the NOW slot as **"Preparing voice… 4 s"** instead of adding a third line.
- Card height is measured (`onGeometryChange`) and fed into the text inset and the visibility check (E5).
- **Listen mode (P3):** a button in `…` → **"Listening view"** swaps the text for the cover (laid out like §2.2). That covers phone-in-pocket and car-mount use (B7) without making the audiobook player grow a text view it can't fill.

### 2.4 Shared Speed sheet

One `SpeedSheet(speed: Binding<Double>, range:)` used by both players:

```
            Playback Speed
               1.25×
   ⊖  ━━━━━━━━━━━━○━━━━━━━━━━━━━━━━  ⊕
  [0.8×] [1×] [1.25×] [1.5×] [1.75×] [2×]
        Saved for this book.  Set as default
```

- Same presets in both: **0.8, 1, 1.25, 1.5, 1.75, 2**. These also replace the lock-screen list in `RemoteRouter.swift:52`. The range is 0.5–3.5 for audio and 0.6–2.0 for Kokoro (the engine's limit). Label everything with `Fmt.speed`.
- Reader speed becomes **per book**, like audiobooks: add `speed` to the text book's saved state, with `ReaderSettings.speed` kept as the default for new books. **"Set as default"** writes the default. This answers "speed is per-book in one and global in the other" by making both work like the audiobook. People listen to dense non-fiction slower than thrillers, whatever the format.
- The voice stays global (it's a big download/warm-up). It's shown on the reader's chip and on the lock screen.

### 2.5 Mini player: one bar, follows what plays

```
┌─────────────────────────────────────────────┐
│ ┌────┐ Riddles in the Dark          ↺   ▶  │
│ │COV🎧│ The Hobbit · Audiobook      15 s     │   kind badge on the cover corner
│ └────┘━━━━━━━━━━━━━━━━━━━━━━━━━━━──────────│
└─────────────────────────────────────────────┘

┌─────────────────────────────────────────────┐
│ ┌────┐ Chapter 2: The Old Sea-dog   ↺   ❚❚ │
│ │COV≡ │ Treasure Island · Read aloud Sentence│
│ └────┘━━━━━━━━━━━━━──────────────────────────│
└─────────────────────────────────────────────┘
```

- **What it shows:** the session `RemoteRouter` last activated (the one the lock screen shows), falling back to the most recently opened if neither has played yet. This fixes C1. Showing "who owns the lock screen" in one place keeps the app and the lock screen in agreement. Concretely: give `RemoteRouter` an observable `activeKind`, have `LibraryView` choose by it instead of `lastOpenedText`, and when the library opens an audiobook while the reader is playing, either autoplay it (and so take over) or leave the bar on the reader.
- **Kind:** a 16 pt badge on the cover's corner (`headphones` / `text.alignleft`) and the word **"Audiobook"** / **"Read aloud"** after the title. The reader version uses `ReaderPalette.card` as its background and the lamp-green play button, so it's visibly the reader.
- **Skip button** is the same as the big player's, with the same caption ("15 s" / "Sentence").
- **The other session:** long-press the bar → **"Switch to *The Hobbit*"** (pauses this, opens and resumes that one) and **"Close"** (unloads this session). If the other session exists, a swipe left/right on the bar also switches, like a two-page carousel with page dots. Long-press is the dependable path; the swipe is a nice extra.
- When `RemoteRouter.activate` pauses one session for the other, show a toast: **"Paused *The Hobbit*"** (C3).

### 2.6 Lock screen / Now Playing

| Field | Audiobook | Reader |
|---|---|---|
| Title | chapter title | chapter title |
| Artist | `Author · Narrated by Narrator` (or just author) | `Author · Read aloud by Heart` |
| Album | book title | book title |
| Chapter number/count | yes (today) | **add** |
| Rate / default rate | book speed | 1.0 (speed is baked into the audio) + `DefaultPlaybackRate` = 1.0; the speed command still works |
| Artwork | cached per book | **cache per book** (D3) |
| Skip ±15/30 | seconds | **≈ seconds**: step back or forward over whole sentences until the estimated time (`secPerCharNow × chars`) reaches the interval, at least 1 sentence. The "15" icon then means about 15 s in both players |
| Next/previous track | chapter | chapter (today it's one sentence or paragraph) |

The lock screen offers only one skip size, and the system shows it as seconds, so the reader converts to seconds there. Inside the app the reader keeps its natural units (sentence/paragraph), with captions saying so.

---

## 3. Alternatives considered

**A. One merged player screen with a "Text / Cover" toggle.** One `NowPlayingView` for everything: audiobooks show the cover, books default to text and can flip to the cover. It's attractive because it removes the "two players" question entirely. Rejected as the main design for three reasons. For half the library (audiobooks) the toggle would do nothing. The reader's text needs the full screen and the paper palette, which the system-styled audiobook sheet doesn't suit. And it means rewriting both screens, where the recommendation can be done step by step on today's code. The useful part is kept as the reader's **Listening view** (§2.3).

**B. Make them deliberately different (two separate apps in one).** Keep the reader as its own world and only label it better. Rejected because the user's complaint is ambiguity, and that comes from **controls in the same position meaning different things** (A1–A4) and **features that exist in one only** (B1–B4). Different colours don't fix either. Labels alone would leave a bedtime reader with no sleep timer.

**C. Two mini players stacked when both sessions are loaded.** The most honest option, but it costs about 70 pt of library permanently, for a state (an audiobook and a book both in progress) that's normal for this user. The lock screen can only show one anyway, so one bar plus a "Switch to …" path matches the system.

---

## 4. Prioritized changes

| P | Change | Fixes | Effort |
|---|---|---|---|
| P0 | Mini player follows `RemoteRouter`'s active target (observable `activeKind`), not `lastOpenedText`; opening an audiobook while a book reads aloud doesn't hide the reader's bar | C1 | S |
| P0 | Reader skip buttons: circular-arrow glyphs + "Sentence"/"Paragraph" caption; long-press menu "Skip by"; same captions on the mini player and "15 s"/"30 s" captions on the audiobook | A1–A3 | S |
| P0 | Shared sleep timer: move `SleepTimer` state out of `Player` into a `SleepController` that pauses `RemoteRouter.active`; add "end of chapter" support to `ReaderPlayer`; put `SleepMenu` in the reader card | B1 | M |
| P0 | Speed: one `SpeedSheet`, same presets, `Fmt.speed` everywhere (reader card, Settings `%.2g`), lock-screen rate list matches | B4, D4 | S |
| P1 | Reader lock-screen skip ≈ seconds (whole sentences); next/previous track = chapter; add chapter number/count; cache artwork; "Read aloud by …"/"Narrated by …" in Artist | A4, D1–D3 | S |
| P1 | Reader per-book speed (default in `ReaderSettings`, "Set as default") | B4 | M |
| P1 | Reader bookmarks: `Bookmark` gains an optional `(chapter, sentence)`; Bookmark button in the reader card; Bookmarks tab in Contents | B2 | M |
| P1 | AirPlay `RoutePicker` in the reader's tool row | B3 | S |
| P1 | Kind capsule in both headers ("Audiobook" / "Read aloud"); remove "Now Playing"; tappable chapter title in the audiobook | A5, E7 | S |
| P1 | Reader card: separate Speed chip (→ Speed sheet) and Voice chip (→ Voice sheet); `…` menu replaces the full Settings button | E2, E3 | S |
| P1 | Book progress line in the reader ("42% · about 6 h left in book") from the existing `bookFraction`/`bookSecLeft` | B5 | S |
| P2 | Reader scrubber → real slider with a thumb and a "Jump to: …" preview while dragging | E1 | M |
| P2 | NOW line only when the current sentence is off screen, merged with the catch-up pill; measured card height instead of `230` | E4, E5 | M |
| P2 | Contents unified: same sheet title, Chapters/Bookmarks segments, same current/read markers in both | A6 | M |
| P2 | Toast "Paused *X*" when one player pauses the other; mini player long-press "Switch to …" / "Close" | C2, C3 | S |
| P2 | Voice preview resumes reading afterwards | E6 | S |
| P3 | Reader "Listening view" (cover + big transport) | B7 | M |
| P3 | Swipe on mini player to flip sessions; audiobook player in lamp-green tint | C2 | S |
