import Foundation

/// Backup and restore, as a folder ("Lamplight Backup 2026-11-11"):
///
///     backup.json        settings, and every book's record: place, bookmarks,
///                        shelves, series, speed
///     Books/<id>/        the files of every book stored in the app: EPUBs and
///                        PDFs, and audiobooks that were copied in (audio,
///                        cover, parsed text)
///
/// Linked audiobooks (audio left in a folder elsewhere) have only their record
/// in the backup. If one isn't in the library when restoring, its record waits
/// and is applied when that book is linked again.
///
/// A folder, not a zip: copied audiobooks can be gigabytes. The book folders
/// are copied with `copyItem`, which on the phone's APFS storage makes clones
/// that take no extra space until the backup is saved somewhere else.
extension Library {
    struct BackupFile: Codable {
        var version = 2
        var exportedAt = Date()
        var settings: BackupSettings
        var books: [BackupEntry]
    }

    struct BackupEntry: Codable {
        var book: Book
        /// The book's folder is in Books/<id>/.
        var hasFiles: Bool
    }

    /// The app's settings. Left out on purpose: what this device learned (how
    /// fast the voice runs here), the watched folder (its access doesn't carry
    /// over), and the date of the last backup.
    struct BackupSettings: Codable {
        // Audiobooks
        var skipBack: Int
        var skipForward: Int
        var smartRewind: Bool
        // Library
        var librarySort: String?
        var libraryShelf: String?
        var shelves: [String]
        var groupSeries: Bool
        // Ebooks read aloud
        var source: String
        var kokoroVoice: String
        var deviceVoice: String
        var speed: Double
        var gapMs: Int
        var skipUnit: String
        var fontSize: Double
        var font: String
        var theme: String
        var follow: Bool
        var fadeRead: Bool
        // Words
        var filterEnabled: Bool
        var filterWords: [String]
        var pronunciationRules: [PronunciationRule]
    }

    static let backupManifestName = "backup.json"

    // MARK: Back up

    /// Makes the backup folder in temporary storage and returns it, ready to
    /// be saved to Files or iCloud Drive. The caller deletes it afterwards.
    func makeBackupFolder() async throws -> URL {
        let fm = FileManager.default
        let day = Date().formatted(.iso8601.year().month().day())
        let parent = fm.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("Lamplight Backup \(day)", isDirectory: true)
        let booksOut = root.appendingPathComponent("Books", isDirectory: true)
        try fm.createDirectory(at: booksOut, withIntermediateDirectories: true)

        var entries: [BackupEntry] = []
        var copies: [(URL, URL)] = []
        for book in books {
            let inApp = book.link == nil
            if inApp { copies.append((folder(for: book), booksOut.appendingPathComponent(book.id.uuidString, isDirectory: true))) }
            entries.append(BackupEntry(book: book, hasFiles: inApp))
        }
        importStatus = "Preparing the backup…"
        defer { importStatus = nil }
        try await Task.detached(priority: .userInitiated) {
            for (from, to) in copies { try FileManager.default.copyItem(at: from, to: to) }
        }.value

        let file = BackupFile(settings: Self.currentSettings(), books: entries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: root.appendingPathComponent(Self.backupManifestName), options: .atomic)
        return root
    }

    /// Called once the backup was saved somewhere.
    func backupSaved() {
        UserDefaults.standard.set(Date(), forKey: "rd.lastBackup")
    }

    private static func currentSettings() -> BackupSettings {
        let d = UserDefaults.standard
        let r = ReaderSettings.shared
        return BackupSettings(
            skipBack: d.integer(forKey: Settings.skipBack), skipForward: d.integer(forKey: Settings.skipForward),
            smartRewind: d.bool(forKey: Settings.smartRewind),
            librarySort: d.string(forKey: "librarySort"), libraryShelf: d.string(forKey: "libraryShelf"),
            shelves: r.shelves, groupSeries: r.groupSeries,
            source: r.source.rawValue, kokoroVoice: r.kokoroVoice, deviceVoice: r.deviceVoice, speed: r.speed,
            gapMs: r.gapMs, skipUnit: r.skipUnit.rawValue, fontSize: r.fontSize, font: r.font.rawValue,
            theme: r.theme.rawValue, follow: r.follow, fadeRead: r.fadeRead,
            filterEnabled: r.filterEnabled, filterWords: r.filterWords, pronunciationRules: r.pronunciationRules)
    }

    // MARK: The backup folder (iCloud Drive or anywhere in Files)

    /// Name of the folder backups are saved to, or nil when none was chosen.
    var backupFolderName: String? { UserDefaults.standard.string(forKey: "rd.backupFolderName") }

    /// Remembers a folder (for example in iCloud Drive) to save backups to.
    func setBackupFolder(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            message = "Could not use that folder."
            return
        }
        UserDefaults.standard.set(bookmark, forKey: "rd.backupFolderBookmark")
        UserDefaults.standard.set(url.lastPathComponent, forKey: "rd.backupFolderName")
    }

    func forgetBackupFolder() {
        for key in ["rd.backupFolderBookmark", "rd.backupFolderName"] { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// The chosen backup folder, when it can still be reached.
    func backupFolderURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: "rd.backupFolderBookmark") else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: "rd.backupFolderBookmark")
        }
        return url
    }

    /// Backs up straight into the chosen folder, replacing a backup from the
    /// same day. In iCloud Drive, iOS then uploads it in the background.
    func backUpToFolder() async {
        guard let dest = backupFolderURL() else {
            message = "Can't reach the backup folder. Choose it again in Settings."
            return
        }
        let ok = dest.startAccessingSecurityScopedResource()
        defer { if ok { dest.stopAccessingSecurityScopedResource() } }
        do {
            let made = try await makeBackupFolder()
            defer { try? FileManager.default.removeItem(at: made.deletingLastPathComponent()) }
            importStatus = "Saving the backup to \(dest.lastPathComponent)…"
            defer { importStatus = nil }
            let target = dest.appendingPathComponent(made.lastPathComponent, isDirectory: true)
            try await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                let coordinator = NSFileCoordinator()
                var coordError: NSError?
                var copyError: Error?
                coordinator.coordinate(writingItemAt: target, options: .forReplacing, error: &coordError) { url in
                    do {
                        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
                        try fm.copyItem(at: made, to: url)
                    } catch { copyError = error }
                }
                if let e = coordError ?? copyError { throw e }
            }.value
            backupSaved()
            message = "Backed up to \(dest.lastPathComponent)."
        } catch {
            let full = (error as? CocoaError)?.code == .fileWriteOutOfSpace
            message = full ? "Not enough space in \(dest.lastPathComponent) for the backup."
                : "Could not back up: \(error.localizedDescription)"
        }
    }

    // MARK: Restore

    /// Restores a backup folder: settings are set from it, books that aren't
    /// here are added back, books that are here keep the newer place and gain
    /// any missing bookmarks and shelves. Nothing is deleted.
    func restoreBackupFolder(_ url: URL) async {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        importStatus = "Restoring…"
        defer { importStatus = nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = try? Data(contentsOf: url.appendingPathComponent(Self.backupManifestName)) else {
                message = "That folder isn't a Lamplight backup."
                return
            }
            let file = try decoder.decode(BackupFile.self, from: data)
            Self.apply(file.settings)

            var added = 0, merged = 0, waiting = 0
            for (i, entry) in file.books.enumerated() {
                importStatus = "Restoring \(entry.book.title)…\n\(i + 1) of \(file.books.count)"
                if let local = match(for: entry.book) {
                    mergeRecord(entry.book, into: local.id)
                    merged += 1
                } else if entry.hasFiles {
                    let from = url.appendingPathComponent("Books", isDirectory: true).appendingPathComponent(entry.book.id.uuidString, isDirectory: true)
                    let to = folder(for: entry.book)
                    try await Task.detached(priority: .userInitiated) {
                        let fm = FileManager.default
                        if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
                        try fm.copyItem(at: from, to: to)
                    }.value
                    books.append(entry.book)
                    reloadCover(entry.book)
                    save()
                    added += 1
                } else {
                    addPendingRestore(entry.book)
                    waiting += 1
                }
            }
            save()
            var parts = ["\(added) book\(added == 1 ? "" : "s") added", "\(merged) updated"]
            if waiting > 0 { parts.append("\(waiting) linked audiobook\(waiting == 1 ? "" : "s") will get \(waiting == 1 ? "its" : "their") place back when linked again") }
            message = "Restored: " + parts.joined(separator: ", ") + "."
        } catch {
            let full = (error as? CocoaError)?.code == .fileWriteOutOfSpace
            message = full ? "Not enough storage space on this \(ThisDevice.name) to restore everything."
                : "Could not restore: \(error.localizedDescription)"
        }
    }

    private static func apply(_ s: BackupSettings) {
        let d = UserDefaults.standard
        let r = ReaderSettings.shared
        d.set(s.skipBack, forKey: Settings.skipBack)
        d.set(s.skipForward, forKey: Settings.skipForward)
        d.set(s.smartRewind, forKey: Settings.smartRewind)
        if let v = s.librarySort { d.set(v, forKey: "librarySort") }
        if let v = s.libraryShelf { d.set(v, forKey: "libraryShelf") }
        for shelf in s.shelves where !r.shelves.contains(shelf) { r.shelves.append(shelf) }
        r.groupSeries = s.groupSeries
        if let v = VoiceSource(rawValue: s.source) { r.source = v }
        r.kokoroVoice = s.kokoroVoice
        // Apple's voices differ between devices; keep this one's if the saved one isn't here.
        if DeviceVoice.voices().contains(where: { $0.id == s.deviceVoice }) { r.deviceVoice = s.deviceVoice }
        r.speed = s.speed
        r.gapMs = s.gapMs
        if let v = SkipUnit(rawValue: s.skipUnit) { r.skipUnit = v }
        r.fontSize = s.fontSize
        if let v = ReaderFont(rawValue: s.font) { r.font = v }
        if let v = ReaderTheme(rawValue: s.theme) { r.theme = v }
        r.follow = s.follow
        r.fadeRead = s.fadeRead
        r.filterEnabled = s.filterEnabled
        for w in s.filterWords where !r.filterWords.contains(w) { r.filterWords.append(w) }
        for rule in s.pronunciationRules where !r.pronunciationRules.contains(where: {
            $0.find == rule.find && $0.replace == rule.replace && $0.matchCase == rule.matchCase
        }) {
            r.pronunciationRules.append(rule)
        }
    }

    /// The book in this library that a backed-up record belongs to: the same
    /// book, the same ebook file, or an audiobook with the same title and length.
    private func match(for other: Book) -> Book? {
        if let same = books.first(where: { $0.id == other.id }) { return same }
        if let name = other.text?.sourceName {
            return books.first { $0.text?.sourceName.lowercased() == name.lowercased() }
        }
        return books.first { !$0.isText && $0.title == other.title && abs($0.duration - other.duration) < 2 }
    }

    /// Adds the record's shelves, series and bookmarks to a book, and its
    /// place when that is newer.
    func mergeRecord(_ e: Book, into id: UUID) {
        mutate(id) { b in
            for s in e.shelves where !b.shelves.contains(s) { b.shelves.append(s) }
            if b.series.isEmpty, !b.seriesManual, !e.series.isEmpty {
                b.series = e.series; b.seriesIndex = e.seriesIndex; b.seriesManual = e.seriesManual
            }
            for m in e.bookmarks where !b.bookmarks.contains(where: { $0.id == m.id }) { b.bookmarks.append(m) }
            if b.text != nil {
                if let at = e.text?.positionAt, at > (b.text?.positionAt ?? .distantPast) {
                    b.text?.chapter = e.text?.chapter ?? 0
                    b.text?.sentence = e.text?.sentence ?? 0
                    b.text?.charsRead = e.text?.charsRead ?? 0
                    b.text?.positionAt = at
                    b.finished = e.finished
                    b.lastPlayed = max(b.lastPlayed ?? .distantPast, e.lastPlayed ?? .distantPast)
                }
            } else if let at = e.lastPlayed, at > (b.lastPlayed ?? .distantPast) {
                b.position = min(e.position, b.duration)
                b.lastPlayed = at
                b.finished = e.finished
                b.speed = e.speed
                b.muteLanguage = e.muteLanguage
            }
        }
    }

    // MARK: Linked audiobooks waiting to be linked again

    private var pendingRestoreURL: URL { booksDir.deletingLastPathComponent().appendingPathComponent("restore-pending.json") }

    private func pendingRestores() -> [Book] {
        (try? Data(contentsOf: pendingRestoreURL)).flatMap { try? JSONDecoder().decode([Book].self, from: $0) } ?? []
    }

    private func setPendingRestores(_ list: [Book]) {
        if list.isEmpty { try? FileManager.default.removeItem(at: pendingRestoreURL); return }
        try? JSONEncoder().encode(list).write(to: pendingRestoreURL, options: .atomic)
    }

    private func addPendingRestore(_ book: Book) {
        var list = pendingRestores()
        list.removeAll { $0.id == book.id || ($0.title == book.title && abs($0.duration - book.duration) < 2) }
        list.append(book)
        setPendingRestores(list)
    }

    /// A newly added audiobook picks up the place, bookmarks and shelves a
    /// restored backup had for it.
    func applyPendingRestore(to book: Book) {
        var list = pendingRestores()
        guard let i = list.firstIndex(where: { !$0.isText && $0.title == book.title && abs($0.duration - book.duration) < 2 }) else { return }
        mergeRecord(list.remove(at: i), into: book.id)
        setPendingRestores(list)
    }
}
