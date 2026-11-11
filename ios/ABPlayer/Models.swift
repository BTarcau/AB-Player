import Foundation

/// One audio file inside a book.
struct Track: Codable, Hashable {
    var file: String        // file name inside the book's folder
    var title: String
    var duration: Double
}

/// A chapter. `start` is measured from the beginning of the whole book.
/// Books with embedded chapters (M4B, chaptered M4A/MP3) use those; otherwise
/// every file is one chapter.
struct Chapter: Codable, Hashable {
    var title: String
    var start: Double
}

struct Bookmark: Codable, Hashable, Identifiable {
    var id = UUID()
    var time: Double
    var note: String = ""
    var created = Date()
}

/// A book whose audio stays where it is (iCloud Drive, On My iPhone, another
/// provider) instead of being copied into the app.
struct LinkedFolder: Codable, Hashable {
    /// Bookmark to the folder that was picked; it keeps access across launches.
    var bookmark: Data
    /// Name of the picked folder, for display.
    var rootName: String
    /// The book's folder relative to the picked folder ("" if it is the picked
    /// folder). nil when the book is a set of files inside a shared folder.
    var folderPath: String?
}

/// An EPUB or PDF read aloud by a voice. Its parsed text is cached in the
/// book's folder as text.json; this holds what the library needs.
struct TextInfo: Codable, Hashable {
    var file: String              // the original EPUB/PDF in the book's folder
    var format: String            // "epub" | "pdf"
    var sourceName: String        // original file name; same name = same book
    var chapterTitles: [String]
    var chapterChars: [Int]
    var totalChars: Int
    var subjects: [String] = []
    /// Reading position, to the sentence.
    var chapter = 0
    var sentence = 0
    var charsRead = 0
    /// When the position last moved (for backup merges: newer wins).
    var positionAt: Date?
    /// Earlier file names of the original, after it was renamed in its folder,
    /// so the watched folder doesn't add the old name again as a new book.
    var formerNames: [String]?
}

struct Book: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var author: String = ""
    var narrator: String = ""
    /// For linked books, `Track.file` is a path relative to the picked folder.
    var link: LinkedFolder?
    /// Set for EPUB/PDF books read aloud; nil for audiobooks.
    var text: TextInfo?
    /// User-named shelves (genres) the book sits on.
    var shelves: [String] = []
    var series = ""
    var seriesIndex: Double?
    /// Series typed in by hand is never replaced by the file's metadata.
    var seriesManual = false
    var tracks: [Track]
    var chapters: [Chapter]
    var coverFile: String?
    /// Listening position in seconds from the start of the book.
    var position: Double = 0
    var speed: Double = 1
    var createdAt = Date()
    var lastPlayed: Date?
    var finished = false
    var bookmarks: [Bookmark] = []
    /// Audiobooks: mute strong language, found by listening ahead on the phone.
    var muteLanguage = false

    var duration: Double { tracks.reduce(0) { $0 + $1.duration } }

    var trackStarts: [Double] {
        var starts: [Double] = []
        var t = 0.0
        for track in tracks {
            starts.append(t)
            t += track.duration
        }
        return starts
    }

    /// Which file a book position falls in, and the offset inside that file.
    func locate(_ time: Double) -> (index: Int, offset: Double) {
        var start = 0.0
        for (i, track) in tracks.enumerated() {
            if time < start + track.duration || i == tracks.count - 1 {
                return (i, max(0, min(time - start, track.duration)))
            }
            start += track.duration
        }
        return (0, 0)
    }

    func chapterIndex(at time: Double) -> Int {
        var index = 0
        for (i, chapter) in chapters.enumerated() {
            if chapter.start <= time + 0.05 { index = i } else { break }
        }
        return index
    }

    func chapterBounds(_ i: Int) -> (start: Double, end: Double) {
        guard chapters.indices.contains(i) else { return (0, duration) }
        let end = i + 1 < chapters.count ? chapters[i + 1].start : duration
        return (chapters[i].start, max(chapters[i].start, end))
    }

    var isText: Bool { text != nil }

    var progress: Double {
        if finished { return 1 }
        if let text { return text.totalChars > 0 ? min(1, Double(text.charsRead) / Double(text.totalChars)) : 0 }
        return duration > 0 ? min(1, position / duration) : 0
    }

    /// Seconds left at 1×. For text books, estimated from characters and how fast the voice reads.
    var remaining: Double {
        if finished { return 0 }
        if let text { return Double(max(0, text.totalChars - text.charsRead)) * TextTiming.secPerChar }
        return max(0, duration - position)
    }

    var totalTime: Double {
        if let text { return Double(text.totalChars) * TextTiming.secPerChar }
        return duration
    }

    var chapterCount: Int { text?.chapterTitles.count ?? chapters.count }

    /// What is already known about each file, so a rescan only reads new files.
    /// Chapter starts are relative to the start of their file.
    var knownFiles: [String: Importer.KnownFile] {
        var out: [String: Importer.KnownFile] = [:]
        for (track, start) in zip(tracks, trackStarts) {
            let end = start + track.duration
            let own = chapters.filter { $0.start >= start - 0.01 && $0.start < end - 0.01 }
                .map { Chapter(title: $0.title, start: $0.start - start) }
            out[track.file] = Importer.KnownFile(duration: track.duration, chapters: own)
        }
        return out
    }

    enum Status { case notStarted, inProgress, finished }

    var status: Status {
        if finished { return .finished }
        if let text { return lastPlayed == nil && text.charsRead == 0 ? .notStarted : .inProgress }
        return lastPlayed == nil && position < 1 ? .notStarted : .inProgress
    }

    // Tolerant decoding, so fields added in later versions don't break older libraries.
    init(id: UUID = UUID(), title: String, author: String = "", narrator: String = "",
         tracks: [Track], chapters: [Chapter], coverFile: String? = nil) {
        self.id = id
        self.title = title
        self.author = author
        self.narrator = narrator
        self.tracks = tracks
        self.chapters = chapters
        self.coverFile = coverFile
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        narrator = try c.decodeIfPresent(String.self, forKey: .narrator) ?? ""
        link = try c.decodeIfPresent(LinkedFolder.self, forKey: .link)
        text = try c.decodeIfPresent(TextInfo.self, forKey: .text)
        shelves = try c.decodeIfPresent([String].self, forKey: .shelves) ?? []
        series = try c.decodeIfPresent(String.self, forKey: .series) ?? ""
        seriesIndex = try c.decodeIfPresent(Double.self, forKey: .seriesIndex)
        seriesManual = try c.decodeIfPresent(Bool.self, forKey: .seriesManual) ?? false
        tracks = try c.decode([Track].self, forKey: .tracks)
        chapters = try c.decodeIfPresent([Chapter].self, forKey: .chapters) ?? []
        coverFile = try c.decodeIfPresent(String.self, forKey: .coverFile)
        position = try c.decodeIfPresent(Double.self, forKey: .position) ?? 0
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastPlayed = try c.decodeIfPresent(Date.self, forKey: .lastPlayed)
        finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? false
        bookmarks = try c.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? []
        muteLanguage = try c.decodeIfPresent(Bool.self, forKey: .muteLanguage) ?? false
        if chapters.isEmpty && text == nil {
            chapters = zip(tracks, trackStarts).map { Chapter(title: $0.title, start: $1) }
        }
    }
}

// MARK: - Formatting

enum Fmt {
    /// 1:02:03 or 2:03
    static func clock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds.isFinite ? seconds : 0))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// 3h 5m, 12m, <1m
    static func long(_ seconds: Double) -> String {
        let s = max(0, seconds.isFinite ? seconds : 0)
        if s > 0 && s < 60 { return "<1m" }
        var h = Int(s) / 3600
        var m = Int((s.truncatingRemainder(dividingBy: 3600) / 60).rounded())
        if m == 60 { h += 1; m = 0 }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(m)m"
    }

    static func speed(_ rate: Double) -> String {
        let text = String(format: "%.2f", rate)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        return text + "×"
    }
}

/// "iPad" or "iPhone", for text like "Delete from this iPhone".
enum ThisDevice {
    static let name: String = {
        var id = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        if id.isEmpty {
            var size = 0
            sysctlbyname("hw.machine", nil, &size, nil, 0)
            var buf = [CChar](repeating: 0, count: max(1, size))
            sysctlbyname("hw.machine", &buf, &size, nil, 0)
            id = String(cString: buf)
        }
        return id.hasPrefix("iPad") ? "iPad" : "iPhone"
    }()
}
