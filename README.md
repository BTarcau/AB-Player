# AB-Player — Audiobooks for iPhone

A web app you add to your iPhone Home Screen. Each folder of audio files is one book. It plays the files in order and remembers where you stopped, whether you pause, lock the phone, switch apps or close the app.

## Features

- **Folder = book.** Pick a folder of audio files and it becomes a book. Pick a folder that holds several book folders and they're all added at once. Subfolders named `CD1`, `Disc 2`, `Part 3` and so on stay together as one book.
- **Remembers your place.** It saves your position when you pause, every 5 seconds while playing, and when the app is hidden or closed. When you reopen the app, your last book is ready to play from where you stopped.
- **Works offline.** Files are copied into the app's on-device storage, so nothing needs the internet once a book is added.
- **Lock screen controls.** Play, pause and skip from the lock screen, Control Center, AirPods and CarPlay.
- Back 15 s and forward 30 s, crossing into the next or previous track.
- Speed from 0.75× to 3×, saved per book.
- Sleep timer: 5–90 minutes, or the end of the current track.
- Track list, percentage finished, and time left in the book.
- **Cover art:** uses an image in the folder (`cover.jpg`, `folder.jpg`, or the first image). If there isn't one, it uses the artwork embedded in the audio files (MP3 ID3 tags, M4A/M4B cover art). Books added earlier get their embedded artwork the next time the app opens.
- Rename a book, start it over, mark it finished, or delete it.

Supported formats on iPhone: MP3, M4A, M4B, AAC, WAV, FLAC, AIFF.

## Install on your iPhone

The app needs to be served over HTTPS. GitHub Pages is the easiest option:

1. On GitHub, open **Settings → Pages** for this repository.
2. Under **Build and deployment**, set Source to **Deploy from a branch**, pick `main` and `/ (root)`, then **Save**.
3. After a minute the site is live at `https://<your-username>.github.io/AB-Player/`.
   (GitHub Pages on a private repository needs a paid GitHub plan. Otherwise make the repository public. Your audio files are never uploaded; they stay on your phone.)
4. Open that address in **Safari** on the iPhone, tap **Share → Add to Home Screen**, then open the app from its new icon.

## Adding books

1. Put each book's audio files in their own folder in the **Files** app (On My iPhone, iCloud Drive, etc.). Name the files so they sort in order, e.g. `01 Intro.mp3`, `02 Chapter One.mp3`. Numbers sort naturally, so `2` comes before `10`.
2. In the app, tap **+**:
   - **Choose a folder** lets you pick a book folder, or a folder of book folders.
   - **Choose audio files** is for older iOS versions that can't pick folders. Open the book's folder, tap **Select → Select All**, then **Open**, and give the book a name.
3. The files are copied into the app. Once copying finishes, you can delete the originals from Files if you want to save space.

## Notes and limits

- **Storage.** Books are stored in the app's private storage on the phone. iOS gives Home Screen apps a large share of free space, and doesn't clear their data the way it can for websites you visit in Safari. Always open the app from the Home Screen icon: Safari and the Home Screen app keep separate storage.
- **Deleting the Home Screen icon deletes its books and progress.**
- **iOS can close the app in the background.** The worst case is losing the last few seconds of progress.
- **Lock screen after a long pause.** If you pause and leave the phone for a long time, iOS may remove the app from the lock screen. Open the app and tap play; your place is kept.
- **Track lengths** are read in the background after you import, so "time left" may show up a few seconds later.

## Files

| File | Purpose |
| --- | --- |
| `index.html` | Page layout |
| `styles.css` | Styles: dark theme with automatic light mode, safe areas for the iPhone notch |
| `app.js` | Library, importing, player, saving progress, lock-screen controls |
| `db.js` | IndexedDB storage for books and audio files |
| `artwork.js` | Reads cover art embedded in MP3 (ID3v2) and M4A/M4B (MP4 `covr`) files |
| `duration.js` | Reads track lengths from MP3, M4A/M4B, WAV and FLAC headers |
| `sw.js` | Service worker that caches the app so it opens offline |
| `manifest.webmanifest`, `icons/` | Home Screen name and icon |

No build step. To run it locally, serve the folder with any static server, for example `python3 -m http.server`, and open `http://localhost:8000`.

When you change app files, bump `VERSION` in `sw.js` so installed copies pick up the update.
