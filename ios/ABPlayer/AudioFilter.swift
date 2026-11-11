import AVFoundation
import Observation
import Speech
import os

private let log = Logger(subsystem: "com.bentarcau.lamplight", category: "AudioFilter")

/// A word heard in an audiobook, timed in seconds from the start of its file.
struct HeardWord: Codable, Hashable {
    var w: String
    var s: Double
    var e: Double
}

/// Mutes strong language in audiobooks. Listens a few minutes ahead of the
/// player in 2-minute pieces, on the phone, and remembers every word it heard
/// so a changed word list applies straight away without listening again.
@MainActor @Observable
final class AudioFilter {
    /// Each piece is 2 minutes; pieces overlap by 5 seconds so a word on the
    /// edge is heard whole in one of them.
    static let window = 120.0
    static let step = 115.0
    /// How far ahead of the listener to stay.
    static let lookahead = 8 * 60.0
    /// After a jump to an unchecked spot, wait this long at most before playing.
    static let jumpWait = 4.0

    /// Shown in the player's menu.
    private(set) var status = ""
    /// Seconds checked ahead of the listener, for the menu.
    private(set) var checkedAhead: Double = 0
    /// Called with (book, track) when new words were heard in a file.
    @ObservationIgnored var onHeard: ((UUID, Int) -> Void)?

    @ObservationIgnored private let library: Library
    @ObservationIgnored private var scans: [UUID: [String: [HeardWord]]] = [:]
    @ObservationIgnored private var target: (book: UUID, time: Double)?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var failures = 0

    init(library: Library) { self.library = library }

    nonisolated private static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AudioFilter", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    nonisolated private static func file(_ id: UUID) -> URL { dir.appendingPathComponent(id.uuidString + ".json") }
    private static func key(_ track: Int, _ k: Int) -> String { "\(track):\(k)" }

    // MARK: What has been heard

    private func scan(_ id: UUID) -> [String: [HeardWord]] {
        if let s = scans[id] { return s }
        let s = (try? Data(contentsOf: Self.file(id))).flatMap { try? JSONDecoder().decode([String: [HeardWord]].self, from: $0) } ?? [:]
        scans[id] = s
        return s
    }

    private func store(_ id: UUID, _ track: Int, _ k: Int, _ words: [HeardWord]) {
        var s = scan(id)
        s[Self.key(track, k)] = words
        scans[id] = s
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: Self.file(id), options: .atomic) }
    }

    /// Forget what was heard in a book that was deleted.
    nonisolated static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(id))
    }

    private static func windowCount(_ duration: Double) -> Int { max(1, Int(ceil(max(0, duration - (window - step)) / step))) }

    private func isScanned(_ book: Book, _ track: Int, _ offset: Double) -> Bool {
        let k = min(Int(offset / Self.step), Self.windowCount(book.tracks[track].duration) - 1)
        return scan(book.id)[Self.key(track, k)] != nil
    }

    func isChecked(_ book: Book, at time: Double) -> Bool {
        let (i, o) = book.locate(time)
        return isScanned(book, i, o)
    }

    /// Stretches of a file to mute, merged, in seconds from the start of the file.
    func muteRanges(_ book: Book, track: Int) -> [ClosedRange<Double>] {
        let regex = TextPipeline.badWordsRegex(extraWords: ReaderSettings.shared.filterWords)
        let words = scan(book.id).filter { $0.key.hasPrefix("\(track):") }.values.joined()
        var hits = words.filter { Self.matches($0.w, regex) }.map { max(0, $0.s - 0.06)...($0.e + 0.10) }
        hits.sort { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for r in hits {
            if let last = merged.last, r.lowerBound <= last.upperBound + 0.15 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    private static func matches(_ word: String, _ regex: NSRegularExpression?) -> Bool {
        // The older recognizer writes strong language as "f***".
        if word.contains("*") { return true }
        guard let regex else { return false }
        return regex.firstMatch(in: word, range: NSRange(word.startIndex..., in: word)) != nil
    }

    // MARK: Following the player

    /// The player is at `time` in a book that has muting on: keep checking ahead of it.
    func follow(_ book: Book, at time: Double) {
        target = (book.id, time)
        checkedAhead = aheadChecked(book, from: time)
        if loop == nil {
            loop = Task { [weak self] in
                await self?.run()
                self?.loop = nil
            }
        }
    }

    func stop() {
        target = nil
        loop?.cancel()
        loop = nil
        status = ""
        resumeWaiters()
    }

    /// Wait until the spot at `time` is checked, or `timeout` seconds pass.
    func waitUntilChecked(_ book: Book, at time: Double, timeout: Double) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !isChecked(book, at: time), target?.book == book.id {
            await withCheckedContinuation { c in
                waiters.append(c)
                Task { try? await Task.sleep(for: .seconds(max(0.1, deadline.timeIntervalSinceNow))); self.resumeWaiters() }
            }
        }
    }

    private func resumeWaiters() {
        let w = waiters
        waiters = []
        w.forEach { $0.resume() }
    }

    /// Seconds checked without a gap, starting where the listener is.
    private func aheadChecked(_ book: Book, from time: Double) -> Double {
        var (i, o) = book.locate(time)
        var k = Int(o / Self.step)
        var covered = 0.0
        let starts = book.trackStarts
        while i < book.tracks.count, covered < Self.lookahead {
            let n = Self.windowCount(book.tracks[i].duration)
            if k >= n { i += 1; k = 0; continue }
            guard scan(book.id)[Self.key(i, k)] != nil else { break }
            let end = starts[i] + min(Double(k) * Self.step + Self.window, book.tracks[i].duration)
            covered = max(covered, end - time)
            k += 1
        }
        return max(0, covered)
    }

    /// The first piece not yet checked within the look-ahead, starting at the listener.
    private func nextPiece(_ book: Book, from time: Double) -> (track: Int, k: Int)? {
        var (i, o) = book.locate(time)
        var k = Int(o / Self.step)
        let starts = book.trackStarts
        while i < book.tracks.count {
            let n = Self.windowCount(book.tracks[i].duration)
            if k >= n { i += 1; k = 0; continue }
            let pieceStart = starts[i] + Double(k) * Self.step
            if pieceStart - time > Self.lookahead { return nil }
            if scan(book.id)[Self.key(i, k)] == nil { return (i, k) }
            k += 1
        }
        return nil
    }

    private func run() async {
        while !Task.isCancelled, let target, let book = library.book(target.book) {
            guard let piece = nextPiece(book, from: target.time) else {
                checkedAhead = aheadChecked(book, from: target.time)
                status = checkedAhead >= Self.lookahead - 1 || target.time + checkedAhead >= book.duration - 1
                    ? "Checked \(Fmt.long(checkedAhead)) ahead" : status
                // Caught up: look again once the listener has moved on.
                try? await Task.sleep(for: .seconds(15))
                continue
            }
            status = "Checking ahead…"
            do {
                let words = try await listen(book, track: piece.track, k: piece.k)
                failures = 0
                store(book.id, piece.track, piece.k, words)
                onHeard?(book.id, piece.track)
                resumeWaiters()
                if let t = self.target { checkedAhead = aheadChecked(book, from: t.time) }
            } catch is CancellationError {
                return
            } catch {
                failures += 1
                log.error("Check failed: \(String(describing: error), privacy: .public)")
                status = "Couldn't check the audio: \(error.localizedDescription)"
                resumeWaiters()
                if failures >= 3 { return }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: Listening

    private func listen(_ book: Book, track: Int, k: Int) async throws -> [HeardWord] {
        guard let url = library.url(for: book, track: track) else { throw FilterError.unreachable }
        if book.link != nil, !(await Importer.ensureLocal(url)) { throw FilterError.unreachable }
        let start = Double(k) * Self.step
        let length = min(Self.window, book.tracks[track].duration - start)
        let audio = try await Task.detached(priority: .utility) { try Self.readAudio(url, start: start, length: length) }.value
        var words: [HeardWord]
        if #available(iOS 26, *), SpeechTranscriber.isAvailable {
            do {
                words = try await Self.transcribe(audio)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log.error("New speech engine failed, using the older one: \(error.localizedDescription, privacy: .public)")
                words = try await Self.transcribeOld(audio)
            }
        } else {
            words = try await Self.transcribeOld(audio)
        }
        log.info("Heard \(words.count) words in track \(track) piece \(k)")
        for i in words.indices { words[i].s += start; words[i].e += start }
        return words
    }

    /// Mono 16 kHz audio for a stretch of a file.
    nonisolated private static func readAudio(_ url: URL, start: Double, length: Double) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        file.framePosition = AVAudioFramePosition(start * rate)
        let frames = AVAudioFrameCount(max(0, min(length * rate, Double(file.length - file.framePosition))))
        guard frames > 0, let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { throw FilterError.noAudio }
        try file.read(into: raw, frameCount: frames)
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        return try convert(raw, to: mono)
    }

    nonisolated private static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1024)
        else { throw FilterError.noAudio }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .endOfStream; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        return out
    }

    private static var locale: Locale { Locale.current.language.languageCode == nil ? Locale(identifier: "en-US") : Locale.current }

    /// iOS 26 and later: Apple's newer on-device speech engine.
    @available(iOS 26, *)
    private static func transcribe(_ audio: AVAudioPCMBuffer) async throws -> [HeardWord] {
        var found = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        if found == nil { found = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
        guard let loc = found else { throw FilterError.language }
        // No etiquette replacements: we need the words as said, to mute them.
        let transcriber = SpeechTranscriber(locale: loc, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: audio.format) ?? audio.format
        let input = try convert(audio, to: format)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collect = Task {
            var words: [HeardWord] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters)
                    for w in text.split(whereSeparator: { $0.isWhitespace }) {
                        words.append(HeardWord(w: String(w), s: range.start.seconds, e: range.end.seconds))
                    }
                }
            }
            return words
        }
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)
        cont.yield(AnalyzerInput(buffer: input))
        cont.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collect.value
    }

    /// iOS 17–25: the older on-device recognizer.
    private static func transcribeOld(_ audio: AVAudioPCMBuffer) async throws -> [HeardWord] {
        guard await authorize() else { throw FilterError.notAllowed }
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.supportsOnDeviceRecognition else { throw FilterError.language }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = false
        request.append(audio)
        request.endAudio()
        return try await withCheckedThrowingContinuation { cont in
            var done = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !done else { return }
                if let result, result.isFinal {
                    done = true
                    cont.resume(returning: result.bestTranscription.segments.map {
                        HeardWord(w: $0.substring, s: $0.timestamp, e: $0.timestamp + $0.duration)
                    })
                } else if let error {
                    done = true
                    // Nothing said in this stretch is not a failure.
                    if (error as NSError).code == 1110 { cont.resume(returning: []) } else { cont.resume(throwing: error) }
                }
            }
        }
    }

    /// Asks for speech recognition permission the first time muting is turned on.
    static func authorize() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    enum FilterError: LocalizedError {
        case unreachable, noAudio, language, notAllowed
        var errorDescription: String? {
            switch self {
            case .unreachable: return "the audio file couldn't be reached."
            case .noAudio: return "the audio couldn't be read."
            case .language: return "on-device speech recognition isn't available for this language."
            case .notAllowed: return "speech recognition isn't allowed. Turn it on in Settings › Lamplight."
            }
        }
    }
}
