import SwiftUI

@main
struct ABPlayerApp: App {
    @State private var library: Library
    @State private var player: Player
    @State private var reader: ReaderPlayer
    @State private var readerSettings = ReaderSettings.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Settings.register()
        let library = Library()
        _library = State(initialValue: library)
        _player = State(initialValue: Player(library: library))
        _reader = State(initialValue: ReaderPlayer(library: library))
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(library)
                .environment(player)
                .environment(reader)
                .environment(readerSettings)
                .environment(VoiceStatus.shared)
                .task {
                    // Warm up the Kokoro voice in the background so the first sentence is quick.
                    if readerSettings.source == .kokoro, KokoroEngine.unavailableReason == nil {
                        let voice = readerSettings.kokoroVoice
                        Task.detached(priority: .utility) { try? await KokoroEngine.shared.prepare(voice: voice) }
                    }
                    if readerSettings.source == .pocket, PocketEngine.unavailableReason == nil {
                        let voice = readerSettings.pocketVoice
                        Task.detached(priority: .utility) { try? await PocketEngine.shared.prepare(voice: voice) }
                    }
                    player.restoreLast()
                    // If an EPUB/PDF was the last thing read, have it ready in the reader too.
                    let lastText = library.books.filter { $0.isText && $0.lastPlayed != nil }.max { $0.lastPlayed! < $1.lastPlayed! }
                    let lastAudio = player.book?.lastPlayed ?? .distantPast
                    if let lastText, lastText.lastPlayed! > lastAudio {
                        UserDefaults.standard.set(true, forKey: "lastOpenedText")
                        await reader.open(lastText)
                    }
                    if ReaderPlayer.spikeRun, let lastText {
                        await reader.open(lastText)
                        readerSettings.source = .pocket
                        if ProcessInfo.processInfo.arguments.contains("-castSpike") {
                            // Character voices too: Kokoro for the dialogue alongside the Pocket narrator.
                            await CastStore.shared.findCharacters(lastText)
                            PocketLog.write("spike: \(CastStore.shared.cast?.characters.count ?? 0) characters, \(CastStore.shared.cast?.dialogueCount ?? 0) lines")
                        }
                        PocketLog.write("spike: reading \(lastText.title) from chapter \(reader.chapter?.title ?? "?")")
                        reader.play()
                    }
                    await library.scanFilesFolder()
                    await library.scanWatchedFolder(announce: false)
                }
                .onOpenURL { url in
                    // "Open in Lamplight" from the share sheet or Files.
                    let inbox = library.filesDir.appendingPathComponent("Inbox").standardizedFileURL.path
                    let fromInbox = url.standardizedFileURL.path.hasPrefix(inbox)
                    Task { await library.importItems([url], removeOriginals: fromInbox) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive:
                player.saveNow()
                reader.save(force: true)
            case .active:
                Task {
                    await library.scanFilesFolder()
                    await library.scanWatchedFolder(announce: false)
                }
            @unknown default:
                break
            }
        }
    }
}
