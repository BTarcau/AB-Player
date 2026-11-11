import SwiftUI

struct PlayerView: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var showChapters = false
    @State private var showSpeed = false
    @State private var scrub: Double = 0

    var body: some View {
        if let book = player.book {
            let i = book.chapterIndex(at: player.currentTime)
            let (start, end) = book.chapterBounds(i)
            let length = max(end - start, 0.1)
            let elapsed = player.isScrubbing ? scrub : min(max(0, player.currentTime - start), length)

            VStack(spacing: 0) {
                header
                Spacer(minLength: 8)
                CoverView(book: book, corner: 14)
                    .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                    .padding(.horizontal, 28)
                    .frame(maxHeight: 360)
                    .scaleEffect(player.isPlaying ? 1 : 0.94)
                    .animation(.spring(duration: 0.4), value: player.isPlaying)
                Spacer(minLength: 16)

                VStack(spacing: 4) {
                    Text(book.chapters.indices.contains(i) ? book.chapters[i].title : book.title)
                        .font(.title3.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                    Text(book.author.isEmpty ? book.title : "\(book.title) · \(book.author)")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal)

                // Scrubber covers the current chapter.
                VStack(spacing: 2) {
                    Scrubber(fraction: elapsed / length, dragging: player.isScrubbing) { frac in
                        scrub = frac * length
                        player.isScrubbing = true
                    } onEnd: { frac in
                        scrub = frac * length
                        player.isScrubbing = false
                        player.seek(to: start + scrub)
                    }
                    .accessibilityElement()
                    .accessibilityLabel("Position in chapter")
                    .accessibilityValue("\(Fmt.clock(elapsed)) of \(Fmt.clock(length))")
                    .accessibilityAdjustableAction { dir in player.skip(dir == .increment ? Settings.forward : -Settings.back) }
                    HStack {
                        Text(Fmt.clock(elapsed))
                        Spacer()
                        if book.chapters.count > 1 { Text("Chapter \(i + 1) of \(book.chapters.count)") }
                        Spacer()
                        Text("-" + Fmt.clock(length - elapsed))
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24).padding(.top, 18)

                controls(book: book, chapter: i).padding(.top, 14)

                Group {
                    if player.downloading {
                        Label { Text("Downloading from iCloud…") } icon: { ProgressView().controlSize(.small) }
                    } else if player.checkingBeforePlay {
                        Label { Text("Checking for strong language…") } icon: { ProgressView().controlSize(.small) }
                    } else {
                        Text(progressText(book))
                    }
                }
                .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                .padding(.top, 10)

                bottomBar(book: book).padding(.top, 18).padding(.bottom, 8)
            }
            .overlay(alignment: .bottom) { ToastOverlay().padding(.bottom, 70) }
            .sheet(isPresented: $showChapters) { ChaptersView() }
            .sheet(isPresented: $showSpeed) { SpeedView().presentationDetents([.height(320)]) }
            .presentationDragIndicator(.visible)
        } else {
            ContentUnavailableView("Nothing playing", systemImage: "headphones")
                .onAppear { dismiss() }
        }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close player")
            Spacer()
            Text("Now Playing").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            MuteMenu()
            Button { showChapters = true } label: {
                Image(systemName: "list.bullet").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Chapters and bookmarks")
        }
        .padding(.horizontal, 8).padding(.top, 8)
        .tint(.primary)
    }

    private func controls(book: Book, chapter: Int) -> some View {
        HStack {
            Button { player.previousChapter() } label: {
                Image(systemName: "backward.end.fill").font(.title2)
            }
            .accessibilityLabel("Previous chapter")
            Spacer()
            Button { player.skip(-Settings.back) } label: {
                Image(systemName: "gobackward.\(Int(Settings.back))").font(.system(size: 34))
            }
            .accessibilityLabel("Back \(Int(Settings.back)) seconds")
            Spacer()
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 76))
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Spacer()
            Button { player.skip(Settings.forward) } label: {
                Image(systemName: "goforward.\(Int(Settings.forward))").font(.system(size: 34))
            }
            .accessibilityLabel("Forward \(Int(Settings.forward)) seconds")
            Spacer()
            Button { player.nextChapter() } label: {
                Image(systemName: "forward.end.fill").font(.title2)
            }
            .disabled(chapter >= book.chapters.count - 1)
            .accessibilityLabel("Next chapter")
        }
        .padding(.horizontal, 28)
        .tint(.primary)
    }

    private func bottomBar(book: Book) -> some View {
        HStack {
            Button { showSpeed = true } label: {
                Text(Fmt.speed(book.speed)).font(.body.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 52, minHeight: 36)
            }
            .accessibilityLabel("Playback speed \(Fmt.speed(book.speed))")
            Spacer()
            SleepMenu()
            Spacer()
            Button { player.addBookmark() } label: {
                Image(systemName: "bookmark").font(.title3).frame(width: 44, height: 36)
            }
            .accessibilityLabel("Add bookmark")
            Spacer()
            RoutePicker().frame(width: 44, height: 36)
        }
        .padding(.horizontal, 28)
        .tint(.primary)
    }

    private func progressText(_ book: Book) -> String {
        guard book.duration > 0 else { return "" }
        let pct = Int((player.currentTime / book.duration) * 100)
        let left = max(0, book.duration - player.currentTime) / book.speed
        return "\(pct)% · \(Fmt.long(left)) left in book" + (book.speed != 1 ? " at \(Fmt.speed(book.speed))" : "")
    }
}

/// The chapter position bar: drag the knob or tap anywhere on the bar to jump.
/// Its touch area is tall and it wins over the sheet's pull-down, so a quick
/// sideways swipe moves the position instead of starting to close the player.
struct Scrubber: View {
    var fraction: Double
    var dragging: Bool
    var onChange: (Double) -> Void
    var onEnd: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let f = min(1, max(0, fraction.isFinite ? fraction : 0))
            let knob: CGFloat = dragging ? 22 : 14
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25)).frame(height: dragging ? 8 : 5)
                Capsule().fill(Color.accentColor).frame(width: w * f, height: dragging ? 8 : 5)
                Circle().fill(Color.accentColor)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    .offset(x: w * f - knob / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.15), value: dragging)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { onChange(min(1, max(0, $0.location.x / w))) }
                    .onEnded { onEnd(min(1, max(0, $0.location.x / w))) }
            )
        }
        .frame(height: 36)
    }
}

/// Per-book switch for muting strong language, with how far ahead it has checked.
struct MuteMenu: View {
    @Environment(Player.self) private var player

    var body: some View {
        let on = player.book?.muteLanguage ?? false
        Menu {
            Toggle(isOn: Binding(get: { on }, set: { player.setMuteLanguage($0) })) {
                Label("Mute Strong Language", systemImage: "speaker.slash")
            }
            // Menus don't show section footers, so the explanation is a disabled item.
            Button(on && !player.filter.status.isEmpty ? player.filter.status
                   : "Listens a few minutes ahead on this iPhone and mutes words on your filter list. Nothing is sent anywhere.") {}
                .disabled(true)
        } label: {
            Image(systemName: on ? "speaker.slash.fill" : "speaker.slash")
                .font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                .foregroundStyle(on ? Color.accentColor : Color.primary)
        }
        .accessibilityLabel("Mute strong language")
        .accessibilityValue(on ? "On" : "Off")
    }
}

struct SleepMenu: View {
    @Environment(Player.self) private var player

    var body: some View {
        SleepTimerMenu(sleep: player.sleep, remaining: player.sleepRemaining) { player.setSleep($0) }
    }
}

/// The moon menu, shared by the audiobook player and the ebook reader.
struct SleepTimerMenu: View {
    var sleep: SleepTimer
    var remaining: Double
    var tint: Color = .accentColor
    var plain: Color = .primary
    var set: (SleepTimer) -> Void

    var body: some View {
        Menu {
            if sleep != .off {
                Button("Turn Off Timer", systemImage: "xmark", role: .destructive) { set(.off) }
            }
            Button("End of Chapter", systemImage: "book.closed") { set(.endOfChapter) }
            ForEach([90, 60, 45, 30, 15, 10, 5], id: \.self) { m in
                Button("\(m) minutes") { set(.at(Date().addingTimeInterval(Double(m) * 60))) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: sleep == .off ? "moon.zzz" : "moon.zzz.fill")
                switch sleep {
                case .off: EmptyView()
                case .endOfChapter: Text("Chapter end").font(.caption.weight(.semibold))
                case .at: Text(Fmt.clock(remaining)).font(.caption.weight(.semibold).monospacedDigit())
                }
            }
            .font(.title3)
            .foregroundStyle(sleep == .off ? plain : tint)
            .frame(minWidth: 44, minHeight: 36)
        }
        .accessibilityLabel("Sleep timer")
        .accessibilityValue(sleep == .off ? "Off" : sleep == .endOfChapter ? "End of chapter" : Fmt.clock(remaining))
    }
}

struct SpeedView: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    private let presets: [Double] = [0.8, 1, 1.2, 1.5, 1.75, 2]

    var body: some View {
        let speed = player.book?.speed ?? 1
        VStack(spacing: 18) {
            Text("Playback Speed").font(.headline).padding(.top, 20)
            Text(Fmt.speed(speed)).font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
            HStack(spacing: 16) {
                Button { player.setSpeed(max(0.5, speed - 0.05)) } label: { Image(systemName: "minus.circle.fill").font(.title) }
                    .accessibilityLabel("Slower")
                Slider(value: Binding(get: { speed }, set: { player.setSpeed(($0 * 20).rounded() / 20) }), in: 0.5...3.5)
                    .accessibilityLabel("Speed")
                Button { player.setSpeed(min(3.5, speed + 0.05)) } label: { Image(systemName: "plus.circle.fill").font(.title) }
                    .accessibilityLabel("Faster")
            }
            .padding(.horizontal)
            HStack {
                ForEach(presets, id: \.self) { p in
                    Button(Fmt.speed(p)) { player.setSpeed(p) }
                        .buttonStyle(.bordered)
                        .tint(abs(p - speed) < 0.01 ? .accentColor : .secondary)
                        .font(.subheadline.monospacedDigit())
                }
            }
            Text("Saved for this book.").font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
    }
}
