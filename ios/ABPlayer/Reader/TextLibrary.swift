import Foundation
import UIKit

extension Importer {
    static let ebookExtensions: Set<String> = ["epub", "pdf"]
    static func isEbook(_ url: URL) -> Bool { ebookExtensions.contains(url.pathExtension.lowercased()) }

    /// Every EPUB and PDF in a folder and its subfolders.
    static func ebooks(in folder: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { $0 as? URL }.filter(isEbook).sorted { naturalLess($0.lastPathComponent, $1.lastPathComponent) }
    }
}

extension Library {
    // MARK: Parsed text

    /// Bump the version when parsing changes, so books are read again from their files.
    nonisolated static let textCacheName = "text-2.json"
    func textCacheURL(_ book: Book) -> URL { folder(for: book).appendingPathComponent(Self.textCacheName) }

    /// The book's chapters and sentences, from the cache or parsed from the file again.
    func parsedText(for book: Book) async throws -> ParsedText {
        guard let info = book.text else { throw BookParseError.unreadable }
        let cache = textCacheURL(book)
        let file = folder(for: book).appendingPathComponent(info.file)
        return try await Task.detached(priority: .userInitiated) {
            if let data = try? Data(contentsOf: cache), let parsed = try? JSONDecoder().decode(ParsedText.self, from: data) {
                return parsed
            }
            var parsed = try Self.parseEbook(at: file, format: info.format)
            parsed.cover = nil
            try? JSONEncoder().encode(parsed).write(to: cache, options: .atomic)
            try? FileManager.default.removeItem(at: cache.deletingLastPathComponent().appendingPathComponent("text.json"))
            return parsed
        }.value
    }

    nonisolated static func parseEbook(at url: URL, format: String) throws -> ParsedText {
        if format == "pdf" { return try PDFTextParser.parse(url: url) }
        return try EPUBParser.parse(Data(contentsOf: url, options: .mappedIfSafe))
    }

    // MARK: Importing EPUB and PDF

    enum EbookResult { case added(Book), duplicate }

    /// Copies an EPUB/PDF into the app, reads its chapters and metadata, and adds it.
    /// `suggestShelves` puts it on shelves matching its subjects (not for watched folders).
    func importEbook(_ src: URL, suggestShelves: Bool = true) async throws -> EbookResult {
        let name = src.lastPathComponent
        if books.contains(where: { b in
            guard let t = b.text else { return false }
            return ([t.sourceName] + (t.formerNames ?? [])).contains { $0.lowercased() == name.lowercased() }
        }) { return .duplicate }
        undismiss(name)
        let format = src.pathExtension.lowercased() == "pdf" ? "pdf" : "epub"
        let id = UUID()
        let dir = booksDir.appendingPathComponent(id.uuidString, isDirectory: true)
        let fileName = "book." + format
        let parsed: ParsedText
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            _ = await Importer.ensureLocal(src)
            try FileManager.default.copyItem(at: src, to: dir.appendingPathComponent(fileName))
            let dest = dir.appendingPathComponent(fileName)
            parsed = try await Task.detached(priority: .userInitiated) {
                var p = try Self.parseEbook(at: dest, format: format)
                let cover = p.cover
                p.cover = nil
                try JSONEncoder().encode(p).write(to: dir.appendingPathComponent(Self.textCacheName), options: .atomic)
                p.cover = cover
                return p
            }.value
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }

        var coverFile: String?
        if let cover = parsed.cover, (try? cover.write(to: dir.appendingPathComponent("cover.art"))) != nil { coverFile = "cover.art" }
        let chars = parsed.chapters.map(\.charCount)
        var start = 0.0
        let chapters = parsed.chapters.enumerated().map { i, c -> Chapter in
            defer { start += Double(chars[i]) * 0.075 }
            return Chapter(title: c.title, start: start)
        }
        let fallbackTitle = src.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
        var book = Book(id: id, title: parsed.title.isEmpty ? fallbackTitle : parsed.title, author: parsed.author,
                        tracks: [], chapters: chapters, coverFile: coverFile)
        book.text = TextInfo(file: fileName, format: format, sourceName: name, chapterTitles: parsed.chapters.map(\.title),
                             chapterChars: chars, totalChars: chars.reduce(0, +), subjects: parsed.subjects)
        book.series = parsed.series
        book.seriesIndex = parsed.seriesIndex
        if suggestShelves { book.shelves = ReaderSettings.shared.suggestShelves(parsed.subjects) }
        books.append(book)
        reloadCover(book)
        save()
        return .added(book)
    }

    // MARK: Removed on purpose

    /// A watched folder mustn't bring back a book that was deleted while its file is still there.
    private static let dismissedKey = "rd.dismissed"
    func dismiss(_ name: String) {
        var list = UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? []
        if !list.contains(name.lowercased()) { list.append(name.lowercased()) }
        UserDefaults.standard.set(list, forKey: Self.dismissedKey)
    }
    func undismiss(_ name: String) {
        let list = (UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? []).filter { $0 != name.lowercased() }
        UserDefaults.standard.set(list, forKey: Self.dismissedKey)
    }
    var dismissed: Set<String> { Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? []) }

    // MARK: Watched folder

    var watchedFolderName: String? { UserDefaults.standard.string(forKey: "rd.watchName") }
    var watchedLastScan: Date? { UserDefaults.standard.object(forKey: "rd.watchLastScan") as? Date }

    func setWatchedFolder(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            message = "Could not use that folder."
            return
        }
        UserDefaults.standard.set(bookmark, forKey: "rd.watchBookmark")
        UserDefaults.standard.set(url.lastPathComponent, forKey: "rd.watchName")
        UserDefaults.standard.removeObject(forKey: "rd.watchLastScan")
        Task { await scanWatchedFolder(announce: true) }
    }

    func stopWatching() {
        for key in ["rd.watchBookmark", "rd.watchName", "rd.watchLastScan"] { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// Adds new EPUBs and PDFs from the watched folder (and its subfolders), without a shelf.
    func scanWatchedFolder(announce: Bool) async {
        guard importStatus == nil, let data = UserDefaults.standard.data(forKey: "rd.watchBookmark") else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            if announce { message = "Can't reach the watched folder. Choose it again in Settings." }
            return
        }
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        if stale, let fresh = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: "rd.watchBookmark")
        }
        let known = Set(books.flatMap { b -> [String] in
            guard let t = b.text else { return [] }
            return ([t.sourceName] + (t.formerNames ?? [])).map { $0.lowercased() }
        }).union(dismissed)
        let found = Importer.ebooks(in: url)
        let new = found.filter { !known.contains($0.lastPathComponent.lowercased()) }
        UserDefaults.standard.set(Date(), forKey: "rd.watchLastScan")
        guard !new.isEmpty else {
            if announce { message = "No new books (\(found.count) checked)." }
            return
        }
        importStatus = "Watched folder"
        defer { importStatus = nil }
        var added = 0
        for (i, file) in new.enumerated() {
            importStatus = "Adding \(file.lastPathComponent)…\n\(i + 1) of \(new.count)"
            if case .added = try? await importEbook(file, suggestShelves: false) { added += 1 }
        }
        message = "Added \(added) new book\(added == 1 ? "" : "s")."
    }

    // MARK: Backup and restore

    struct BackupBook: Codable {
        var title: String, author: String, narrator: String?
        var kind: String              // "text" | "audio"
        var sourceName: String?       // text books
        var file: String?             // path in the zip
        var cover: String?
        var duration: Double?         // audiobooks, to match them up
        var shelves: [String], series: String, seriesIndex: Double?, seriesManual: Bool
        var finished: Bool, lastPlayed: Date?
        var position: Double?         // audiobooks
        var chapter: Int?, sentence: Int?, charsRead: Int?, positionAt: Date?   // text books
        var bookmarks: [Bookmark]?
    }

    struct BackupManifest: Codable {
        var version = 1
        var exportedAt = Date()
        var shelves: [String]
        var filterWords: [String]
        var pronunciationRules: [PronunciationRule]
        var books: [BackupBook]
    }

    /// One file with every EPUB/PDF, covers, shelves, series and every book's place.
    /// Audiobook audio isn't included (it's too large); their places and shelves are.
    func exportBackup() async throws -> URL {
        let settings = ReaderSettings.shared
        var zip = ZipWriter()
        var entries: [BackupBook] = []
        for book in books {
            let folder = folder(for: book)
            var entry = BackupBook(title: book.title, author: book.author, narrator: book.narrator, kind: book.isText ? "text" : "audio",
                                   shelves: book.shelves, series: book.series, seriesIndex: book.seriesIndex, seriesManual: book.seriesManual,
                                   finished: book.finished, lastPlayed: book.lastPlayed, bookmarks: book.bookmarks)
            if let text = book.text {
                entry.sourceName = text.sourceName
                entry.chapter = text.chapter
                entry.sentence = text.sentence
                entry.charsRead = text.charsRead
                entry.positionAt = text.positionAt
                if let data = try? Data(contentsOf: folder.appendingPathComponent(text.file)) {
                    entry.file = "books/\(book.id.uuidString)/\(text.sourceName)"
                    zip.add(entry.file!, data)
                }
            } else {
                entry.duration = book.duration
                entry.position = book.position
            }
            if let c = book.coverFile, let data = try? Data(contentsOf: folder.appendingPathComponent(c)) {
                entry.cover = "covers/\(book.id.uuidString)"
                zip.add(entry.cover!, data)
            }
            entries.append(entry)
        }
        let manifest = BackupManifest(shelves: settings.shelves, filterWords: settings.filterWords,
                                      pronunciationRules: settings.pronunciationRules, books: entries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        zip.add("lamplight-backup.json", try encoder.encode(manifest))
        let day = Date().formatted(.iso8601.year().month().day())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Lamplight backup \(day).zip")
        try zip.finish().write(to: url, options: .atomic)
        UserDefaults.standard.set(Date(), forKey: "rd.lastBackup")
        return url
    }

    /// Merges a backup: adds what's missing, unions shelves and words, newer places win, nothing is deleted.
    func importBackup(_ url: URL) async {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        importStatus = "Restoring…"
        defer { importStatus = nil }
        do {
            let zip = try ZipReader(data: Data(contentsOf: url, options: .mappedIfSafe))
            guard let data = try zip.read("lamplight-backup.json") else { throw BookParseError.unreadable }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(BackupManifest.self, from: data)
            let settings = ReaderSettings.shared
            for s in manifest.shelves where !settings.shelves.contains(s) { settings.shelves.append(s) }
            for w in manifest.filterWords where !settings.filterWords.contains(w) { settings.filterWords.append(w) }
            for r in manifest.pronunciationRules where !settings.pronunciationRules.contains(where: { $0.find == r.find && $0.replace == r.replace && $0.matchCase == r.matchCase }) {
                settings.pronunciationRules.append(r)
            }

            var added = 0, merged = 0, moved = 0
            for entry in manifest.books {
                var local: Book?
                if entry.kind == "text", let name = entry.sourceName {
                    local = books.first { $0.text?.sourceName.lowercased() == name.lowercased() }
                    if local == nil, let path = entry.file, let bytes = try zip.read(path) {
                        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                        let file = tmp.appendingPathComponent(name)
                        try bytes.write(to: file)
                        if case .added(let b) = try await importEbook(file, suggestShelves: false) {
                            mutate(b.id) {
                                $0.title = entry.title; $0.author = entry.author
                                $0.shelves = entry.shelves; $0.series = entry.series; $0.seriesIndex = entry.seriesIndex
                                $0.seriesManual = entry.seriesManual; $0.finished = entry.finished; $0.lastPlayed = entry.lastPlayed
                                $0.text?.chapter = entry.chapter ?? 0; $0.text?.sentence = entry.sentence ?? 0
                                $0.text?.charsRead = entry.charsRead ?? 0; $0.text?.positionAt = entry.positionAt
                                $0.bookmarks = entry.bookmarks ?? []
                            }
                            added += 1
                        }
                        try? FileManager.default.removeItem(at: tmp)
                        continue
                    }
                } else if let d = entry.duration {
                    local = books.first { !$0.isText && $0.title == entry.title && abs($0.duration - d) < 2 }
                }
                guard let local else { continue }
                merged += 1
                var movedThis = false
                mutate(local.id) { b in
                    for s in entry.shelves where !b.shelves.contains(s) { b.shelves.append(s) }
                    if b.author.isEmpty { b.author = entry.author }
                    if b.series.isEmpty && !b.seriesManual && !entry.series.isEmpty {
                        b.series = entry.series; b.seriesIndex = entry.seriesIndex; b.seriesManual = entry.seriesManual
                    }
                    for m in entry.bookmarks ?? [] where !b.bookmarks.contains(where: { $0.id == m.id }) { b.bookmarks.append(m) }
                    if b.text != nil {
                        if let at = entry.positionAt, at > (b.text?.positionAt ?? .distantPast) {
                            b.text?.chapter = entry.chapter ?? 0; b.text?.sentence = entry.sentence ?? 0
                            b.text?.charsRead = entry.charsRead ?? 0; b.text?.positionAt = at
                            b.finished = entry.finished; movedThis = true
                        }
                    } else if let at = entry.lastPlayed, at > (b.lastPlayed ?? .distantPast), let p = entry.position {
                        b.position = p; b.lastPlayed = at; b.finished = entry.finished; movedThis = true
                    }
                }
                if movedThis { moved += 1 }
                if local.coverFile == nil, let c = entry.cover, let img = try zip.read(c) { setCover(img, for: local) }
            }
            message = "Restored: \(added) book\(added == 1 ? "" : "s") added, \(merged) merged, \(moved) place\(moved == 1 ? "" : "s") moved forward."
        } catch {
            message = "Could not restore: \(error.localizedDescription)"
        }
    }
}
