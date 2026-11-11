import AVFoundation
import MediaPlayer
import Observation
import UIKit
import os

private let muteLog = Logger(subsystem: "com.bentarcau.lamplight", category: "AudioFilter")

enum SleepTimer: Equatable {
    case off
    case at(Date)
    case endOfChapter
}

enum Settings {
    static let skipBack = "skipBack"
    static let skipForward = "skipForward"
    static let smartRewind = "smartRewind"
    static let rewindAfterInterruption: Double = 3
    static let maxAutoResume: TimeInterval = 30 * 60
    static let saveEvery: TimeInterval = 5
    static let fadeOut: Double = 10

    static func register() {
        UserDefaults.standard.register(defaults: [skipBack: 15, skipForward: 30, smartRewind: true])
    }
    static var back: Double { Double(UserDefaults.standard.integer(forKey: skipBack)) }
    static var forward: Double { Double(UserDefaults.standard.integer(forKey: skipForward)) }
}

/// Plays a book as one continuous timeline across its files, keeps the lock
/// screen up to date, saves the position, and handles calls, unplugged
/// headphones and the sleep timer.
@MainActor @Observable
final class Player: RemoteTarget {
    private(set) var bookID: UUID?
    private(set) var isPlaying = false
    /// Position in seconds from the start of the book.
    private(set) var currentTime: Double = 0
    private(set) var sleep: SleepTimer = .off
    private(set) var sleepRemaining: Double = 0
    /// Set while a file is being fetched from iCloud before it can play.
    private(set) var downloading = false
    /// Set while playback waits a moment for a jumped-to spot to be checked.
    private(set) var checkingBeforePlay = false
    var isScrubbing = false

    private let library: Library
    private let player = AVPlayer()
    /// Finds and mutes strong language, for books with muting on.
    let filter: AudioFilter
    @ObservationIgnored private var filterWait = 0
    @ObservationIgnored private var skipFilterWait = false
    @ObservationIgnored private var trackIndex = 0
    @ObservationIgnored private var pendingSeek: Double?
    @ObservationIgnored private var wantsPlay = false
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var pausedAt: Date?
    @ObservationIgnored private var interruptedAt: Date?
    @ObservationIgnored private var lastChapter = -1
    @ObservationIgnored private var sleepChapter = 0
    @ObservationIgnored private var sleepTimer: Timer?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var loadToken = 0
    @ObservationIgnored private var isLoadingTrack = false
    @ObservationIgnored private var nowPlayingArtwork: (UUID, MPMediaItemArtwork)?

    var book: Book? { bookID.flatMap { library.book($0) } }

    init(library: Library) {
        self.library = library
        filter = AudioFilter(library: library)
        player.automaticallyWaitsToMinimizeStalling = false
        configureSession()
        observePlayer()
        setUpRemoteCommands()
        filter.onHeard = { [weak self] id, track in
            guard let self, id == self.bookID, track == self.trackIndex, let item = self.player.currentItem else { return }
            self.applyMute(to: item, track: track)
        }
    }

    // MARK: Setup

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let info = note.userInfo
            MainActor.assumeIsolated { self?.handleInterruption(info) }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                // Headphones unplugged or AirPods taken out: pause, like every audio app.
                if reason == .oldDeviceUnavailable { self?.pause() }
            }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverFromReset() }
        }
    }

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            DispatchQueue.main.async {
                guard let self, self.isPlaying != playing else { return }
                self.isPlaying = playing
                if !playing {
                    if self.pausedAt == nil { self.pausedAt = Date() }
                    self.saveNow()
                }
                self.updateNowPlaying()
            }
        }
    }

    // MARK: Opening books

    func open(_ book: Book, autoplay: Bool = false) {
        guard !book.isText else { return }   // EPUB/PDF books belong to the reader
        if bookID == book.id {
            if autoplay && !isPlaying { play() }
            return
        }
        if bookID != nil { saveNow(); pause() }
        bookID = book.id
        lastChapter = -1
        nowPlayingArtwork = nil
        let start = book.finished ? 0 : book.position
        let (index, offset) = book.locate(start)
        currentTime = start
        filter.stop()
        if book.muteLanguage { filter.follow(book, at: start) }
        loadTrack(index, offset: offset)
        if autoplay { play() }
    }

    /// Open the most recently played book, paused, so it's one tap away.
    func restoreLast() {
        guard bookID == nil,
              let recent = library.books.filter({ $0.lastPlayed != nil && !$0.isText }).max(by: { $0.lastPlayed! < $1.lastPlayed! })
        else { return }
        open(recent)
    }

    func close() {
        pause()
        player.replaceCurrentItem(with: nil)
        bookID = nil
        currentTime = 0
        filter.stop()
        setSleep(.off)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func loadTrack(_ index: Int, offset: Double) {
        guard let book, book.tracks.indices.contains(index) else { return }
        trackIndex = index
        pendingSeek = offset > 0.05 ? offset : nil
        loadToken += 1
        let token = loadToken
        guard let url = library.url(for: book, track: index) else {
            wantsPlay = false
            player.replaceCurrentItem(with: nil)
            library.message = "Can't reach the folder for “\(book.title)”. It may have been moved or deleted, or iCloud may be signed out."
            return
        }
        guard book.link != nil else {
            attach(url)
            return
        }
        // Linked books: the file may be in iCloud and not on the phone yet.
        player.replaceCurrentItem(with: nil)
        isLoadingTrack = true
        downloading = Importer.needsDownload(url)
        updateNowPlaying()
        Task {
            let ok = await Importer.ensureLocal(url)
            guard token == self.loadToken else { return }
            self.isLoadingTrack = false
            self.downloading = false
            if ok {
                self.attach(url)
            } else {
                self.wantsPlay = false
                self.library.message = "“\(book.tracks[index].title)” couldn't be opened. Check that you're online, or that the file is still in the folder."
            }
            if let next = self.library.url(for: book, track: index + 1) { Importer.prefetch(next) }
        }
    }

    private func attach(_ url: URL) {
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async { self?.itemStatusChanged(item) }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackEnded() }
        }
        player.replaceCurrentItem(with: item)
        applyMute(to: item, track: trackIndex)
        updateNowPlaying()
    }

    // MARK: Muting strong language

    /// Turn muting on or off for the open book.
    func setMuteLanguage(_ on: Bool) {
        guard let id = bookID else { return }
        if !on {
            library.mutate(id) { $0.muteLanguage = false }
            filter.stop()
            if let item = player.currentItem { item.audioMix = nil }
            return
        }
        Task {
            guard await AudioFilter.authorize() else {
                library.message = "Muting needs speech recognition. Allow it in the iPhone's Settings › Lamplight."
                return
            }
            library.mutate(id) { $0.muteLanguage = true }
            if let book = self.book { filter.follow(book, at: currentTime) }
        }
    }

    /// The word list changed: mute by the new list (nothing is listened to again).
    func refreshMute() {
        guard let item = player.currentItem else { return }
        applyMute(to: item, track: trackIndex)
    }

    /// Silences the stretches of this file where strong language was heard,
    /// with a short fade either side so it doesn't click.
    private func applyMute(to item: AVPlayerItem, track: Int) {
        guard let book, book.muteLanguage else { item.audioMix = nil; return }
        let ranges = filter.muteRanges(book, track: track)
        guard !ranges.isEmpty else { item.audioMix = nil; return }
        Task {
            guard let audio = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }
            let params = AVMutableAudioMixInputParameters(track: audio)
            let fade = 0.02
            func t(_ s: Double) -> CMTime { CMTime(seconds: max(0, s), preferredTimescale: 44_100) }
            for r in ranges {
                params.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: t(r.lowerBound - fade), duration: t(fade)))
                params.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: t(r.upperBound), duration: t(fade)))
            }
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            item.audioMix = mix
            muteLog.info("Muting \(ranges.count) stretches in file \(track)")
        }
    }

    private func itemStatusChanged(_ item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            if let offset = pendingSeek {
                pendingSeek = nil
                player.seek(to: CMTime(seconds: offset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self, self.wantsPlay else { return }
                        self.startPlayback()
                    }
                }
            } else if wantsPlay {
                startPlayback()
            }
        case .failed:
            wantsPlay = false
            library.message = "This file could not be played. Try deleting and re-adding the book."
        default:
            break
        }
    }

    private func recoverFromReset() {
        configureSession()
        guard book != nil else { return }
        let (index, offset) = book!.locate(currentTime)
        loadTrack(index, offset: offset)
    }

    // MARK: Playback

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard let book else { return }
        if book.finished || currentTime >= book.duration - 0.5 {
            library.mutate(book.id) { $0.finished = false }
            seek(to: 0, play: true)
            return
        }
        interruptedAt = nil
        let rewind = smartRewindAmount()
        pausedAt = nil
        if rewind > 0 {
            seek(to: currentTime - rewind, play: true)
        } else if pendingSeek != nil || player.currentItem?.status != .readyToPlay {
            wantsPlay = true
            if player.currentItem == nil && !isLoadingTrack { let (i, o) = book.locate(currentTime); loadTrack(i, offset: o) }
        } else {
            startPlayback()
        }
    }

    private func startPlayback() {
        guard let book else { return }
        if book.muteLanguage, !skipFilterWait, !filter.isChecked(book, at: currentTime) {
            // Jumped somewhere not checked yet: give the check a moment first.
            filterWait += 1
            let token = filterWait
            wantsPlay = true
            filter.follow(book, at: currentTime)
            checkingBeforePlay = true
            Task {
                await filter.waitUntilChecked(book, at: currentTime, timeout: AudioFilter.jumpWait)
                if token == filterWait { checkingBeforePlay = false }
                guard token == filterWait, wantsPlay else { return }
                skipFilterWait = true
                startPlayback()
                skipFilterWait = false
            }
            return
        }
        wantsPlay = false
        try? AVAudioSession.sharedInstance().setActive(true)
        player.volume = 1
        player.defaultRate = Float(book.speed)
        RemoteRouter.shared.activate(self)
        player.playImmediately(atRate: Float(book.speed))
        isPlaying = true
        library.mutate(book.id, save: false) {
            $0.lastPlayed = Date()
            $0.finished = false
        }
        lastChapter = book.chapterIndex(at: currentTime)
        updateNowPlaying()
    }

    func pause() {
        wantsPlay = false
        filterWait += 1
        checkingBeforePlay = false
        guard player.rate != 0 || isPlaying else { return }
        player.pause()
        isPlaying = false
        pausedAt = Date()
        saveNow()
        updateNowPlaying()
    }

    /// Go back a little after a pause so you can pick up the thread:
    /// longer pauses rewind further.
    private func smartRewindAmount() -> Double {
        guard UserDefaults.standard.bool(forKey: Settings.smartRewind), let pausedAt else { return 0 }
        let paused = Date().timeIntervalSince(pausedAt)
        switch paused {
        case ..<10: return 0
        case ..<300: return 2
        case ..<3600: return 10
        default: return 20
        }
    }

    func seek(to time: Double) { seek(to: time, play: isPlaying || wantsPlay) }

    private func seek(to time: Double, play shouldPlay: Bool) {
        guard let book else { return }
        let t = max(0, min(time, book.duration - 0.25))
        let (index, offset) = book.locate(t)
        currentTime = t
        if book.muteLanguage { filter.follow(book, at: t) }
        if case .endOfChapter = sleep { sleepChapter = book.chapterIndex(at: t) }
        if index != trackIndex || (player.currentItem == nil && !isLoadingTrack) {
            wantsPlay = shouldPlay
            player.pause()
            loadTrack(index, offset: offset)
        } else if player.currentItem?.status == .readyToPlay && pendingSeek == nil {
            player.seek(to: CMTime(seconds: offset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if shouldPlay && self.player.rate == 0 { self.startPlayback() }
                    self.updateNowPlaying()
                }
            }
        } else {
            pendingSeek = offset
            wantsPlay = shouldPlay
        }
        lastChapter = book.chapterIndex(at: t)
        if !shouldPlay { saveNow() }
        updateNowPlaying()
    }

    func skip(_ seconds: Double) { seek(to: currentTime + seconds) }

    func previousChapter() {
        guard let book else { return }
        let i = book.chapterIndex(at: currentTime)
        let start = book.chapterBounds(i).start
        // Like a CD player: first go to the start of this chapter.
        if currentTime - start > 3 || i == 0 { seek(to: start) } else { seek(to: book.chapterBounds(i - 1).start) }
    }

    func nextChapter() {
        guard let book else { return }
        let i = book.chapterIndex(at: currentTime)
        guard i + 1 < book.chapters.count else { return }
        seek(to: book.chapters[i + 1].start)
    }

    func goToChapter(_ i: Int) {
        guard let book, book.chapters.indices.contains(i) else { return }
        seek(to: book.chapters[i].start, play: true)
    }

    func jump(to time: Double) { seek(to: time, play: true) }

    func jumpPaused(to time: Double) {
        pause()
        seek(to: time, play: false)
    }

    func setSpeed(_ rate: Double) {
        guard let id = bookID else { return }
        let r = (rate * 100).rounded() / 100
        library.mutate(id) { $0.speed = r }
        player.defaultRate = Float(r)
        if player.rate != 0 { player.rate = Float(r) }
        updateNowPlaying()
    }

    private func trackEnded() {
        guard let book else { return }
        if trackIndex + 1 < book.tracks.count {
            let stopHere = sleep == .endOfChapter
            if stopHere { setSleep(.off) }
            currentTime = book.trackStarts[trackIndex + 1]
            wantsPlay = !stopHere
            loadTrack(trackIndex + 1, offset: 0)
            if stopHere { isPlaying = false; saveNow() }
        } else {
            wantsPlay = false
            isPlaying = false
            currentTime = book.duration
            if sleep == .endOfChapter { setSleep(.off) }
            library.mutate(book.id) {
                $0.finished = true
                $0.position = $0.duration
                $0.lastPlayed = Date()
            }
            library.message = "Finished “\(book.title)”"
            updateNowPlaying()
        }
    }

    private func tick(_ seconds: Double) {
        guard let book, !isScrubbing, pendingSeek == nil, player.currentItem != nil, seconds.isFinite else { return }
        let starts = book.trackStarts
        guard starts.indices.contains(trackIndex) else { return }
        currentTime = min(starts[trackIndex] + seconds, book.duration)
        if book.muteLanguage { filter.follow(book, at: currentTime) }
        let chapter = book.chapterIndex(at: currentTime)
        if chapter != lastChapter {
            if lastChapter >= 0, sleep == .endOfChapter, isPlaying, chapter != sleepChapter {
                // Stop exactly at the start of the next chapter.
                setSleep(.off)
                pause()
                seek(to: book.chapters[chapter].start, play: false)
            }
            lastChapter = chapter
            updateNowPlaying()
        }
        if isPlaying && Date().timeIntervalSince(lastSave) > Settings.saveEvery { saveNow() }
    }

    /// Save the listening position. Called on pause, every few seconds while
    /// playing, and when the app goes to the background.
    func saveNow() {
        guard let id = bookID, pendingSeek == nil, let book else { return }
        let t = currentTime
        lastSave = Date()
        if abs(book.position - t) < 0.5 && !isPlaying { return }
        library.mutate(id) {
            $0.position = t
            if self.isPlaying || $0.lastPlayed != nil { $0.lastPlayed = Date() }
        }
    }

    // MARK: Phone calls and other interruptions

    private func handleInterruption(_ info: [AnyHashable: Any]?) {
        guard let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            if isPlaying || wantsPlay { interruptedAt = Date() }
            isPlaying = false
            saveNow()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            guard let at = interruptedAt else { return }
            interruptedAt = nil
            // Resume a few seconds back, unless it was a very long interruption.
            if options.contains(.shouldResume), Date().timeIntervalSince(at) < Settings.maxAutoResume {
                pausedAt = nil
                seek(to: currentTime - Settings.rewindAfterInterruption, play: true)
            }
        @unknown default:
            break
        }
    }

    // MARK: Sleep timer

    func setSleep(_ timer: SleepTimer) {
        sleep = timer
        sleepTimer?.invalidate()
        sleepTimer = nil
        player.volume = 1
        switch timer {
        case .off:
            sleepRemaining = 0
        case .endOfChapter:
            sleepChapter = book?.chapterIndex(at: currentTime) ?? 0
            sleepRemaining = 0
        case .at(let end):
            sleepRemaining = end.timeIntervalSinceNow
            sleepTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sleepTick() }
            }
        }
    }

    func setSleep(minutes: Int) { setSleep(.at(Date().addingTimeInterval(Double(minutes) * 60))) }

    private func sleepTick() {
        guard case .at(let end) = sleep else { return }
        sleepRemaining = max(0, end.timeIntervalSinceNow)
        if sleepRemaining <= 0 {
            pause()
            setSleep(.off)
        } else if sleepRemaining < Settings.fadeOut && isPlaying {
            // Fade out over the last few seconds instead of stopping mid-word.
            player.volume = Float(sleepRemaining / Settings.fadeOut)
        }
    }

    // MARK: Bookmarks

    func addBookmark(note: String = "") {
        guard let id = bookID else { return }
        let t = currentTime
        library.mutate(id) { $0.bookmarks.append(Bookmark(time: t, note: note)) }
        library.message = "Bookmark added at \(Fmt.clock(t))"
    }

    // MARK: Lock screen, Control Center, AirPods, CarPlay

    private func setUpRemoteCommands() {
        _ = RemoteRouter.shared
        updateSkipIntervals()
    }

    func updateSkipIntervals() {
        let c = MPRemoteCommandCenter.shared()
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: Settings.back)]
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: Settings.forward)]
    }

    func updateNowPlaying() {
        guard let book, RemoteRouter.shared.owns(self) else { return }
        let i = book.chapterIndex(at: currentTime)
        let (start, end) = book.chapterBounds(i)
        let title = book.chapters.indices.contains(i) ? book.chapters[i].title : book.title
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyAlbumTitle: book.title,
            MPMediaItemPropertyArtist: book.author.isEmpty ? book.title : book.author,
            MPMediaItemPropertyPlaybackDuration: end - start,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, currentTime - start),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? book.speed : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: book.speed,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyChapterNumber: i,
            MPNowPlayingInfoPropertyChapterCount: book.chapters.count,
        ]
        if nowPlayingArtwork?.0 != book.id, let image = library.cover(for: book) {
            nowPlayingArtwork = (book.id, Self.artwork(image))
        }
        if let art = nowPlayingArtwork, art.0 == book.id { info[MPMediaItemPropertyArtwork] = art.1 }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: RemoteTarget

    func remotePlay() { play() }
    func remotePause() { pause() }
    func remoteToggle() { togglePlay() }
    func remoteSkip(_ seconds: Double) { skip(seconds) }
    func remoteNext() { nextChapter() }
    func remotePrevious() { previousChapter() }
    func remoteSeek(_ position: Double) {
        // The lock-screen scrubber covers the current chapter.
        guard let book else { return }
        seek(to: book.chapterBounds(book.chapterIndex(at: currentTime)).start + position)
    }
    func remoteRate(_ rate: Double) { setSpeed(rate) }

    /// Built outside the main actor: iOS asks for the image on a background thread.
    nonisolated private static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    /// Call after a book's cover changes.
    func refreshArtwork() {
        nowPlayingArtwork = nil
        updateNowPlaying()
    }
}
