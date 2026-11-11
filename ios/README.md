# Lamplight for iPhone

A SwiftUI version of the AB-Player web app, built with AVFoundation. Same idea: each folder of audio files you add is one book, and it remembers where you stopped. Being a real app, it can do a lot that the Home Screen web app couldn't.

Requires iOS 18 or later. One third-party dependency: [kokoro-coreml](https://github.com/mattmireles/kokoro-coreml) (Apache-2.0) for the Kokoro voice, which brings MisakiSwift and MLX (Apache-2.0 and MIT).

## What's new compared with the web app

| Area | Web app | Native app |
| --- | --- | --- |
| **Chapters** | Each file is a "track"; chapters inside M4B files are ignored | Reads chapters embedded in M4B/M4A (and chaptered MP3). Files without chapters count as one chapter each. Scrubber, lock screen and skip buttons work by chapter, and a chapter list lets you jump |
| **Long single-file books** | One 20-hour "track" with a 20-hour scrubber | Navigated by chapter |
| **Book details** | Title only | Title, author and narrator read from tags (album, artist/album artist, composer) or an `Author - Title` / `Author/Title` folder layout. All editable |
| **Bookmarks** | None | Add at the current spot, add notes, jump back, delete |
| **Adding books** | Pick folders/files, which are copied into browser storage | **Link** a folder in iCloud Drive / On My iPhone / another Files provider and play it where it is, or **copy** folders/files into the app. Also: a folder in the Files app (and Finder over USB) that's imported automatically, and "Open in"/Share from other apps. A folder of M4B files becomes one book per album tag. Duplicate imports are skipped |
| **Storage** | Safari's website storage; deleting the Home Screen icon or Safari clearing data wipes it | Linked books: the audio stays in your folder; the app keeps only a bookmark to it, plus the cover and your progress. Copied books: plain files in the app's container, included in iPhone backups (cloned on import, so no extra space while the original exists) |
| **Smart rewind** | No | Goes back 2–20 s depending on how long you paused (can be turned off) |
| **Skip intervals** | Fixed 15/30 s | 5–90 s, set separately for back and forward; also used on the lock screen |
| **Speed** | Presets from 0.75× to 3× | 0.5×–3.5× in 0.05 steps plus presets, saved per book, pitch-corrected |
| **Sleep timer** | Stops abruptly | Fades out over the last 10 s; "end of chapter" stops exactly at the chapter boundary |
| **Library** | One list sorted by recently played | Search (title/author/narrator), filters (Listening / New / Finished), sorting (recent, title, author, date added), swipe actions |
| **Covers** | Folder image or embedded art | Same, plus choose a cover from Photos |
| **Phone calls / headphones** | Workarounds for Safari's audio session; sometimes needs a tap | Native audio session: resumes 3 s back after a call (unless it lasted 30+ min), pauses when headphones are unplugged, recovers if iOS resets media services |
| **Output** | n/a | AirPlay/Bluetooth picker on the player |
| **Lengths** | Read in the background after import | Read precisely during import, so time left is right immediately |

### EPUB and PDF read aloud (from Lamplight Reader)

The reader from [Lamplight](https://github.com/Bidpuck/Lamplight) is built in, without Piper:

- **Add** EPUBs and PDFs with **+ › Add EPUB or PDF**, the Files folder, Open in, or a **watched folder** (Settings › Library) whose new books are added each time the app opens. Title, author, series (Calibre or EPUB 3 metadata), subjects and cover are read from the file; chapters come from the EPUB's contents or the PDF's bookmarks (otherwise 8 pages a chapter).
- **Kokoro runs on the iPhone itself**: the Kokoro v1.0 model (28 English voices) on the Neural Engine through Core ML ([kokoro-coreml](https://github.com/mattmireles/kokoro-coreml)), with Misaki, Kokoro's own phonemizer, turning text into American or British phonemes. No server and no internet. The Neural Engine keeps making speech while the screen is locked and leaves the CPU almost idle (about 2%), so iOS doesn't stop it in the background; the GPU is never used, because iOS refuses it to background apps. It needs a real iPhone (iOS 18 or later): in the simulator Kokoro shows as unavailable. Apple's **iPhone voice** is there as a fallback.
- **Reading screen:** the whole chapter with the sentence being read highlighted and read text faded, follow-along scrolling (scroll away and a "Back to where it's reading" pill appears), tap any sentence to read from there, a NOW line, chapter-time scrubber, skip by sentence or paragraph, speed and voice chips, Contents with search inside the book, and an Aa sheet (text size, five fonts, Paper / Dark / Auto, follow along, fade).
- **Playback** works like Lamplight's player: clips are made in reading order two at a time, 45 s ahead (240 s when the screen locks), it waits once at the start until it can keep going ("Buffering… N s"), learns how fast the voice is on this iPhone (Settings shows the measured speed), trims silence to the "pause between sentences" setting, and adds a beat after dialogue.
- **Words:** strong-language filter (muted in speech, masked on screen) with your own extra words, and a pronunciation dictionary with preview.
- **Library:** shelves (genres) for every book, audiobooks included: the defaults Christian, Biography, Sci-fi and Classics, suggested from an EPUB's subjects; add, delete and reorder them. Series group together in order (toggle in Settings).
- **Back up and sync:** one zip with every EPUB/PDF, covers, shelves, series, words and every book's place; restoring merges (newer places win, nothing is deleted). Audiobook audio isn't included.
- The audiobook player and the reader share the lock screen: starting one pauses the other.

Fonts: Lamplight's web fonts aren't on iOS, so the five are New York, Charter, Georgia, Avenir and System.

### Linked folders (no copy)

**+ › Link Folders** keeps the audio where it is. The app stores a security-scoped bookmark to the picked folder (so access survives restarts, and a moved or renamed folder is followed), and track paths relative to it. Picking a folder of book folders links each book.

- iCloud files that aren't on the phone are downloaded with a coordinated read when they're imported (to read lengths and chapters) and again when played if iOS has removed the local copy; the next file is prefetched while the current one plays. The player shows "Downloading from iCloud…" meanwhile. For offline listening, choose **Keep Downloaded** on the folder in Files.
- **Rescan Folder** (long-press the book) picks up added, removed or renamed files, reuses the lengths and chapters it already knows, and keeps your place. New files after a finished book reopen it at the first new file.
- Deleting a linked book only removes it from the app.
- Not tested yet against real iCloud Drive (the simulator wasn't signed in); tested with a linked On My iPhone folder, including relaunching and rescanning.

Kept from the web app: folder-of-folders and CD1/Disc 2/Part 3 grouping, natural file ordering (`2` before `10`), saving position on pause/every 5 s/backgrounding, restoring the last book on launch, start over / mark finished / delete, cover fallback tiles with initials, and lock-screen/Control Center/AirPods controls.

## Still missing (possible next steps)

- **CarPlay browsing.** Now Playing controls work in the car, but browsing the library on the CarPlay screen needs Apple's CarPlay audio entitlement (request it from Apple) and a `CPTemplateApplicationScene`.
- **Sync between devices** (iCloud for positions and bookmarks; audio stays per device).
- **Widgets, Live Activity, Siri / App Intents** ("resume my audiobook").
- **Listening history and stats.**
- **Voice boost / silence trimming** (needs an `AVAudioEngine` pipeline rather than `AVPlayer`).
- **Moving books over from the web app.** The web app's storage is private to Safari, so books have to be added again; positions don't carry over.
- **Formats.** Ogg/Opus and DRM-protected Audible (AAX/AAXC) files can't be played by AVFoundation.

## Running it

**Once, set up the Kokoro voice** (needs uv and node: `brew install uv node`). This downloads the Kokoro models from kokoro-coreml and builds them, with the app's 28 voices, into `ios/KokoroRuntime/` (about 175 MB, bundled into the app, not kept in git). It takes a few minutes, mostly downloading:

```bash
ios/Scripts/setup-kokoro.sh
```

Without it the app still builds and runs; it just uses the iPhone voice and says why Kokoro isn't available.

Then open `ios/ABPlayer.xcodeproj` in Xcode (26 or later; the first build fetches the kokoro-coreml package), pick an iPhone or simulator, and press Run. The first time Kokoro loads on an iPhone, Core ML compiles its models for that phone, which takes about a minute; after that it loads in seconds. If Xcode fails compiling MLX's Metal shaders, run `xcodebuild -downloadComponent MetalToolchain` once.

The app icon is drawn by `ios/Scripts/make-icon.swift` (lamp, light and pages as vector shapes); run it to regenerate `icon-1024.png` after changing it.

To install on your own iPhone:

1. In Xcode, select the **ABPlayer** target → **Signing & Capabilities**, tick **Automatically manage signing** and choose your team (a free Apple ID works; the app then expires after 7 days and needs re-running from Xcode).
2. If Xcode complains the bundle identifier is taken, change `com.bentarcau.lamplight` to something of your own (the project is set up for team T5C5GL2LW4).
3. Connect the iPhone, select it as the run destination, and press Run. On the phone, allow the developer in **Settings → General → VPN & Device Management** the first time, and turn on **Developer Mode** if asked.

From the command line (simulator):

```bash
xcodebuild -project ios/ABPlayer.xcodeproj -scheme ABPlayer -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## Code

| File | Purpose |
| --- | --- |
| `ABPlayerApp.swift` | App entry; wires the library and player together, imports on launch/foreground and from "Open in" |
| `Models.swift` | `Book`, `Track`, `Chapter`, `Bookmark`; book-wide time ↔ file/offset mapping; formatting |
| `Library.swift` | Stores books (`Application Support/Library/library.json` + one folder per book), covers, imports, the Files-app folder |
| `Importer.swift` | Groups files into books, copies them, reads lengths, chapters, tags and artwork with AVFoundation |
| `Player.swift` | `AVPlayer` playback across files, saving position, lock screen, interruptions, sleep timer, smart rewind |
| `LibraryView.swift` | Library list, search/filter/sort, mini player |
| `PlayerView.swift` | Now Playing screen, speed sheet, sleep menu |
| `ChaptersView.swift` | Chapter list and bookmarks |
| `SettingsViews.swift` | Settings, "how to add books", edit book details |
| `Components.swift` | Cover tile, AirPlay picker, messages, import progress |
