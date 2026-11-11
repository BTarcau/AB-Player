import AVFoundation
import UIKit

/// A set of files that will become one book.
struct ImportGroup {
    var title: String?          // nil: take it from the files' tags
    var authorHint: String?     // parent folder name in an Author/Book layout
    var audio: [URL]
    var images: [URL]
    var folder: URL? = nil      // the book's folder, for naming files in disc subfolders
}

enum ImportError: LocalizedError {
    case noPlayableAudio
    var errorDescription: String? {
        "None of the files could be played. Lamplight can play MP3, M4A/M4B, AAC, WAV, FLAC and AIFF."
    }
}

/// Turns picked folders and files into books: works out which files belong
/// together, copies them into the app, and reads lengths, chapters, tags and
/// cover art.
enum Importer {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "mp4", "aac", "wav", "flac", "aif", "aiff", "aifc", "caf"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "webp", "gif"]

    static func isAudio(_ url: URL) -> Bool { audioExtensions.contains(url.pathExtension.lowercased()) }
    static func isImage(_ url: URL) -> Bool { imageExtensions.contains(url.pathExtension.lowercased()) }
    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    static func naturalLess(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }

    private static let discRegex = try! NSRegularExpression(
        pattern: #"^(cd|disc|disk|part|pt|volume|vol)[\s._-]*\d+"#, options: .caseInsensitive)

    static func isDiscFolder(_ name: String) -> Bool {
        discRegex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    // MARK: Folder tree

    final class Node {
        let url: URL
        var files: [URL] = []
        var dirs: [Node] = []
        init(url: URL) { self.url = url }

        var name: String { url.lastPathComponent }
        var directAudio: [URL] { files.filter(Importer.isAudio) }
        var containsAudio: Bool { files.contains(where: Importer.isAudio) || dirs.contains { $0.containsAudio } }
        /// Every audio file in this folder and below, in play order.
        var allAudio: [URL] { directAudio + dirs.flatMap(\.allAudio) }
        var allImages: [URL] { files.filter(Importer.isImage) + dirs.flatMap(\.allImages) }
    }

    static func scan(_ url: URL) -> Node {
        let node = Node(url: url)
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        for var item in items {
            let name = item.lastPathComponent
            if name.hasPrefix(".") {
                // Older iCloud placeholders: ".Chapter 1.mp3.icloud" stands for "Chapter 1.mp3".
                guard name.hasSuffix(".icloud"), name.count > 8 else { continue }
                item = url.appendingPathComponent(String(name.dropFirst().dropLast(7)))
            }
            if isDirectory(item) { node.dirs.append(scan(item)) } else { node.files.append(item) }
        }
        node.dirs.sort { naturalLess($0.name, $1.name) }
        node.files.sort { naturalLess($0.lastPathComponent, $1.lastPathComponent) }
        return node
    }

    // MARK: Grouping

    /// - A folder with audio in it, or only CD1/Disc 2/Part 3 subfolders: one book.
    /// - A folder of M4B files with different album tags: one book per album.
    /// - A folder of book folders (any depth, e.g. Author/Book): one book per folder.
    static func groups(forFolder url: URL) async -> [ImportGroup] {
        await groups(scan(url), isRoot: true, hint: nil)
    }

    private static func groups(_ node: Node, isRoot: Bool, hint: String?) async -> [ImportGroup] {
        let audioDirs = node.dirs.filter(\.containsAudio)
        let direct = node.directAudio
        if !direct.isEmpty {
            if direct.count > 1, audioDirs.isEmpty, direct.allSatisfy({ $0.pathExtension.lowercased() == "m4b" }) {
                let split = await splitByAlbum(direct)
                if split.count > 1 {
                    return split.map { ImportGroup(title: nil, authorHint: hint, audio: $0, images: []) }
                }
            }
            return [ImportGroup(title: node.name, authorHint: hint, audio: node.allAudio, images: node.allImages, folder: node.url)]
        }
        if audioDirs.isEmpty { return [] }
        if audioDirs.allSatisfy({ isDiscFolder($0.name) }) {
            return [ImportGroup(title: node.name, authorHint: hint, audio: node.allAudio, images: node.allImages, folder: node.url)]
        }
        // A folder of books. Below the folder the person picked, its name is
        // probably the author's (Audiobooks/Author/Book).
        let childHint = isRoot ? hint : node.name
        var out: [ImportGroup] = []
        for dir in audioDirs { out += await groups(dir, isRoot: false, hint: childHint) }
        return out
    }

    /// Loose files picked one by one, or dropped into the app's Files folder.
    static func groups(forFiles files: [URL]) async -> [ImportGroup] {
        let audio = files.filter(isAudio).sorted { naturalLess($0.lastPathComponent, $1.lastPathComponent) }
        guard !audio.isEmpty else { return [] }
        if audio.count > 1, audio.allSatisfy({ $0.pathExtension.lowercased() == "m4b" }) {
            return await splitByAlbum(audio).map { ImportGroup(title: nil, authorHint: nil, audio: $0, images: []) }
        }
        return [ImportGroup(title: nil, authorHint: nil, audio: audio, images: files.filter(isImage))]
    }

    /// Files sharing an album tag stay together (Part 1.m4b, Part 2.m4b);
    /// untagged files are each their own book.
    private static func splitByAlbum(_ files: [URL]) async -> [[URL]] {
        var order: [String] = []
        var byAlbum: [String: [URL]] = [:]
        for url in files {
            _ = await ensureLocal(url)
            let album = await stringValue(AVURLAsset(url: url), key: .commonKeyAlbumName)
            let key = album.map { "album:" + $0.lowercased() } ?? "file:" + url.path
            if byAlbum[key] == nil { order.append(key) }
            byAlbum[key, default: []].append(url)
        }
        return order.compactMap { byAlbum[$0] }
    }

    // MARK: Reading files

    struct FileInfo {
        var duration: Double = 0
        var title: String?
        var album: String?
        var artist: String?
        var albumArtist: String?
        var composer: String?
        var artwork: Data?
        var chapters: [(title: String, start: Double)] = []
    }

    static func readInfo(_ url: URL, wantArtwork: Bool) async -> FileInfo {
        // MP3 lengths are only exact if the whole file is scanned (VBR files).
        let precise = url.pathExtension.lowercased() == "mp3"
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: precise])
        var info = FileInfo()
        if let d = try? await asset.load(.duration), d.isNumeric { info.duration = d.seconds }
        let common = (try? await asset.load(.commonMetadata)) ?? []
        let all = (try? await asset.load(.metadata)) ?? []
        info.title = await string(in: common, key: .commonKeyTitle)
        info.album = await string(in: common, key: .commonKeyAlbumName)
        info.artist = await string(in: common, key: .commonKeyArtist)
        info.albumArtist = await string(in: all, ids: [.iTunesMetadataAlbumArtist, .id3MetadataBand])
        info.composer = await string(in: all, ids: [.iTunesMetadataComposer, .id3MetadataComposer])
        if wantArtwork {
            for item in AVMetadataItem.metadataItems(from: common, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common) {
                if let data = try? await item.load(.dataValue), UIImage(data: data) != nil { info.artwork = data; break }
            }
        }
        var groups = (try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages)) ?? []
        if groups.isEmpty, let locale = (try? await asset.load(.availableChapterLocales))?.first {
            groups = (try? await asset.loadChapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: [])) ?? []
        }
        for (i, group) in groups.enumerated() {
            let title = await string(in: group.items, key: .commonKeyTitle) ?? "Chapter \(i + 1)"
            let start = group.timeRange.start.seconds
            if start.isFinite { info.chapters.append((title, max(0, start))) }
        }
        info.chapters.sort { $0.start < $1.start }
        return info
    }

    private static func string(in items: [AVMetadataItem], key: AVMetadataKey) async -> String? {
        for item in AVMetadataItem.metadataItems(from: items, withKey: key, keySpace: .common) {
            if let s = try? await item.load(.stringValue), let t = clean(s) { return t }
        }
        return nil
    }

    private static func string(in items: [AVMetadataItem], ids: [AVMetadataIdentifier]) async -> String? {
        for id in ids {
            for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id) {
                if let s = try? await item.load(.stringValue), let t = clean(s) { return t }
            }
        }
        return nil
    }

    private static func stringValue(_ asset: AVURLAsset, key: AVMetadataKey) async -> String? {
        let common = (try? await asset.load(.commonMetadata)) ?? []
        return await string(in: common, key: key)
    }

    private static func clean(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func cleanName(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? url.lastPathComponent : name
    }

    /// The common start of the file names, e.g. "The Hobbit" from "The Hobbit 01", "The Hobbit 02".
    static func guessTitle(_ files: [URL]) -> String {
        let names = files.map(cleanName)
        guard var prefix = names.first else { return "New Book" }
        if names.count == 1 { return prefix }
        for name in names.dropFirst() {
            prefix = String(zip(prefix, name).prefix { $0.lowercased() == $1.lowercased() }.map(\.0))
        }
        prefix = prefix.replacingOccurrences(of: #"[\s\d._\-–—()\[\]#]+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return prefix.count >= 3 ? prefix : "New Book"
    }

    private static func pickCover(_ images: [URL]) -> URL? {
        images.first { $0.lastPathComponent.range(of: #"^(cover|folder|front)\b"#, options: [.regularExpression, .caseInsensitive]) != nil }
            ?? images.first
    }

    // MARK: Files that live in iCloud or another provider

    /// True when the file is in iCloud and not on this iPhone right now.
    static func needsDownload(_ url: URL) -> Bool {
        let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
        return status != nil && status != .current
    }

    /// Make sure a file's contents are on the device, downloading it from
    /// iCloud (or another Files provider) if needed. Returns false if it can't
    /// be read.
    static func ensureLocal(_ url: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            var error: NSError?
            var readable = false
            // A coordinated read makes the provider fetch the file and waits for it.
            NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &error) { local in
                readable = FileManager.default.isReadableFile(atPath: local.path)
            }
            return error == nil && readable
        }.value
    }

    /// Start downloading in the background without waiting (the next file of a book).
    static func prefetch(_ url: URL) {
        Task.detached(priority: .utility) {
            if needsDownload(url) { _ = await ensureLocal(url) }
        }
    }

    static func relativePath(_ url: URL, from root: URL) -> String {
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base) else { return url.lastPathComponent }
        return String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: Importing

    enum Placement {
        /// Copy the audio into this folder inside the app.
        case copy(to: URL)
        /// Leave the audio where it is; file names are stored relative to `root`.
        case link(root: URL)
    }

    /// Length and chapters already known for a file (chapter starts relative to the file).
    struct KnownFile {
        var duration: Double
        var chapters: [Chapter]
    }

    struct ReadTracks {
        var tracks: [Track] = []
        var chapters: [Chapter] = []
        var first: FileInfo?
        var artwork: Data?
    }

    /// Reads (and copies, if asked) a book's audio files in play order.
    /// `progress` gets (file number, file count, downloading from iCloud).
    static func readTracks(_ audio: [URL], folder: URL?, placement: Placement,
                           known: [String: KnownFile] = [:],
                           progress: @escaping @MainActor (Int, Int, Bool) -> Void) async throws -> ReadTracks {
        let fm = FileManager.default
        var out = ReadTracks()
        var start = 0.0
        for (i, src) in audio.enumerated() {
            await progress(i + 1, audio.count, needsDownload(src))
            var trackTitle = cleanName(src)
            // "CD2 · 01 Track" for files in disc subfolders
            if let folder {
                let parent = src.deletingLastPathComponent().standardizedFileURL
                if parent != folder.standardizedFileURL { trackTitle = parent.lastPathComponent + " · " + trackTitle }
            }

            let name: String
            let playURL: URL
            switch placement {
            case .copy(let dir):
                name = String(format: "%03d.%@", i + 1, src.pathExtension.lowercased())
                playURL = dir.appendingPathComponent(name)
                _ = await ensureLocal(src)
                try fm.copyItem(at: src, to: playURL)
            case .link(let root):
                name = relativePath(src, from: root)
                playURL = src
            }

            if let k = known[name], k.duration > 0 {
                out.tracks.append(Track(file: name, title: trackTitle, duration: k.duration))
                out.chapters += k.chapters.map { Chapter(title: $0.title, start: start + $0.start) }
                start += k.duration
                continue
            }

            if case .link = placement, !(await ensureLocal(playURL)) { continue }
            let info = await readInfo(playURL, wantArtwork: out.artwork == nil && i < 3)
            guard info.duration > 0 else {
                if case .copy = placement { try? fm.removeItem(at: playURL) }   // not playable on iPhone (e.g. Ogg)
                continue
            }
            if out.first == nil { out.first = info }
            if out.artwork == nil { out.artwork = info.artwork }
            out.tracks.append(Track(file: name, title: trackTitle, duration: info.duration))
            if info.chapters.isEmpty {
                let title = audio.count == 1 ? (info.title ?? trackTitle) : trackTitle
                out.chapters.append(Chapter(title: title, start: start))
            } else {
                if let firstStart = info.chapters.first?.start, firstStart > 1 {
                    out.chapters.append(Chapter(title: trackTitle, start: start))
                }
                out.chapters += info.chapters.map { Chapter(title: $0.title, start: start + $0.start) }
            }
            start += info.duration
        }
        return out
    }

    /// Creates a book from a group. With `linkRoot`, the audio stays in place
    /// and only the cover is stored in the app; otherwise everything is copied.
    /// (On APFS a copy is a clone: instant, and no extra space until the
    /// original is changed or deleted.)
    static func importGroup(_ group: ImportGroup, booksDir: URL, linkRoot: URL? = nil,
                            progress: @escaping @MainActor (Int, Int, Bool) -> Void) async throws -> Book {
        let fm = FileManager.default
        let id = UUID()
        let dir = booksDir.appendingPathComponent(id.uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let placement: Placement = linkRoot.map { .link(root: $0) } ?? .copy(to: dir)
            let read = try await readTracks(group.audio, folder: group.folder, placement: placement, progress: progress)
            guard !read.tracks.isEmpty else { throw ImportError.noPlayableAudio }
            let first = read.first

            var title = group.title
                ?? first?.album
                ?? (group.audio.count == 1 ? first?.title : nil)
                ?? guessTitle(group.audio)
            var author = first?.albumArtist ?? first?.artist ?? group.authorHint ?? ""
            if author.isEmpty, let dash = title.range(of: " - ") {
                // "Author - Title" folder names
                author = String(title[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
                title = String(title[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            if author.caseInsensitiveCompare("Various Artists") == .orderedSame { author = "" }

            var coverFile: String?
            if let image = pickCover(group.images) {
                let name = "cover." + image.pathExtension.lowercased()
                _ = await ensureLocal(image)
                if (try? fm.copyItem(at: image, to: dir.appendingPathComponent(name))) != nil { coverFile = name }
            }
            if coverFile == nil, let artwork = read.artwork,
               (try? artwork.write(to: dir.appendingPathComponent("cover.art"))) != nil {
                coverFile = "cover.art"
            }

            return Book(id: id, title: title, author: author, narrator: first?.composer ?? "",
                        tracks: read.tracks, chapters: read.chapters, coverFile: coverFile)
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
    }
}
