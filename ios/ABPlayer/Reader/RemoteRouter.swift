import MediaPlayer

/// Something the lock screen, Control Center and headphones can control.
@MainActor protocol RemoteTarget: AnyObject {
    func remotePlay()
    func remotePause()
    func remoteToggle()
    func remoteSkip(_ seconds: Double)
    func remoteNext()
    func remotePrevious()
    /// Position inside the item shown on the lock screen (the chapter).
    func remoteSeek(_ position: Double)
    func remoteRate(_ rate: Double)
}

/// The audiobook player and the book reader share one set of lock-screen
/// controls. Whichever started playing last owns them; starting one pauses the other.
@MainActor final class RemoteRouter {
    static let shared = RemoteRouter()
    private(set) weak var active: RemoteTarget?

    func activate(_ target: RemoteTarget) {
        if let current = active, current !== target { current.remotePause() }
        active = target
        // The library's mini player follows whatever played last.
        UserDefaults.standard.set(target is ReaderPlayer, forKey: "lastOpenedText")
    }

    func owns(_ target: RemoteTarget) -> Bool { active == nil || active === target }

    private init() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { _ in MainActor.assumeIsolated { RemoteRouter.shared.active?.remotePlay() }; return .success }
        c.pauseCommand.addTarget { _ in MainActor.assumeIsolated { RemoteRouter.shared.active?.remotePause() }; return .success }
        c.togglePlayPauseCommand.addTarget { _ in MainActor.assumeIsolated { RemoteRouter.shared.active?.remoteToggle() }; return .success }
        c.skipBackwardCommand.addTarget { event in
            let s = (event as? MPSkipIntervalCommandEvent)?.interval ?? Settings.back
            MainActor.assumeIsolated { RemoteRouter.shared.active?.remoteSkip(-s) }
            return .success
        }
        c.skipForwardCommand.addTarget { event in
            let s = (event as? MPSkipIntervalCommandEvent)?.interval ?? Settings.forward
            MainActor.assumeIsolated { RemoteRouter.shared.active?.remoteSkip(s) }
            return .success
        }
        c.nextTrackCommand.addTarget { _ in MainActor.assumeIsolated { RemoteRouter.shared.active?.remoteNext() }; return .success }
        c.previousTrackCommand.addTarget { _ in MainActor.assumeIsolated { RemoteRouter.shared.active?.remotePrevious() }; return .success }
        c.changePlaybackPositionCommand.addTarget { event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            MainActor.assumeIsolated { RemoteRouter.shared.active?.remoteSeek(t) }
            return .success
        }
        c.changePlaybackRateCommand.supportedPlaybackRates = [0.75, 1, 1.25, 1.5, 1.75, 2].map { NSNumber(value: $0) }
        c.changePlaybackRateCommand.addTarget { event in
            guard let e = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            let r = Double(e.playbackRate)
            MainActor.assumeIsolated { RemoteRouter.shared.active?.remoteRate(r) }
            return .success
        }
    }
}
