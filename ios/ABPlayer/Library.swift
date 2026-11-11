import Foundation
import ImageIO
import Observation
import UIKit

/// The books on this phone. Book records live in `library.json`; each book's
/// files live in their own folder under Application Support.
@MainActor @Observable
final class Library {
    var books: [Book] = []
    /// Shown over the app while an import runs.
    var importStatus: String?
    /// A short message shown at the bottom of the screen.
    var message: String?
    private(set) var covers: [UUID: UIImage] = [:]
    /// Linked folders resolved from their bookmarks, kept open for the app's lifetime.
    @ObservationIgnored private var roots: [Data: URL] = [:]

    let booksDir: URL
    /// The app's folder in the Files app ("On My iPhone › Lamplight").
    let filesDir: URL
    private let libraryFile: URL
    static let readmeName = "Put audiobook folders here.txt"

    init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = support.appendingPathComponent("Library", isDirectory: true)
        booksDir = base.appendingPathComponent("Books", isDirectory: true)
        libraryFile = base.appendingPathComponent("library.json")
        filesDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: booksDir, withIntermediateDirectories: true)
        writeReadme()
        load()
    }

    // MARK: Storage

    private func load() {
        guard let data = try? Data(contentsOf: libraryFile) else { return }
        do {
            books = try JSONDecoder().decode([Book].self, from: data)
            removeUnusedFolders()
        } catch {
            // Keep the unreadable file rather than overwriting it on the next save.
            try? FileManager.default.copyItem(
                at: libraryFile, to: libraryFile.deletingLastPathComponent().appendingPathComponent("library-unreadable-\(Int(Date().timeIntervalSince1970)).json"))
            message = "Could not read the library: \(error.localizedDescription)"
        }
        for book in books { reloadCover(book) }
    }

    /// Deletes book folders that no book in the library uses any more (left by
    /// an interrupted import or a library edited outside the app). Only runs
    /// after the library file was read successfully and isn't empty, only
    /// touches folders named like a book id, and decides which folders go
    /// before anything else can start an import.
    private func removeUnusedFolders() {
        guard !books.isEmpty else { return }
        let used = Set(books.map(\.id))
        let fm = FileManager.default
        let unused = ((try? fm.contentsOfDirectory(at: booksDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []).filter { url in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return false }
            return !used.contains(id) && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard !unused.isEmpty else { return }
        Task.detached(priority: .utility) {
            for url in unused { try? FileManager.default.removeItem(at: url) }
        }
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(books)
            try data.write(to: libraryFile, options: [.atomic])
        } catch {
            message = "Could not save: \(error.localizedDescription)"
        }
    }

    private func writeReadme() {
        let url = filesDir.appendingPathComponent(Self.readmeName)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let text = """
        Copy audiobook folders (or single M4B/MP3 files) into this folder.
        Next time you open Lamplight, they are added to your library and removed from here.

        Each folder becomes a book. A folder of book folders adds them all.
        Subfolders named CD1, Disc 2, Part 3 and so on stay together as one book.
        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Access

    func book(_ id: UUID) -> Book? { books.first { $0.id == id } }

    func folder(for book: Book) -> URL { booksDir.appendingPathComponent(book.id.uuidString, isDirectory: true) }

    /// Where a track's audio is. nil if a linked folder can't be reached.
    func url(for book: Book, track index: Int) -> URL? {
        guard book.tracks.indices.contains(index) else { return nil }
        if let link = book.link {
            return rootURL(link)?.appendingPathComponent(book.tracks[index].file)
        }
        return folder(for: book).appendingPathComponent(book.tracks[index].file)
    }

    /// Resolve a linked folder's bookmark and keep access to it.
    func rootURL(_ link: LinkedFolder) -> URL? {
        if let url = roots[link.bookmark] { return url }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: link.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        roots[link.bookmark] = url
        if stale, let fresh = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
            // The folder moved or was renamed: refresh the bookmark for every book that uses it.
            roots[fresh] = url
            for i in books.indices where books[i].link?.bookmark == link.bookmark { books[i].link?.bookmark = fresh }
            save()
        }
        return url
    }

    /// Where a linked book lives, for display: "iCloud Drive › Books › Dune".
    func locationDescription(_ book: Book) -> String {
        guard let link = book.link else { return "Stored in this app" }
        var parts = [link.rootName]
        if let path = link.folderPath, !path.isEmpty { parts += path.split(separator: "/").map(String.init) }
        if let root = rootURL(link), root.path.contains("Mobile Documents") || root.path.contains("iCloud") {
            parts.insert("iCloud Drive", at: 0)
        }
        return parts.joined(separator: " › ")
    }

    func mutate(_ id: UUID, save shouldSave: Bool = true, _ change: (inout Book) -> Void) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        change(&books[i])
        if shouldSave { save() }
    }

    func delete(_ book: Book) {
        if let text = book.text { ([text.sourceName] + (text.formerNames ?? [])).forEach(dismiss) }
        books.removeAll { $0.id == book.id }
        covers[book.id] = nil
        try? FileManager.default.removeItem(at: folder(for: book))
        AudioFilter.remove(book.id)
        save()
    }

    // MARK: Covers

    func cover(for book: Book) -> UIImage? { covers[book.id] }

    func reloadCover(_ book: Book) {
        guard let file = book.coverFile else { covers[book.id] = nil; return }
        covers[book.id] = Self.downsample(folder(for: book).appendingPathComponent(file), maxPixels: 900)
    }

    func setCover(_ data: Data, for book: Book) {
        let name = "cover-\(UUID().uuidString.prefix(8)).art"
        let dir = folder(for: book)
        guard (try? data.write(to: dir.appendingPathComponent(name))) != nil else {
            message = "Could not save that image."
            return
        }
        if let old = book.coverFile { try? FileManager.default.removeItem(at: dir.appendingPathComponent(old)) }
        mutate(book.id) { $0.coverFile = name }
        if let updated = self.book(book.id) { reloadCover(updated) }
    }

    /// Decode a cover at a small size: a full-size scan can take 30+ MB of memory.
    nonisolated static func downsample(_ url: URL, maxPixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    // MARK: Importing

    /// Import picked folders and files. With `removeOriginals`, the originals
    /// are deleted once everything imported (used for the Files-app folder).
    func importItems(_ urls: [URL], removeOriginals: Bool = false, link: Bool = false) async {
        guard importStatus == nil, !urls.isEmpty else { return }
        importStatus = "Preparing…"
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer {
            scoped.forEach { $0.stopAccessingSecurityScopedResource() }
            importStatus = nil
        }

        // Each group remembers the picked folder it came from, for linking.
        var groups: [(group: ImportGroup, root: URL?)] = []
        var loose: [URL] = []
        var ebooks: [URL] = []
        for url in urls {
            if Importer.isDirectory(url) {
                groups += await Importer.groups(forFolder: url).map { ($0, url) }
                ebooks += Importer.ebooks(in: url)
            } else if Importer.isEbook(url) {
                ebooks.append(url)
            } else {
                loose.append(url)
            }
        }
        groups += await Importer.groups(forFiles: loose).map { ($0, nil) }
        guard !groups.isEmpty || !ebooks.isEmpty else {
            message = "No audiobooks, EPUBs or PDFs found in that selection."
            return
        }

        var added: [Book] = []
        var duplicates = 0
        var failure: Error?
        // EPUBs and PDFs are always copied in: they're small, and their text is parsed once.
        for (i, file) in ebooks.enumerated() {
            importStatus = "Reading \(file.lastPathComponent)…" + (ebooks.count > 1 ? "\n\(i + 1) of \(ebooks.count)" : "")
            do {
                switch try await importEbook(file) {
                case .added(let b): added.append(b)
                case .duplicate: duplicates += 1
                }
            } catch {
                failure = error
            }
        }
        for (gi, (group, root)) in groups.enumerated() {
            let label = groups.count > 1 ? "Book \(gi + 1) of \(groups.count)\n" : ""
            let name = group.title ?? Importer.cleanName(group.audio[0])
            let linkRoot = link ? root : nil
            do {
                var linked: LinkedFolder?
                if let linkRoot {
                    let bookmark = try linkRoot.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                    linked = LinkedFolder(bookmark: bookmark, rootName: linkRoot.lastPathComponent,
                                          folderPath: group.folder.map { Importer.relativePath($0, from: linkRoot) })
                }
                var book = try await Importer.importGroup(group, booksDir: booksDir, linkRoot: linkRoot) { [weak self] i, n, downloading in
                    let verb = downloading ? "Downloading file \(i) of \(n) from iCloud…"
                        : (linkRoot == nil ? "Copying file \(i) of \(n)…" : "Reading file \(i) of \(n)…")
                    self?.importStatus = "\(label)\(name)\n\(verb)"
                }
                book.link = linked
                if books.contains(where: { $0.title == book.title && abs($0.duration - book.duration) < 2 }) {
                    try? FileManager.default.removeItem(at: folder(for: book))
                    duplicates += 1
                    continue
                }
                books.append(book)
                reloadCover(book)
                save()
                applyPendingRestore(to: book)
                added.append(book)
            } catch {
                failure = error
            }
        }

        if removeOriginals && failure == nil {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }

        if link, let failure, (failure as? CocoaError)?.code == .fileReadNoPermission {
            message = "Lamplight can't keep access to that folder. Try copying it instead."
            return
        }
        if let failure {
            let full = (failure as? CocoaError)?.code == .fileWriteOutOfSpace
            message = full ? "Not enough storage space on this \(ThisDevice.name) for that book."
                : "Import failed: \(failure.localizedDescription)"
        } else if added.count == 1 {
            message = "Added “\(added[0].title)”"
        } else if added.count > 1 {
            message = "Added \(added.count) books"
        } else if duplicates > 0 {
            message = duplicates == 1 ? "That book is already in your library." : "Those books are already in your library."
        }
    }

    /// Re-read a linked book's folder after files were added, removed or renamed.
    /// Files already known keep their lengths and chapters; the listening
    /// position stays in the same file.
    func rescan(_ book: Book) async -> Bool {
        guard importStatus == nil, let link = book.link else { return false }
        guard let root = rootURL(link) else {
            message = "Can't reach the folder for “\(book.title)”. It may have been moved or deleted."
            return false
        }
        importStatus = "Checking “\(book.title)”…"
        defer { importStatus = nil }

        let audio: [URL]
        let folder: URL?
        if let path = link.folderPath {
            let dir = path.isEmpty ? root : root.appendingPathComponent(path)
            folder = dir
            audio = Importer.scan(dir).allAudio
        } else {
            // A book made of some of the files in a shared folder: keep its files.
            folder = nil
            audio = book.tracks.map { root.appendingPathComponent($0.file) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        let names = audio.map { Importer.relativePath($0, from: root) }
        if names == book.tracks.map(\.file) {
            message = "No changes in “\(book.title)”."
            return false
        }
        guard let read = try? await Importer.readTracks(audio, folder: folder, placement: .link(root: root),
                                                        known: book.knownFiles, progress: { [weak self] i, n, downloading in
            self?.importStatus = downloading ? "Downloading file \(i) of \(n) from iCloud…" : "Reading file \(i) of \(n)…"
        }), !read.tracks.isEmpty else {
            message = "No playable audio is left in the folder for “\(book.title)”."
            return false
        }

        // Keep the place: same file and offset if that file is still there.
        let (oldIndex, offset) = book.locate(book.position)
        let oldFile = book.tracks.indices.contains(oldIndex) ? book.tracks[oldIndex].file : nil
        var position = book.position
        var start = 0.0
        for track in read.tracks {
            if track.file == oldFile { position = start + min(offset, track.duration); break }
            start += track.duration
        }
        let added = Set(read.tracks.map(\.file)).subtracting(book.tracks.map(\.file)).count
        let removed = Set(book.tracks.map(\.file)).subtracting(read.tracks.map(\.file)).count
        let reopen = book.finished && added > 0
        mutate(book.id) {
            $0.tracks = read.tracks
            $0.chapters = read.chapters
            $0.position = min(position, $0.duration)
            if reopen {
                // New files after a finished book (e.g. the next part): carry on from the first new one.
                let firstNew = $0.tracks.firstIndex { !book.tracks.map(\.file).contains($0.file) } ?? 0
                $0.position = $0.trackStarts[firstNew]
                $0.finished = false
            }
        }
        var parts: [String] = []
        if added > 0 { parts.append("\(added) file\(added == 1 ? "" : "s") added") }
        if removed > 0 { parts.append("\(removed) removed") }
        message = parts.isEmpty ? "Updated “\(book.title)”." : "“\(book.title)”: " + parts.joined(separator: ", ")
        return true
    }

    /// Import anything copied into the app's folder in the Files app.
    func scanFilesFolder() async {
        guard importStatus == nil else { return }
        let fm = FileManager.default
        func list(_ dir: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        }
        var items = list(filesDir).filter { $0.lastPathComponent != Self.readmeName }
        // iOS puts files shared to the app with "Open in…" into Documents/Inbox.
        if let inbox = items.first(where: { $0.lastPathComponent == "Inbox" && Importer.isDirectory($0) }) {
            items.removeAll { $0 == inbox }
            items += list(inbox)
        }
        let candidates = items.filter {
            Importer.isDirectory($0) ? (Importer.scan($0).containsAudio || !Importer.ebooks(in: $0).isEmpty)
                : (Importer.isAudio($0) || Importer.isEbook($0))
        }
        guard !candidates.isEmpty else { return }

        // Skip anything still being copied in: its size must hold still.
        let before = candidates.map(Self.totalSize)
        try? await Task.sleep(for: .seconds(1.5))
        let settled = zip(candidates, before).filter { Self.totalSize($0.0) == $0.1 }.map(\.0)
        guard !settled.isEmpty else { return }
        await importItems(settled, removeOriginals: true)
    }

    nonisolated static func totalSize(_ url: URL) -> Int {
        let fm = FileManager.default
        if !Importer.isDirectory(url) {
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        var total = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let file as URL in e {
                total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        return total
    }

    func storageSummary() async -> String {
        let dir = booksDir
        let count = books.count
        let (used, free) = await Task.detached { () -> (Int, Int64) in
            let used = Library.totalSize(dir)
            let free = (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? 0
            return (used, free)
        }.value
        let f = ByteCountFormatter()
        f.countStyle = .file
        return "\(count) book\(count == 1 ? "" : "s") · \(f.string(fromByteCount: Int64(used))) used · \(f.string(fromByteCount: free)) free"
    }
}
