@preconcurrency import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// Reads an EPUB or PDF aloud, sentence by sentence. Ported from Lamplight's
/// player.js: a read-ahead cache of clips made in reading order, a start that
/// waits until it can keep going, the learned voice speed, and saving the place.
@MainActor @Observable
final class ReaderPlayer: RemoteTarget {
    enum State { case idle, preparing, playing }

    private(set) var bookID: UUID?
    private(set) var chapters: [TextChapter] = []
    private(set) var ch = 0
    private(set) var s = 0
    private(set) var state: State = .idle
    private(set) var sleep: SleepTimer = .off
    private(set) var sleepRemaining: Double = 0
    @ObservationIgnored private var sleepTimer: Timer?
    private(set) var finished = false
    private(set) var isLoading = false
    /// Seconds into the current sentence's audio.
    private(set) var sentenceElapsed: Double = 0
    /// Bumped on jumps (taps, contents, skips) so the text view scrolls instantly.
    private(set) var jumpCount = 0

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let settings = ReaderSettings.shared
    @ObservationIgnored private let status = VoiceStatus.shared

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var clipStartSample: AVAudioFramePosition = 0
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var positionAt = Date()
    @ObservationIgnored private var chapterChars: [Int] = []
    @ObservationIgnored private var charBefore: [[Int]] = []

    var book: Book? { bookID.flatMap { library.book($0) } }
    var chapter: TextChapter? { chapters.indices.contains(ch) ? chapters[ch] : nil }
    var sentence: String { chapter.map { $0.sentences.indices.contains(s) ? $0.sentences[s] : "" } ?? "" }

    init(library: Library) {
        self.library = library
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: ClipAudio.format)
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state != .idle else { self?.save(force: true); return }
                self.prefetch(burst: true)   // prepare a long run while the app can
                self.save(force: true)
            }
        }
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let opts = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated { self?.interruption(raw.flatMap(AVAudioSession.InterruptionType.init), resume: AVAudioSession.InterruptionOptions(rawValue: opts).contains(.shouldResume)) }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated { if reason == .oldDeviceUnavailable { self?.pause() } }
        }
        center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // The cloned voice's model is the biggest thing the app holds; let it go
                // unless it's reading right now.
                guard let self, self.settings.source != .pocket || self.state == .idle else { return }
                PocketEngine.shared.unload()
            }
        }
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.audioConfigurationChanged() }
        }
    }

    // MARK: Opening

    func open(_ book: Book) async {
        guard bookID != book.id else { return }
        if bookID != nil { pause(); save(force: true) }
        bookID = book.id
        chapters = []
        isLoading = true
        defer { isLoading = false }
        dropAll()
        finished = false
        do {
            let parsed = try await library.parsedText(for: book)
            guard bookID == book.id else { return }
            chapters = parsed.chapters
        } catch {
            library.message = "That book couldn't be read: \(error.localizedDescription)"
            bookID = nil
            return
        }
        chapterChars = chapters.map(\.charCount)
        charBefore = chapters.map { c in
            var acc = 0
            return c.sentences.map { let v = acc; acc += $0.count; return v }
        }
        let info = book.text
        ch = min(info?.chapter ?? 0, chapters.count - 1)
        s = min(info?.sentence ?? 0, max(0, chapters[ch].sentences.count - 1))
        if let info, info.chapterTitles != chapters.map(\.title) || info.chapterChars != chapterChars {
            // The book was read into chapters differently when the place was saved
            // (a parser fix); the text is the same, so find the place by characters.
            (ch, s) = position(atChars: info.charsRead)
            let (titles, chars, c, i) = (chapters.map(\.title), chapterChars, ch, s)
            library.mutate(book.id) {
                $0.text?.chapterTitles = titles
                $0.text?.chapterChars = chars
                $0.text?.totalChars = chars.reduce(0, +)
                $0.text?.chapter = c
                $0.text?.sentence = i
            }
        }
        finished = book.finished
        jumpCount += 1
        updateNowPlaying()
    }

    func close() {
        pause()
        save(force: true)
        bookID = nil
        chapters = []
        dropAll()
    }

    // MARK: Position

    func charsBefore(_ c: Int, _ s: Int) -> Int {
        chapterChars.prefix(c).reduce(0, +) + (charBefore.indices.contains(c) && charBefore[c].indices.contains(s) ? charBefore[c][s] : 0)
    }

    /// The sentence containing the given character offset into the book.
    private func position(atChars target: Int) -> (Int, Int) {
        var left = max(0, target)
        for (c, n) in chapterChars.enumerated() {
            if left < n || c == chapters.count - 1 {
                let i = (charBefore[c].lastIndex { $0 <= left }) ?? 0
                return (c, min(i, max(0, chapters[c].sentences.count - 1)))
            }
            left -= n
        }
        return (0, 0)
    }

    var secPerCharNow: Double { settings.secPerChar / max(0.1, settings.voiceSpeed) }

    struct PositionInfo { var chapterElapsed: Double; var chapterTotal: Double; var bookFraction: Double; var bookSecLeft: Double }

    var positionInfo: PositionInfo {
        guard let chapter else { return PositionInfo(chapterElapsed: 0, chapterTotal: 0, bookFraction: 0, bookSecLeft: 0) }
        let spc = secPerCharNow
        let within = state == .playing ? min(sentenceElapsed, Double(sentence.count) * spc) : 0
        let done = finished ? chapterChars[ch] : (charBefore[ch].indices.contains(s) ? charBefore[ch][s] : 0)
        let total = chapterChars.reduce(0, +)
        let bookDone = finished ? total : charsBefore(ch, 0) + done
        _ = chapter
        return PositionInfo(chapterElapsed: Double(done) * spc + within, chapterTotal: Double(chapterChars[ch]) * spc,
                            bookFraction: total > 0 ? Double(bookDone) / Double(total) : 0,
                            bookSecLeft: Double(total - bookDone) * spc)
    }

    private func setPosition(_ c: Int, _ sIdx: Int, jump: Bool = false) {
        let chapterChanged = c != ch
        ch = c
        s = sIdx
        finished = false
        sentenceElapsed = 0
        positionAt = Date()
        if jump { jumpCount += 1 }
        save(force: false)
        if chapterChanged || jump { updateNowPlaying() }
    }

    /// Jump anywhere; keeps playing if it was.
    func seek(_ c: Int, _ sIdx: Int) {
        guard chapters.indices.contains(c) else { return }
        let target = max(0, min(chapters[c].sentences.count - 1, sIdx))
        let wasPlaying = state != .idle
        stopAudio()
        setPosition(c, target, jump: true)
        if wasPlaying { speakCurrent(continuing: false) } else { updateNowPlaying() }
    }

    func seekChapterFraction(_ fraction: Double) {
        guard let chapter else { return }
        let target = Int(fraction * Double(chapterChars[ch]))
        var i = 0
        while i + 1 < chapter.sentences.count && charBefore[ch][i + 1] <= target { i += 1 }
        seek(ch, i)
    }

    func next() { step(1) }
    func previous() { step(-1) }

    /// One sentence or one paragraph, per the "Skip buttons move" setting.
    func step(_ dir: Int) {
        guard let chapter else { return }
        var c = ch, i = s
        if settings.skipUnit == .paragraph {
            let p = chapter.sentenceParagraph[s]
            if dir > 0 {
                if p + 1 < chapter.paragraphStarts.count { i = chapter.paragraphStarts[p + 1] } else if c + 1 < chapters.count { c += 1; i = 0 }
            } else {
                let atStart = s == chapter.paragraphStarts[p]
                if atStart && p > 0 { i = chapter.paragraphStarts[p - 1] }
                else if atStart && c > 0 { c -= 1; i = chapters[c].paragraphStarts.last ?? 0 }
                else { i = chapter.paragraphStarts[p] }
            }
        } else {
            i += dir
            if i >= chapter.sentences.count { if c + 1 < chapters.count { c += 1; i = 0 } else { i = chapter.sentences.count - 1 } }
            if i < 0 { if c > 0 { c -= 1; i = chapters[c].sentences.count - 1 } else { i = 0 } }
        }
        seek(c, i)
    }

    // MARK: Sleep timer

    func setSleep(_ timer: SleepTimer) {
        sleep = timer
        sleepTimer?.invalidate()
        sleepTimer = nil
        node.volume = 1
        sleepRemaining = 0
        if case .at(let end) = timer {
            sleepRemaining = end.timeIntervalSinceNow
            sleepTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sleepTick() }
            }
        }
    }

    private func sleepTick() {
        guard case .at(let end) = sleep else { return }
        sleepRemaining = max(0, end.timeIntervalSinceNow)
        if sleepRemaining <= 0 {
            pause()
            setSleep(.off)
        } else if sleepRemaining < Settings.fadeOut && state != .idle {
            // Fade out over the last few seconds instead of stopping mid-word.
            node.volume = Float(sleepRemaining / Settings.fadeOut)
        }
    }

    // MARK: Play / pause

    func togglePlay() { state == .idle ? play() : pause() }

    func play() {
        guard !chapters.isEmpty, state == .idle else { return }
        if finished {
            finished = false
            setPosition(0, 0, jump: true)
        }
        settings.follow = true
        RemoteRouter.shared.activate(self)
        startEngine()
        speakCurrent(continuing: false)
        updateNowPlaying()
    }

    func pause() {
        guard state != .idle else { return }
        stopAudio()
        state = .idle
        status.line = ""
        engine.pause()
        save(force: true)
        updateNowPlaying()
    }

    private func startEngine() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning { try? engine.start() }
    }

    private func stopAudio() {
        token += 1
        node.stop()
        tickTimer?.invalidate()
        tickTimer = nil
        sentenceElapsed = 0
    }

    /// Voice, speed, gap or words changed: what was made is out of date.
    func clearAudio() {
        let wasPlaying = state != .idle
        stopAudio()
        dropAll()
        if settings.source != .pocket { PocketEngine.shared.unload() }
        if wasPlaying { speakCurrent(continuing: false) }
    }

    /// iOS stopped the engine because the audio hardware changed. That happens
    /// on its own, for example just after play when the hardware had gone idle,
    /// so restart and read the current sentence again rather than pausing.
    /// (Unplugged headphones pause through the route change instead.)
    private func audioConfigurationChanged() {
        guard state != .idle else { return }
        stopAudio()
        startEngine()
        speakCurrent(continuing: false)
    }

    private func interruption(_ type: AVAudioSession.InterruptionType?, resume: Bool) {
        switch type {
        case .began:
            if state != .idle { resumeAfterInterruption = true; pause() }
        case .ended:
            if resumeAfterInterruption && resume { play() }
            resumeAfterInterruption = false
        default: break
        }
    }
    @ObservationIgnored private var resumeAfterInterruption = false
    /// Sentences in a row the voice couldn't make; after a few, stop instead of skipping on.
    @ObservationIgnored private var failuresInARow = 0

    // MARK: Making clips

    private final class Entry {
        let key: String
        let chars: Int
        var clip: Clip?
        var waiters: [CheckedContinuation<Clip, Error>] = []
        init(key: String, chars: Int) { self.key = key; self.chars = chars }
    }
    private struct Dropped: Error {}
    private struct Job { let c: Int; let s: Int; let entry: Entry }

    @ObservationIgnored private var cache: [String: Entry] = [:]
    @ObservationIgnored private var queue: [Job] = []
    @ObservationIgnored private var running: [(key: String, chars: Int, sentAt: Date)] = []
    @ObservationIgnored private var lastGenDone = Date.distantPast
    private static let inFlight = 2
    private static let lookahead: Double = 45
    private static let burstLookahead: Double = 240
    /// Sentences kept ready however short they are.
    private static let minAhead = 3
    /// Played sentences kept in memory, for stepping back a little.
    private static let keepBehind = 3

    // MARK: Background CPU pacing
    //
    // iOS kills a background app that averages over 80% CPU for a minute, and
    // Kokoro runs flat out, so away from the screen new clips wait until the app
    // has averaged no more than `bgCPUShare` since the mark (with at most
    // `bgIdleCredit` seconds of earlier idle time counted towards it).
    private static let bgCPUShare = 0.5
    private static let bgIdleCredit = 10.0
    @ObservationIgnored private var paceWall = Date()
    @ObservationIgnored private var paceCPU = 0.0
    @ObservationIgnored private var paceRetry = false

    private static func processCPUSeconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)) / 1e9
    }

    /// Seconds to hold off starting a clip; 0 in the foreground.
    private func paceWait() -> Double {
        let now = Date(), cpu = Self.processCPUSeconds()
        guard UIApplication.shared.applicationState != .active else {
            paceWall = now; paceCPU = cpu
            return 0
        }
        let slack = now.timeIntervalSince(paceWall) - (cpu - paceCPU) / Self.bgCPUShare
        if slack > Self.bgIdleCredit {
            // Don't bank more idle time than that, or a long pause could fund a minute flat out.
            paceWall = now.addingTimeInterval(-Self.bgIdleCredit)
            paceCPU = cpu
            return 0
        }
        return max(0, -slack)
    }

    private func key(_ c: Int, _ s: Int) -> String { "\(c)-\(s)" }

    private func entry(_ c: Int, _ s: Int) -> Entry {
        let k = key(c, s)
        if let e = cache[k] { return e }
        let e = Entry(key: k, chars: chapters[c].sentences[s].count)
        cache[k] = e
        queue.append(Job(c: c, s: s, entry: e))
        pump()
        return e
    }

    private func clip(_ c: Int, _ s: Int) async throws -> Clip {
        let e = entry(c, s)
        if let clip = e.clip { return clip }
        return try await withCheckedThrowingContinuation { e.waiters.append($0) }
    }

    private func dropAll() {
        for job in queue { fail(job.entry, Dropped()) }
        queue.removeAll()
        for e in cache.values where e.clip == nil { fail(e, Dropped()) }
        cache.removeAll()
    }

    private func fail(_ e: Entry, _ error: Error) {
        let waiters = e.waiters
        e.waiters = []
        waiters.forEach { $0.resume(throwing: error) }
    }

    private func pump() {
        while running.count < Self.inFlight, !queue.isEmpty {
            let wait = paceWait()
            if wait > 0 {
                if !paceRetry {
                    paceRetry = true
                    if settings.source == .pocket, wait >= 0.5 { PocketLog.write(String(format: "pacing: holding the next sentence %.1f s to keep background CPU at 50%%", wait)) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                        MainActor.assumeIsolated { self?.paceRetry = false; self?.pump() }
                    }
                }
                return
            }
            let job = queue.removeFirst()
            guard cache[job.entry.key] === job.entry else { fail(job.entry, Dropped()); continue }
            let run = (key: job.entry.key, chars: job.entry.chars, sentAt: Date())
            running.append(run)
            let text = TextPipeline.speechText(chapters[job.c].sentences[job.s], settings.rules)
            let source = settings.source, gap = settings.gapMs
            let voice = settings.currentVoice, speed = settings.voiceSpeed
            Task {
                let result: Result<Clip, Error> = await Task.detached {
                    do {
                        if text.trimmingCharacters(in: .whitespaces).isEmpty { return .success(Clip(buffer: ClipAudio.silence(0.05))) }
                        let raw = try await Self.generate(source, text: text, voice: voice, speed: speed)
                        return .success(Clip(buffer: ClipAudio.compressSilence(raw, gapMs: gap)))
                    } catch { return .failure(error) }
                }.value
                self.finished(run, job.entry, result, speed: speed)
            }
        }
    }

    private func finished(_ run: (key: String, chars: Int, sentAt: Date), _ e: Entry, _ result: Result<Clip, Error>, speed: Double) {
        let now = Date()
        running.removeAll { $0.key == run.key && $0.sentAt == run.sentAt }
        if case .success(let clip) = result {
            learnGenTime(chars: run.chars, seconds: now.timeIntervalSince(max(run.sentAt, lastGenDone)))
            // Learn how fast this voice reads, so the time estimates fit it.
            if e.chars > 40, clip.duration > 0 {
                settings.secPerChar = settings.secPerChar * 0.8 + (clip.duration * speed / Double(e.chars)) * 0.2
            }
        }
        lastGenDone = now
        if cache[e.key] === e {
            switch result {
            case .success(let clip):
                e.clip = clip
                let waiters = e.waiters
                e.waiters = []
                waiters.forEach { $0.resume(returning: clip) }
            case .failure(let error):
                cache[e.key] = nil
                fail(e, error)
            }
        } else {
            fail(e, Dropped())
        }
        pump()
    }

    private func unitAfter(_ c: Int, _ s: Int) -> (Int, Int)? {
        if s + 1 < chapters[c].sentences.count { return (c, s + 1) }
        var n = c + 1
        while n < chapters.count { if !chapters[n].sentences.isEmpty { return (n, 0) }; n += 1 }
        return nil
    }

    private func unitSec(_ c: Int, _ s: Int) -> Double {
        if let d = cache[key(c, s)]?.clip?.duration { return d }
        return Double(chapters[c].sentences[s].count) * secPerCharNow
    }

    /// Asks for the clip here and the ones after it, up to the lookahead, and gives
    /// up queued clips outside that run.
    private func prefetch(burst: Bool) {
        guard !chapters.isEmpty else { return }
        let ahead = burst ? Self.burstLookahead : Self.lookahead
        var wanted: [(Int, Int)] = []
        var unit: (Int, Int)? = (ch, s)
        var sec = 0.0
        while let u = unit, wanted.count < Self.minAhead || sec < ahead {
            wanted.append(u)
            sec += unitSec(u.0, u.1)
            unit = unitAfter(u.0, u.1)
        }
        let order = Dictionary(uniqueKeysWithValues: wanted.enumerated().map { (key($0.element.0, $0.element.1), $0.offset) })
        queue.removeAll { job in
            guard order[job.entry.key] == nil else { return false }
            if cache[job.entry.key] === job.entry { cache[job.entry.key] = nil }
            fail(job.entry, Dropped())
            return true
        }
        // Clips well behind the reading place go, or a long session holds every
        // sentence it has read (hundreds of MB after an hour).
        for (k, e) in cache where e.clip != nil {
            let parts = k.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2 else { continue }
            if parts[0] < ch || (parts[0] == ch && parts[1] < s - Self.keepBehind) { cache[k] = nil }
        }
        for u in wanted { _ = entry(u.0, u.1) }
        queue.sort { (order[$0.entry.key] ?? 0) < (order[$1.entry.key] ?? 0) }
    }

    // MARK: How long clips take (learned per voice setup)

    private struct GenStats: Codable { var w = 0.0, x = 0.0, y = 0.0, xx = 0.0, xy = 0.0, clips = 0 }
    @ObservationIgnored private var genModels: [String: GenStats] = {
        (UserDefaults.standard.data(forKey: "rd.genModels")).flatMap { try? JSONDecoder().decode([String: GenStats].self, from: $0) } ?? [:]
    }()

    private var genKey: String {
        switch settings.source {
        case .kokoro: return "kokoro neural engine"
        case .device: return "device"
        case .pocket: return "pocket cpu"
        }
    }

    private func genStats() -> GenStats {
        if let m = genModels[genKey] { return m }
        // Start from two made-up clips: 0.8 s + 25 ms a character, until real ones are measured.
        var m = GenStats()
        for c in [40.0, 300.0] { let t = 0.8 + 0.025 * c; m.w += 1; m.x += c; m.y += t; m.xx += c * c; m.xy += c * t }
        return m
    }

    func genFit() -> (fixed: Double, perChar: Double, clips: Int) {
        let m = genStats()
        let den = m.w * m.xx - m.x * m.x
        let perChar = min(0.5, max(0.0005, den > 1e-9 ? (m.w * m.xy - m.x * m.y) / den : 0.025))
        let fixed = min(10, max(0, (m.y - perChar * m.x) / m.w))
        return (fixed, perChar, m.clips)
    }

    private func genSec(_ chars: Int) -> Double { let f = genFit(); return f.fixed + f.perChar * Double(chars) }

    private func learnGenTime(chars: Int, seconds: Double) {
        guard chars > 0, seconds > 0 else { return }
        let sec = min(seconds, 2 * genSec(chars) + 2)
        var m = genStats()
        m.w *= 0.95; m.x *= 0.95; m.y *= 0.95; m.xx *= 0.95; m.xy *= 0.95
        let c = Double(chars)
        m.w += 1; m.x += c; m.y += sec; m.xx += c * c; m.xy += c * sec; m.clips += 1
        genModels[genKey] = m
        UserDefaults.standard.set(try? JSONEncoder().encode(genModels), forKey: "rd.genModels")
    }

    /// For Settings: how many times faster than speech this voice setup makes it.
    var measuredSpeed: (timesFaster: Double, fixed: Double, clips: Int)? {
        let f = genFit()
        guard f.clips > 0 else { return nil }
        return (secPerCharNow / f.perChar, f.fixed, f.clips)
    }

    /// Seconds to hold the start so nothing due in the next 30 s arrives late.
    private func startDelay() -> Double {
        let now = Date()
        var readyAt: [String: Date] = [:]
        var free = lastGenDone
        for r in running {
            free = max(free, r.sentAt).addingTimeInterval(genSec(r.chars) * 1.15)
            free = max(free, now.addingTimeInterval(0.2))
            readyAt[r.key] = free
        }
        free = max(free, now)
        for job in queue { free = free.addingTimeInterval(genSec(job.entry.chars) * 1.15); readyAt[job.entry.key] = free }
        var unit: (Int, Int)? = (ch, s)
        var startsIn = 0.0, wait = 0.0, i = 0
        while let u = unit, startsIn <= 30, i < 60 {
            var ready = now
            let k = key(u.0, u.1)
            if cache[k]?.clip == nil {
                if readyAt[k] == nil { free = free.addingTimeInterval(genSec(chapters[u.0].sentences[u.1].count) * 1.15); readyAt[k] = free }
                ready = readyAt[k]!
            }
            wait = max(wait, ready.timeIntervalSince(now) - startsIn)
            startsIn += unitSec(u.0, u.1)
            unit = unitAfter(u.0, u.1)
            i += 1
        }
        return wait
    }

    private func waitForHeadStart(_ myToken: Int) async -> Bool {
        let began = Date()
        while Date().timeIntervalSince(began) < 20 {
            let wait = startDelay()
            if wait < 0.3 { break }
            status.line = "Buffering… \(Int(ceil(wait))) s"
            try? await Task.sleep(for: .seconds(min(1, wait)))
            if myToken != token { return false }
        }
        return true
    }

    // MARK: The clip loop

    /// Loads the Kokoro models before the first sentence (a few seconds, once per launch).
    private func ensureReady() async -> Bool {
        switch settings.source {
        case .kokoro:
            if let reason = KokoroEngine.unavailableReason {
                status.line = reason
                return false
            }
            if !KokoroEngine.voices.contains(settings.kokoroVoice) { settings.kokoroVoice = "af_heart" }
            guard !KokoroEngine.shared.isLoaded else { return true }
            let loading = KokoroEngine.firstLoad
                ? "Getting the Kokoro voice ready. The first time takes about a minute…"
                : "Loading the Kokoro voice…"
            status.line = loading
            do {
                try await KokoroEngine.shared.prepare(voice: settings.kokoroVoice)
                if status.line == loading { status.line = "" }
                return true
            } catch {
                status.line = error.localizedDescription
                return false
            }
        case .device:
            if settings.deviceVoice.isEmpty { settings.deviceVoice = DeviceVoice.defaultVoiceID() }
            return true
        case .pocket:
            if let reason = PocketEngine.unavailableReason {
                return await fallBack(from: VoiceError.unavailable(reason))
            }
            if !PocketEngine.voices.contains(settings.pocketVoice) { settings.pocketVoice = PocketEngine.voices[0] }
            guard !PocketEngine.shared.isLoaded else { return true }
            let loading = "Loading the \(settings.pocketVoice.capitalized) voice…"
            status.line = loading
            do {
                try await PocketEngine.shared.prepare(voice: settings.pocketVoice)
                if status.line == loading { status.line = "" }
                return true
            } catch {
                return await fallBack(from: error)
            }
        }
    }

    /// The cloned voice couldn't run: carry on with Kokoro (or Apple's voice)
    /// rather than stopping, and say why.
    private func fallBack(from error: Error) async -> Bool {
        let to: VoiceSource = KokoroEngine.unavailableReason == nil ? .kokoro : .device
        settings.source = to
        PocketEngine.shared.unload()
        let ready = await ensureReady()
        status.line = "The \(settings.pocketVoice.capitalized) voice couldn't run (\(error.localizedDescription)), so \(to.label) is reading."
        return ready
    }

    nonisolated private static func generate(_ source: VoiceSource, text: String, voice: String, speed: Double) async throws -> AVAudioPCMBuffer {
        switch source {
        case .kokoro: return try await KokoroEngine.shared.generate(text: text, voice: voice, speed: speed)
        case .device: return try await DeviceVoice.shared.generate(text: text, voiceID: voice, speed: speed)
        case .pocket: return try await PocketEngine.shared.generate(text: text, voice: voice)
        }
    }

    private func speakCurrent(continuing: Bool) {
        token += 1
        let myToken = token
        guard let chapter else { return }
        if s >= chapter.sentences.count {
            if sleep == .endOfChapter {
                if ch + 1 < chapters.count { setPosition(ch + 1, 0) }
                pause()
                setSleep(.off)
                return
            }
            if ch + 1 < chapters.count { setPosition(ch + 1, 0); speakCurrent(continuing: continuing) } else { finishBook() }
            return
        }
        state = .preparing
        let (c, i) = (ch, s)
        let stalled = cache[key(c, i)]?.clip == nil
        if settings.source == .pocket, continuing, stalled { gapSince = Date() }
        Task {
            guard await ensureReady() else {
                if myToken == token { stopAudio(); state = .idle; engine.pause() }
                return
            }
            guard myToken == token else { return }
            prefetch(burst: UIApplication.shared.applicationState == .background)
            if stalled { status.line = "Generating…" }
            let clip: Clip
            do {
                clip = try await self.clip(c, i)
            } catch is Dropped {
                if myToken == token { speakCurrent(continuing: continuing) }
                return
            } catch {
                guard myToken == token else { return }
                failuresInARow += 1
                if failuresInARow >= 3, settings.source == .pocket {
                    failuresInARow = 0
                    dropAll()
                    if await fallBack(from: error), myToken == token { speakCurrent(continuing: false) }
                    return
                }
                if failuresInARow >= 3 {
                    // Something is wrong with the voice itself; don't race through the book.
                    failuresInARow = 0
                    stopAudio()
                    state = .idle
                    engine.pause()
                    status.line = "The voice couldn't read this (\(error.localizedDescription)). Stopped here; try another voice."
                    save(force: true)
                    return
                }
                status.line = "Voice generation failed (\(error.localizedDescription)) — skipping."
                if let next = unitAfter(c, i) { setPosition(next.0, next.1); speakCurrent(continuing: false) } else { stopAudio(); state = .idle }
                return
            }
            guard myToken == token else { return }
            if stalled || !continuing {
                guard await waitForHeadStart(myToken) else { return }
            }
            if status.line.hasPrefix("Buffering") || status.line == "Generating…" || status.line.hasPrefix("Voice generation failed") { status.line = "" }
            failuresInARow = 0
            schedule(clip, myToken: myToken, lastText: chapter.sentences[i])
        }
    }

    private func schedule(_ clip: Clip, myToken: Int, lastText: String) {
        if let since = gapSince {
            PocketLog.write(String(format: "GAP: %.2f s of silence waiting for the next sentence", Date().timeIntervalSince(since)))
            gapSince = nil
        }
        if settings.source == .pocket {
            let ready = cache.values.filter { $0.clip != nil }.count
            PocketLog.write(String(format: "playing %d.%d (%.1f s); %d clips ready, %d queued", ch, s, clip.duration, ready, queue.count))
        }
        startEngine()
        clipStartSample = currentSample()
        node.scheduleBuffer(clip.buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.clipEnded(myToken, lastText: lastText) }
        }
        if !node.isPlaying { node.play(); clipStartSample = currentSample() }
        state = .playing
        sentenceElapsed = 0
        startTicking()
        updateNowPlaying()
    }

    private func currentSample() -> AVAudioFramePosition {
        guard let t = node.lastRenderTime, let p = node.playerTime(forNodeTime: t) else { return 0 }
        return p.sampleTime
    }

    private func startTicking() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .playing else { return }
                self.sentenceElapsed = max(0, Double(self.currentSample() - self.clipStartSample) / ClipAudio.format.sampleRate)
            }
        }
    }

    private func clipEnded(_ myToken: Int, lastText: String) {
        guard myToken == token, chapter != nil else { return }
        guard let next = unitAfter(ch, s) else {
            s = chapters[ch].sentences.count
            speakCurrent(continuing: true)
            return
        }
        setPosition(next.0, next.1)
        // A closing quote with nothing after it is a natural beat.
        if TextPipeline.endsQuotedDialogue(lastText) {
            Task {
                try? await Task.sleep(for: .seconds(TextPipeline.dialogueEndPause))
                if myToken == token { speakCurrent(continuing: true) }
            }
        } else {
            speakCurrent(continuing: true)
        }
    }

    private func finishBook() {
        stopAudio()
        finished = true
        s = max(0, chapters[ch].sentences.count - 1)
        state = .idle
        engine.pause()
        save(force: true)
        if let book { library.message = "Finished “\(book.title)”" }
        updateNowPlaying()
    }

    // MARK: Voice preview

    func preview(_ text: String) {
        let speech = TextPipeline.speechText(text, settings.rules)
        let source = settings.source, voice = settings.currentVoice, speed = settings.voiceSpeed, gap = settings.gapMs
        if state != .idle { pause() }
        Task {
            guard await ensureReady() else { return }
            do {
                let raw = try await Task.detached {
                    try await Self.generate(source, text: speech, voice: voice, speed: speed)
                }.value
                startEngine()
                node.stop()
                node.scheduleBuffer(ClipAudio.compressSilence(raw, gapMs: gap), completionHandler: nil)
                node.play()
            } catch {
                status.line = error.localizedDescription
            }
        }
    }

    // MARK: Pocket spike (debug builds)

    /// Launched with -pocketSpike: reads the last ebook aloud with the Pocket voice
    /// and logs every gap, without moving the saved place in the book.
    static let spikeRun: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-pocketSpike")
        #else
        return false
        #endif
    }()
    @ObservationIgnored private var gapSince: Date?

    // MARK: Saving

    func save(force: Bool) {
        guard let id = bookID, !chapters.isEmpty, !Self.spikeRun else { return }
        guard force || Date().timeIntervalSince(lastSave) > 5 else { return }
        lastSave = Date()
        let (c, i, done) = (ch, s, finished)
        let read = done ? chapterChars.reduce(0, +) : charsBefore(c, i)
        let at = positionAt
        let played = state != .idle
        library.mutate(id) {
            $0.text?.chapter = c
            $0.text?.sentence = i
            $0.text?.charsRead = read
            $0.text?.positionAt = at
            $0.finished = done
            if played || $0.lastPlayed != nil { $0.lastPlayed = Date() }
        }
    }

    // MARK: Lock screen

    func updateNowPlaying() {
        guard let book, let chapter, RemoteRouter.shared.owns(self) else { return }
        let info = positionInfo
        var np: [String: Any] = [
            MPMediaItemPropertyTitle: chapter.title,
            MPMediaItemPropertyArtist: book.author.isEmpty ? book.title : book.author,
            MPMediaItemPropertyAlbumTitle: book.title,
            MPMediaItemPropertyPlaybackDuration: info.chapterTotal,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: info.chapterElapsed,
            // Preparing counts as playing, like the spinner on the play button.
            MPNowPlayingInfoPropertyPlaybackRate: state != .idle ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let image = library.cover(for: book) { np[MPMediaItemPropertyArtwork] = Self.artwork(image) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = np
    }

    nonisolated private static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    // MARK: RemoteTarget

    func remotePlay() { play() }
    func remotePause() { pause() }
    func remoteToggle() { togglePlay() }
    func remoteSkip(_ seconds: Double) { step(seconds < 0 ? -1 : 1) }
    func remoteNext() { next() }
    func remotePrevious() { previous() }
    func remoteSeek(_ position: Double) {
        let total = positionInfo.chapterTotal
        if total > 0 { seekChapterFraction(min(1, position / total)) }
    }
    func remoteRate(_ rate: Double) { setSpeed(rate) }

    func setSpeed(_ rate: Double) {
        settings.speed = (rate * 20).rounded() / 20
        clearAudio()
    }
}
