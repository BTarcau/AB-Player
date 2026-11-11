# Settings, first run, adding books, and app-wide look

Scope: everything outside the library list and the two players: Settings, first run and empty states, the add-book flows (the `+` menu, the Files folder, linked and watched folders, backup), the voice choice when Kokoro is missing, Edit Details, and the look of the whole app (palette, type, icon, name). Companion proposals: `library.md` and `players.md`.

Method: I read the code; I didn't build or run it. Line numbers refer to the uncommitted `ios/` tree as of 2026-11-11.

---

## 0. The core problem in one paragraph

The app has two kinds of book, but nothing uses one consistent name for each. Settings calls them "Audiobook" (`SettingsViews.swift:17`) and "EPUB & PDF" (`ReaderSettingsViews.swift:60`). The `+` menu says "EPUB or PDF" and "Folders" (`LibraryView.swift:282-289`). Help is written as though only audiobooks exist (`SettingsViews.swift:55-80`). The Files folder's README covers only audiobooks (`Library.swift:65-70`). The reader's settings section also holds things that apply to both kinds (shelves, series, backup). So the user can't tell what a setting or an add option affects. The fix has three parts: **one vocabulary, one icon pair, and grouping by what a setting affects**, applied everywhere below.

### Proposed vocabulary (please use the same in library.md / players.md)

| Concept | Label | SF Symbol | Notes |
|---|---|---|---|
| Recorded audio (MP3/M4B folder) | **Audiobook** | `headphones` | Never "audio file" or "folder" in titles |
| EPUB/PDF read aloud | **Ebook** | `text.book.closed` | Subtitle "EPUB or PDF, read aloud" where space allows. "Read-aloud book" was considered, but it's too long for menus |
| Either | **Book** | `books.vertical` | "Library", "Add Book", "Delete Book" |
| Kokoro | **Natural voice** (detail: "Kokoro, on this iPhone") | `waveform` | Users don't know what "Kokoro" means |
| AVSpeech | **iPhone voice** | `iphone` | Already used |
| Paper / Dark / Auto | **Paper / Night / Match iPhone** | | "Auto" is ambiguous |

---

## 1. Problems found

### Settings (`SettingsView`, `ReaderSettingsSections`)
1. **Order doesn't follow how the app is used.** It's one long `Form`: two audiobook sections, then six reader sections, then "Adding Books", then Version (`SettingsViews.swift:16-37`, `ReaderSettingsViews.swift:30-142`). Audiobook settings come first only because they were written first.
2. **Sections that apply to both kinds sit inside the reader's settings.** `Library` (shelves, series grouping) at `ReaderSettingsViews.swift:90-107` and `Back up and sync` at `:109-142` come from `ReaderSettingsSections`. Shelves and series apply to audiobooks too (`EditBookView` offers them for both, `SettingsViews.swift:126-143`), and the backup includes audiobook places (footer `:141`).
3. **There are two "skip" settings with different headers and units.** "Audiobook Skip Buttons" (seconds, `SettingsViews.swift:17-24`) and "Skip buttons move" (Sentence/Paragraph, `ReaderSettingsViews.swift:38-41`) are four screens apart. They should sit side by side under their kind.
4. **The voice choice appears twice.** The `Voice` picker is in Settings (`ReaderSettingsViews.swift:31-33`), and the "Voice and speed" sheet has it again (`ReaderSheets.swift:219-222`). The Settings row "Voice and speed" is a `Button` that opens a sheet (`:34-37`), while the rows next to it push. That's inconsistent.
5. **Diagnostics sit in the main list.** "Measured voice speed" and "Clear prepared audio" (`ReaderSettingsViews.swift:48-58`) are maintenance tools shown at the same level as Voice.
6. **The Kokoro-missing message is written for developers.** It says "Run ios/Scripts/setup-kokoro.sh, then build again." (`VoiceEngines.swift:179,183`). Settings shows it in the footer (`ReaderSettingsViews.swift:63`), the voice sheet shows it (`ReaderSheets.swift:228-229`), and the reader's status line shows it (`ReaderPlayer.swift:483-485`). Nothing falls back to the iPhone voice: `source` defaults to `.kokoro` (`ReaderSettings.swift:130`), so a build without the model can't read aloud until the user finds the picker.
7. **"Reading display" is one row that pushes to a `Form` with no Done button** (`ReaderSettingsViews.swift:69-71`). That's fine, but its theme (Paper/Dark/Auto) controls only the reader, while the rest of the app follows the iPhone. A user who picks "Dark" there will expect the app to go dark.
8. **The watched folder only takes ebooks** (footer `ReaderSettingsViews.swift:106`; `TextLibrary.swift:133`), but it sits under a "Library" header that sounds general. Linked folders, the audiobook counterpart, have no section in Settings at all. There's no list of linked folders and no way to see or re-link them.
9. **Version shows in two places**: Settings (`SettingsViews.swift:34-36`) and the library footer (`LibraryView.swift:459`). There's no About section, and no credits for Kokoro, sherpa-onnx or espeak-ng. Their licences call for attribution, and espeak-ng is GPL.
10. **Footers are too long.** Smart Rewind's footer runs to 3 lines and quotes exact seconds (`SettingsViews.swift:28`). The backup footer explains a two-way sync process in one sentence (`ReaderSettingsViews.swift:141`).

### First run, empty state and adding books
11. **The empty state is a wall of text with four equal buttons that mix the two kinds** (`LibraryView.swift:169-178`). "Link a Folder" is the prominent action, but a new user who has an EPUB won't know it applies to them (it doesn't, really). "Add an EPUB or PDF" sits between two folder actions. Nothing says what the app *does* (listen to audiobooks; have ebooks read to you).
12. **No sample content, so the app's headline feature (Kokoro reading) can't be tried until the user finds an EPUB.**
13. **The `+` menu is grouped by storage ("nothing copied" vs "always available offline"), not by kind** (`LibraryView.swift:280-296`). The ebook item sits in the "offline" group with two audio-copy items. The label "Add Book" on the `+` hides the fact that there are two kinds.
14. **"Other Ways to Add Books" only covers audiobooks** (`SettingsViews.swift:49-92`). "Formats" lists only audio. "From other apps" says "Share an audio file", although Info.plist also registers EPUB and PDF (`Info.plist` Book document type). The Files-folder text says "audiobook folders (or single M4B/MP3 files)", although `scanFilesFolder` also imports EPUB/PDF (`Library.swift:343-346`). The watched folder is missing from help.
15. **The Files-app README talks only about audiobooks** (`Library.swift:65-70`).
16. **Shelves come pre-seeded with the defaults "Christian, Biography, Sci-fi, Classics"** (`ReaderSettings.swift:93`). On a fresh install they show up as pills above an empty library, which is noise. They're personal choices, and first run should offer them rather than impose them.

### Edit Details (`EditBookView`, `SettingsViews.swift:95-205`)
17. **You can't make a shelf here.** "No shelves yet. Add some under Edit shelves in the library." (`:136`) sends the user to another screen and loses their edits.
18. **The info section has no header and doesn't say what kind of book this is** (`:144-158`). For ebooks, "Format EPUB" sits halfway down. There's no badge at the top saying Audiobook vs Ebook.
19. **The cover can only come from Photos** (`:119`), even though most covers live in Files next to the books.

### Accessibility
20. **Reader chrome and fonts use fixed point sizes and ignore Dynamic Type.** `ReaderFont.font(size:)` (`ReaderSettings.swift:47-53`) and the NOW line at `size: 13.5` (`ReaderView.swift:123`) are fixed. The text-size slider (14–30 pt, `ReaderSheets.swift:149`) starts from scratch rather than following the system text size.
21. **The "Pause between sentences" slider has no accessibility label** (`ReaderSettingsViews.swift:44`), so VoiceOver reads only "80".
22. **The small and large "A" marks on either side of the text-size slider are read aloud as "A", "A"** (`ReaderSheets.swift:148,150`). They should be hidden from VoiceOver.
23. **Several layouts break at large accessibility text sizes.** The font tiles have a fixed size of `72×64` (`ReaderSheets.swift:162`), and the five speed buttons sit in one `HStack` (`ReaderSheets.swift:203-209`).
24. **Some text fails contrast.** Brass on paper is **2.58:1** (fails AA), and it's used for the "NOW" caption at `ReaderView.swift:121`. White on the dark-mode accent `#6FA37E` is **2.91:1**, and the selected shelf pills use it (`LibraryView.swift:243-244`). These pass: inkSoft on paper 4.76:1, lamp on paper 5.87:1, brass on night 8.6:1.
25. **Pronunciation rows read as "quote Ludger quote right arrow quote…"** (`ReaderSettingsViews.swift:232`). They need an `accessibilityLabel` like "Ludger, said as Lood-ger".

### Visual consistency
26. **There are two design languages.** The reader paints its own palette (`ReaderPalette`, `ReaderSettings.swift:56-77`: paper `#ECE6D6`, lamp `#3F5D48`, brass `#AD8A52`, night `#1B1F1A`) with serif text. The library, Settings, Edit Details and the audiobook player use stock grouped-list grey and white, with `.tint(.primary)` controls (`PlayerView.swift:99,133,154`). The only thing they share is AccentColor (lamp green), and only because the asset catalog defines it. Opening a book feels like opening a different app.
27. **The palette exists only as `UIColor` constants inside the reader.** There are no named colours in `Assets.xcassets`, so other views can't use it and SwiftUI can't switch light and dark automatically.
28. **The app icon has only a light variant** (a single `icon-1024.png` in `AppIcon.appiconset`). On iOS 18+ the dark and tinted home screens show a pale square. Internally the app is still "ABPlayer": project, scheme, `ABPlayerApp`, bundle id `com.abplayer.audiobooks`, and the `Settings` keys. Users never see this, so it can wait.

---

## 2. Recommended design

### 2.1 Principles
- **Group by what a setting affects.** The groups are **Audiobooks**, **Ebooks**, **Library** (both), and **App** (both). Each kind gets its icon in its section header, and the same icons appear on library rows, menus and Edit Details.
- **Settings live where they're used, and Settings collects them all.** The players keep their in-place controls (speed chips, Aa sheet). Settings is the full list, in the same order and with the same labels.
- **The Lamplight look applies everywhere, with the reader as the strongest version of it.** Paper-tone backgrounds and serif titles go app-wide; the content area stays SF for legibility.

### 2.2 Settings structure

```
┌─────────────────────────────────────────┐
│ Settings                          Done  │
├─────────────────────────────────────────┤
│  [icon]  Lamplight                      │  ← header card: icon, name,
│          14 books · 3.2 GB              │    storage (moved from the
│                                         │    library footer)
│ 🎧 AUDIOBOOKS                            │
│  Skip back                     15 sec ›  │  ← Pickers (menu style)
│  Skip forward                  30 sec ›  │
│  Smart Rewind                     [on]  │
│  Goes back a few seconds when you        │  ← one-line footer
│  resume, more after a long break.        │
│                                         │
│ 📖 EBOOKS READ ALOUD                     │
│  Voice            Heart · Natural  ›     │  ← push: Voice & Speed screen
│  Speed                        1.2×  ›    │  ← same screen, speed section
│  Skip buttons move  [Sentence|Paragraph]│
│  Pause between sentences        80 ms   │
│  ──────────────────o────────────        │
│  Text & Theme                        ›  │  ← push: DisplayControls
│  Words & Pronunciation               ›  │  ← push: filter + rules
│                                         │
│ 📚 LIBRARY                               │
│  Shelves                    4 shelves › │  ← push (not a sheet)
│  Group books by series            [on]  │
│  Linked folders                     2 › │  ← NEW: list, re-link, remove
│  Watched folder           "Ebooks"  ›   │  ← push: status, Check now,
│                                         │    Change, Stop watching
│  Back up & Restore           Never ›    │  ← push: backup screen
│                                         │
│ ✦ APP                                    │
│  Appearance      Match iPhone  ›        │  ← Match iPhone / Paper / Night
│  How to Add Books                    ›  │
│  Advanced                            ›  │  ← measured speed, clear audio,
│  About & Credits                     ›  │    reset onboarding
└─────────────────────────────────────────┘
```

**Exact header strings:** `Audiobooks`, `Ebooks Read Aloud`, `Library`, `App`. Each header is a `Label(title, systemImage:)`, so it shows the kind's icon. (Use `.textCase(nil)` if the uppercase style hides the icon.)

**Voice & Speed screen** (replaces both the Settings voice rows and the reader's `VoiceSheet`; the reader opens the same view as a sheet):
```
Voice & Speed
 SPEED     [0.8×][1.0×][1.2×][1.5×][2.0×]   ← wraps at AX sizes (ViewThatFits → Picker)
           Fine speed 1.20×  ───o──────
 VOICE TYPE  [ Natural | iPhone ]          ← segmented
           ▶ Hear this voice
 NATURAL VOICES (Kokoro, on this iPhone)
   ✓ Heart       American English, female
     Bella       American English, female
   …
 Footer: Runs on this iPhone. Nothing leaves your phone, and it keeps
 reading while the screen is locked.
```

**Back up & Restore screen:**
```
Back up & Restore
 [ Back Up Now ]                Last: 3 Nov
   Saves every ebook, all your shelves and every book's place
   (audiobook audio isn't included).
 [ Restore from a Backup… ]
   Adds what's missing and moves places forward. Nothing is deleted.
 HOW TO KEEP TWO IPHONES IN STEP
   1. Back up here and save the file to iCloud Drive.
   2. On the other iPhone, choose Restore and pick that file.
   3. Do the same in the other direction.
```

**Advanced:** Measured voice speed (read-only), Clear Prepared Audio, Show Welcome Again.

**About & Credits:** Version, build, Kokoro (Apache-2.0), sherpa-onnx (Apache-2.0), ONNX Runtime (MIT) and espeak-ng (GPL-3.0) with their licence texts, plus "Made for reading by lamplight." Remove the version line from the library footer, or keep only the storage figure there.

### 2.3 First run

A one-time welcome sheet (`.sheet` with `interactiveDismissDisabled(false)`, shown while the library is empty and `hasSeenWelcome` is false). Paper background with serif titles: this is the first impression of the Lamplight look.

```
┌─────────────────────────────────────────┐
│                                         │
│              [ lamp icon ]              │
│          Welcome to Lamplight           │  serif, .largeTitle
│                                         │
│ 🎧  Listen to audiobooks                 │
│     MP3 or M4B. A folder is one book.   │
│     Chapters, bookmarks, sleep timer.   │
│                                         │
│ 📖  Have ebooks read to you              │
│     EPUB or PDF, read aloud by a        │
│     natural voice on this iPhone, with  │
│     the sentence highlighted.           │
│                                         │
│ 📚  One library for both                 │
│     Shelves and series hold either      │
│     kind.                               │
│                                         │
│  [      Try a Sample Ebook       ]      │  ← prominent: imports a bundled
│  [         Add My Books          ]      │    public-domain short story
│             Not now                     │
└─────────────────────────────────────────┘
```

- **Sample ebook:** bundle one small public-domain EPUB (a short story, under 100 KB) and import it with `importEbook`. Opening it straight away shows the reader and plays Kokoro, which is the app's best feature, within 10 seconds of install.
- **Shelves:** start with **no** shelves. The library's `Edit shelves` pill already handles adding them, and the Shelves screen offers the old four as one-tap suggestions ("Suggested: Christian · Biography · Sci-fi · Classics").
- If Kokoro isn't in the build, the welcome sheet still works. The sample reads with the iPhone voice (see 2.5).

### 2.4 Empty library and the add flow

**Empty state** (replaces `LibraryView.swift:169-178`): two cards, one for each kind, and nothing else.

```
┌─────────────────────────────────────────┐
│ ⚙                Lamplight           +  │
│                                         │
│         Your library is empty           │  serif .title2
│                                         │
│ ┌─────────────────────────────────────┐ │
│ │ 🎧  Add an Audiobook                 │ │
│ │     A folder of MP3 or M4B files    │ │
│ └─────────────────────────────────────┘ │
│ ┌─────────────────────────────────────┐ │
│ │ 📖  Add an Ebook                     │ │
│ │     EPUB or PDF, read aloud         │ │
│ └─────────────────────────────────────┘ │
│                                         │
│      Try a sample · More ways to add    │  ← two text buttons
└─────────────────────────────────────────┘
```

**`+` menu** (replaces `LibraryView.swift:280-296`), grouped by kind, then by method:

```
 + 
 ┌───────────────────────────────────────┐
 │ AUDIOBOOK                              │
 │  🔗 Link a Folder…                     │  footer: Plays from Files or
 │  ⬇︎ Copy a Folder In…                  │  iCloud. Nothing is copied.
 │  〰 Copy Audio Files In…               │
 │ EBOOK                                  │
 │  📖 Add EPUB or PDF…                   │
 │ ────────────────────────────────────── │
 │  ? More Ways to Add                    │
 └───────────────────────────────────────┘
```
Each kind is a `Section("Audiobook")` / `Section("Ebook")` header inside the `Menu`, and the link-vs-copy explanation becomes the audiobook section's footer. The toolbar label stays `Label("Add Book", systemImage: "plus")`.

**"Add an Audiobook"** (from the empty state) opens a small choice sheet, because linking vs copying is the one real decision:

```
Add an Audiobook
 ┌───────────────────────────────────────┐
 │ 🔗 Link a Folder          Recommended │
 │    Plays from iCloud Drive or Files.  │
 │    Takes no space in Lamplight.       │
 ├───────────────────────────────────────┤
 │ ⬇︎ Copy into Lamplight                 │
 │    Always available offline. Uses     │
 │    space on this iPhone.              │
 └───────────────────────────────────────┘
 Tip: pick a folder of book folders to add them all at once.
```

**"More Ways to Add"** (rewrite of `HowToAddView`), with sections by kind and shared items:
- **Audiobooks:** Link a folder / Copy into the app / How files become books / Formats (MP3, M4A, M4B, AAC, WAV, FLAC, AIFF, CAF; not AAX, not Ogg).
- **Ebooks:** Add EPUB or PDF / **Watch a folder** (new to help: "Put EPUBs in a folder in iCloud Drive and they appear here each time you open Lamplight") / What's read from the file (title, author, series, cover, chapters).
- **Both:** The Lamplight folder in Files (EPUBs, PDFs, audio files or folders) / Share or Open in… from other apps / From a Mac in Finder.
- Update the Files README text (`Library.swift:65-70`) to cover ebooks too.

**After an import:** the "Added “Title”" toast (`Library.swift:256`) gains a kind icon and an **Open** button, so the first book is one tap away.

### 2.5 When the natural voice isn't installed
- On launch, if `KokoroEngine.unavailableReason != nil` and `source == .kokoro`, set the **effective** source to `.device` without overwriting the user's choice, so it comes back when the model returns.
- User-facing text everywhere: **"The natural voice isn't included in this version of Lamplight, so the iPhone voice is reading."** Keep the `setup-kokoro.sh` hint, but only in `#if DEBUG` or under Advanced.
- In Voice & Speed, the "Natural" segment stays visible but disabled, with a footer that explains why.
- First load: change "Loading the Kokoro voice…" (`ReaderPlayer.swift:490`) to **"Warming up the natural voice (only the first time)…"**.

### 2.6 Edit Details
```
Edit Details                       Cancel  Save
          [ cover 160 ]
     📖 Ebook · EPUB · about 6 h     ← kind badge right under the cover
   Choose Cover ▾  (Photos… / Files…)
 DETAILS     Title / Author / (Narrator — audiobooks only)
 SERIES      Name / Number
 SHELVES     toggles…   + New Shelf…   ← inline TextField alert
 ABOUT THIS BOOK                       ← header added
             File, Chapters, Subjects, Location, Added
```

### 2.7 App-wide look

**Make the palette app-wide, in two strengths.**

1. Move `ReaderPalette` into named colours in `Assets.xcassets`, each with Any and Dark appearances: `Paper`, `Paper2`, `Card`, `Ink`, `InkSoft`, `Lamp`, `LampDark`, `Brass`, `Glow`. Add a `Color.lamplight.paper` and similar extension. The reader keeps its own override when its theme differs from the app's.
2. **Chrome (library, Settings, sheets, audiobook player):**
   - `List`/`Form`: `.scrollContentBackground(.hidden)`, `.background(Color.paper)`, `.listRowBackground(Color.card)`. Light: paper `#ECE6D6` behind white cards. Night: `#1B1F1A` behind `#232821`.
   - Navigation titles in New York serif, via `UINavigationBarAppearance` `largeTitleTextAttributes`/`titleTextAttributes` with `UIFontDescriptor.withDesign(.serif)` scaled by `UIFontMetrics`. Use `.fontDesign(.serif)` on book titles in rows, the player title, empty states and the welcome sheet. **Body, buttons, captions and settings labels stay SF**, because serif at caption size hurts legibility.
   - Tint: Lamp (already AccentColor). Brass is for **progress and "now"** only: progress bars in rows, the player scrubber fill, the NOW marker. It's never small text on paper, where it fails contrast. Use `Ink` for that text, or darken brass to `#8A6A35` (4.6:1 on paper).
   - Audiobook player: the paper background, a cover shadow lit by `Glow`, and Lamp for the play button. That way both players feel like the same app (coordinate with players.md).
3. **Appearance setting (app-wide):** `Match iPhone` (default) / `Paper` / `Night`, applied with `.preferredColorScheme`. The reader's theme picker becomes `Same as App` (default) / `Paper` / `Night`, so a user can still read on paper at night while the app is dark.
4. **Fix contrast:** the selected shelf pill in Night uses `LampDark` text on `Lamp`, or `Paper` text on `#4F7F5C`. The NOW label uses `Ink` weight heavy with a brass dot.

**Icon and name:**
- Add **dark** and **tinted** icon variants to `AppIcon.appiconset`. Dark: the same lamp and pages on night `#1B1F1A`, with the glow kept warm. Tinted: a single-channel greyscale version of the lamp and pages, no background.
- Use the lamp mark (an SF-style glyph traced from the icon, or `lamp.desk` as a stand-in) in the welcome sheet, the Settings header card and the empty state, so the icon carries into the app.
- The display name "Lamplight" is right. Renaming the Xcode target and bundle id isn't worth the risk: a new bundle id loses the installed library.

### 2.8 Accessibility fixes (bundled with the restyle)
- Scale reader chrome with `UIFontMetrics(forTextStyle: .body).scaledFont(for:)` in `ReaderFont.uiFont`. Make the text-size slider an *offset* from the user's Dynamic Type size, rather than an absolute 14–30 pt.
- Add `Slider(...) { Text("Pause between sentences") }` and `.accessibilityValue("\(gap) milliseconds")`.
- Mark the "A" marks around the size slider `.accessibilityHidden(true)`.
- Font tiles: drop the fixed frame and use `.frame(minWidth: 72, minHeight: 64)`. At AX sizes, wrap the speed buttons with `ViewThatFits` and fall back to a `Picker`.
- Pronunciation rows: `.accessibilityElement(children: .combine)` with the label "\(find), said as \(replace)" or "\(find), skipped".
- Section headers with kind icons: the label text is enough, so hide the icon from VoiceOver (`Label` already does this).
- Add an "Open" accessibility action on the new toast.

---

## 3. Alternatives considered

**A. Split Settings into tabs, "Audiobooks | Ebooks", with a segmented control at the top.** It looks like it solves the ambiguity, but a third of the settings (shelves, series, folders, backup, appearance, about) belong to neither kind. They'd either be duplicated on both tabs or hidden on one. The control also hides half the settings, which makes finding things harder. Rejected. The section-per-kind list with icons gets the same clarity without hiding anything.

**B. No Settings screen for player settings at all; everything lives in the players** (skip and smart rewind in the audiobook player's menu, voice and words in the reader's Aa sheet), with Settings only for Library and App. That's attractive and fits "settings live where they're used", but there'd be no way to set up the voice or words before opening an ebook, and nowhere to review everything at once. Partly adopted: each player gets a "Settings…" item that opens Settings scrolled to its kind's section (`ScrollViewReader` with ids `audiobooks` and `ebooks`).

**C. Keep stock iOS styling everywhere and make the reader plainer to match.** It's less work and "native", but the paper-and-lamp identity is what makes Lamplight feel like itself, and it's what the user built the web app around. Rejected in favour of 2.7, which keeps system controls and layout and changes only colours and title type.

---

## 4. Prioritized changes

| # | Change | Files | Effort |
|---|---|---|---|
| 1 | Reorder Settings into Audiobooks / Ebooks Read Aloud / Library / App with icon headers; move Library and Backup out of `ReaderSettingsSections`; remove the duplicate Voice picker | `SettingsViews.swift`, `ReaderSettingsViews.swift` | S |
| 2 | Kokoro missing: fall back to the iPhone voice and show user-facing text; developer hint only in DEBUG; friendlier first-load line | `VoiceEngines.swift`, `ReaderPlayer.swift`, `ReaderSheets.swift`, `ReaderSettingsViews.swift` | S |
| 3 | `+` menu grouped by kind (Audiobook / Ebook sections) | `LibraryView.swift` | S |
| 4 | Empty state with two kind cards, plus the "Add an Audiobook" link-or-copy sheet | `LibraryView.swift`, new `AddBookSheet` | S |
| 5 | Rewrite "More Ways to Add" by kind (add ebooks, watched folder, Files folder); update the Files README text | `SettingsViews.swift`, `Library.swift` | S |
| 6 | Accessibility quick fixes: slider labels, hidden "A" marks, pronunciation labels, NOW and pill contrast | `ReaderSettingsViews.swift`, `ReaderSheets.swift`, `ReaderView.swift`, `LibraryView.swift` | S |
| 7 | Named palette colours in the asset catalog plus a `Color` extension; the reader reads from them | `Assets.xcassets`, `ReaderSettings.swift` | S |
| 8 | Apply the palette and serif titles to the library, Settings, sheets and audiobook player; add the app-wide Appearance setting; reader theme "Same as App" | many views, `ABPlayerApp.swift` | M |
| 9 | Voice & Speed as one pushed/sheet screen shared by Settings and the reader; Advanced and About & Credits screens (licences) | `ReaderSheets.swift`, `SettingsViews.swift` | M |
| 10 | Back up & Restore screen and Watched Folder screen; new Linked Folders list (re-link, remove) | `ReaderSettingsViews.swift`, `Library.swift` | M |
| 11 | Edit Details: kind badge, About header, inline New Shelf, cover from Files | `SettingsViews.swift` | S |
| 12 | Welcome sheet, plus a bundled public-domain sample EPUB and "Try a Sample"; start with no shelves and show the old defaults as suggestions | new `WelcomeView`, `ReaderSettings.swift`, bundle resource | M |
| 13 | Dynamic Type for reader chrome and fonts (`UIFontMetrics`); size slider as an offset; AX-size layouts for font tiles and speed buttons | `ReaderSettings.swift`, `ReaderSheets.swift`, `ReaderView.swift` | M |
| 14 | Dark and tinted app icon variants; lamp glyph in the welcome sheet, Settings header and empty state | `AppIcon.appiconset`, art | M (art) |
| 15 | "Settings…" entry from each player that jumps to its section | players + `SettingsView` | S |
| 16 | Toast with kind icon and Open button after an import | `Library.swift`, `Components.swift` | S |

Suggested order: 1–7 as one "clarity" pass (all S; they fix most of the ambiguity), then 8–10 for the visual pass, then 11–16.
