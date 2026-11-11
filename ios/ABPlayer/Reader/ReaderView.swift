import SwiftUI
import UIKit

/// Lamplight's reading screen: the whole chapter with the sentence being read
/// highlighted, follow-along scrolling, and the player card at the bottom.
struct ReaderView: View {
    @Environment(ReaderPlayer.self) private var reader
    @Environment(ReaderSettings.self) private var settings
    @Environment(VoiceStatus.self) private var status
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase

    @State private var showContents = false
    @State private var showDisplay = false
    @State private var showVoice = false
    @State private var showSettings = false
    @State private var currentVisible = true
    @State private var catchUp = 0

    private var palette: ReaderPalette { ReaderPalette.resolve(settings.theme, scheme) }

    var body: some View {
        let p = palette
        ZStack(alignment: .bottom) {
            Color(p.paper).ignoresSafeArea()
            if let chapter = reader.chapter, let book = reader.book {
                ChapterTextView(
                    chapter: chapter, chapterIndex: reader.ch, isLast: reader.ch == reader.chapters.count - 1,
                    bookTitle: book.title, current: reader.s, follow: settings.follow, fade: settings.fadeRead,
                    palette: p, font: settings.font, size: settings.fontSize, rules: settings.rules,
                    jumpCount: reader.jumpCount, catchUp: catchUp,
                    onTap: { reader.seek(reader.ch, $0) },
                    onDoubleTap: { s in
                        // Start reading from the sentence that was double-tapped.
                        reader.seek(reader.ch, s)
                        if reader.state == .idle { reader.play() }
                    },
                    onUserScroll: { if settings.follow { settings.follow = false } },
                    onVisibility: { currentVisible = $0 }
                )
                .ignoresSafeArea(edges: .bottom)
                .safeAreaInset(edge: .top) { topBar(book: book, chapter: chapter, p) }

                if !settings.follow && !currentVisible {
                    Button {
                        settings.follow = true
                        catchUp += 1
                    } label: {
                        Label("Back to where it's reading", systemImage: "chevron.down")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(Color(p.lampDark), in: Capsule())
                            .foregroundStyle(Color(p.paper))
                    }
                    .padding(.bottom, 230)
                }
                PlayerCard(palette: p, showVoice: $showVoice)
                    .frame(maxWidth: ReadingTextView.measure + 40)
            } else if reader.isLoading {
                ProgressView("Opening…").tint(Color(p.ink)).foregroundStyle(Color(p.ink))
            }
        }
        .preferredColorScheme(settings.theme == .auto ? nil : (settings.theme == .dark ? .dark : .light))
        .sheet(isPresented: $showContents) { ContentsSheet(palette: p) }
        .sheet(isPresented: $showDisplay) { DisplaySheet().presentationDetents([.medium]) }
        .sheet(isPresented: $showVoice) { VoiceSheet() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { catchUp += 1 } }
        .onChange(of: settings.follow) { _, on in if on { catchUp += 1 } }
        .animation(.easeInOut(duration: 0.2), value: currentVisible)
        .animation(.easeInOut(duration: 0.2), value: settings.follow)
    }

    private func topBar(book: Book, chapter: TextChapter, _ p: ReaderPalette) -> some View {
        HStack(spacing: 4) {
            Button { reader.save(force: true); dismiss() } label: {
                Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Back to library")
            Button { showContents = true } label: {
                VStack(spacing: 1) {
                    Text(chapter.title).font(.subheadline.weight(.bold)).lineLimit(1)
                    Text("Chapter \(reader.ch + 1) of \(reader.chapters.count) · tap for contents")
                        .font(.caption2).foregroundStyle(Color(p.inkSoft)).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
            .accessibilityLabel("Contents. \(chapter.title)")
            Button { showDisplay = true } label: {
                Text("Aa").font(.system(size: 18, weight: .semibold, design: .serif)).frame(width: 40, height: 44)
            }
            .accessibilityLabel("Display")
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.title3).frame(width: 40, height: 44)
            }
            .accessibilityLabel("Settings")
        }
        .foregroundStyle(Color(p.ink))
        .padding(.horizontal, 6)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Player card

private struct PlayerCard: View {
    @Environment(ReaderPlayer.self) private var reader
    @Environment(ReaderSettings.self) private var settings
    @Environment(VoiceStatus.self) private var status
    let palette: ReaderPalette
    @Binding var showVoice: Bool

    var body: some View {
        let p = palette
        let info = reader.positionInfo
        VStack(spacing: 10) {
            if !status.line.isEmpty {
                Text(status.line).font(.caption).foregroundStyle(Color(p.inkSoft)).multilineTextAlignment(.center).lineLimit(3)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("NOW").font(.caption2.weight(.heavy)).foregroundStyle(Color(p.brass))
                Text(TextPipeline.displayText(reader.sentence, settings.rules))
                    .font(settings.font.font(size: 13.5)).foregroundStyle(Color(p.ink)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Text(Fmt.clock(info.chapterElapsed)).font(.caption.monospacedDigit())
                GeometryReader { geo in
                    let frac = info.chapterTotal > 0 ? min(1, info.chapterElapsed / info.chapterTotal) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(p.inkSoft).opacity(0.25))
                        Capsule().fill(LinearGradient(colors: [Color(p.brass).opacity(0.7), Color(p.brass)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * frac)
                    }
                    .frame(height: 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                        reader.seekChapterFraction(max(0, min(1, v.location.x / geo.size.width)))
                    })
                }
                .frame(height: 24)
                .accessibilityElement()
                .accessibilityLabel("Position in chapter")
                .accessibilityValue("\(Fmt.clock(info.chapterElapsed)) of \(Fmt.clock(info.chapterTotal))")
                .accessibilityAdjustableAction { dir in dir == .increment ? reader.next() : reader.previous() }
                Text("-" + Fmt.clock(max(0, info.chapterTotal - info.chapterElapsed))).font(.caption.monospacedDigit())
            }
            .foregroundStyle(Color(p.inkSoft))
            HStack {
                Button { showVoice = true } label: {
                    Text(String(format: "%.1f×", settings.speed)).font(.subheadline.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color(p.paper2), in: Capsule())
                }
                .accessibilityLabel("Speed \(String(format: "%.1f", settings.speed)). Voice and speed")
                SleepTimerMenu(sleep: reader.sleep, remaining: reader.sleepRemaining, tint: Color(p.brass), plain: Color(p.inkSoft)) { reader.setSleep($0) }
                Spacer(minLength: 0)
                skipButton(back: true)
                Button { reader.togglePlay() } label: {
                    ZStack {
                        Circle().fill(Color(p.lamp)).frame(width: 58, height: 58)
                        if reader.state == .preparing {
                            ProgressView().tint(Color(p.paper))
                        } else {
                            Image(systemName: reader.state == .idle ? "play.fill" : "pause.fill")
                                .font(.title2).foregroundStyle(Color(p.paper))
                        }
                    }
                }
                .accessibilityLabel(reader.state == .idle ? "Play" : "Pause")
                skipButton(back: false)
                Spacer(minLength: 0)
                Button { showVoice = true } label: {
                    Text(voiceLabel).font(.subheadline.weight(.semibold)).lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color(p.paper2), in: Capsule())
                }
                .accessibilityLabel("Voice \(voiceLabel)")
            }
            .foregroundStyle(Color(p.ink))
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                .fill(Color(p.card))
                .shadow(color: .black.opacity(0.15), radius: 12, y: -2)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    /// Sentence or paragraph back/forward, captioned with what it moves by;
    /// press and hold to change that.
    private func skipButton(back: Bool) -> some View {
        Button { back ? reader.previous() : reader.next() } label: {
            VStack(spacing: 1) {
                Image(systemName: back ? "arrow.counterclockwise" : "arrow.clockwise").font(.title3.weight(.semibold))
                Text(settings.skipUnit.label).font(.system(size: 9, weight: .semibold)).foregroundStyle(Color(palette.inkSoft))
            }
            .frame(width: 58, height: 48)
        }
        .contextMenu {
            Section("Skip by") {
                ForEach(SkipUnit.allCases) { u in
                    Button { settings.skipUnit = u } label: {
                        if settings.skipUnit == u { Label(u.label, systemImage: "checkmark") } else { Text(u.label) }
                    }
                }
            }
        }
        .accessibilityLabel("\(back ? "Previous" : "Next") \(settings.skipUnit.rawValue)")
        .accessibilityHint("Press and hold to skip by sentence or paragraph")
    }

    private var voiceLabel: String {
        switch settings.source {
        case .kokoro: return friendlyVoiceName(settings.kokoroVoice).name
        case .device: return DeviceVoice.voices().first { $0.id == settings.deviceVoice }?.name ?? "Voice"
        }
    }
}

// MARK: - Chapter text

/// Keeps lines at a comfortable length on wide screens (iPad, landscape) by
/// widening the side margins; on an iPhone they stay at 20 points.
final class ReadingTextView: UITextView {
    static let measure: CGFloat = 680

    override func layoutSubviews() {
        let side = max(20, ((bounds.width - Self.measure) / 2).rounded())
        if textContainerInset.left != side {
            textContainerInset.left = side
            textContainerInset.right = side
        }
        super.layoutSubviews()
    }
}

/// The chapter in a UITextView: sentences as ranges that can be highlighted,
/// faded, tapped and scrolled to without re-laying out the whole chapter.
struct ChapterTextView: UIViewRepresentable {
    let chapter: TextChapter
    let chapterIndex: Int
    let isLast: Bool
    let bookTitle: String
    let current: Int
    let follow: Bool
    let fade: Bool
    let palette: ReaderPalette
    let font: ReaderFont
    let size: Double
    let rules: TextRules
    let jumpCount: Int
    let catchUp: Int
    let onTap: (Int) -> Void
    let onDoubleTap: (Int) -> Void
    let onUserScroll: () -> Void
    let onVisibility: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let tv = ReadingTextView(usingTextLayoutManager: false)
        tv.isEditable = false
        tv.isSelectable = false
        tv.textContainerInset = UIEdgeInsets(top: 22, left: 20, bottom: 230, right: 20)
        tv.alwaysBounceVertical = true
        tv.delegate = context.coordinator
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        single.require(toFail: double)
        tv.addGestureRecognizer(double)
        tv.addGestureRecognizer(single)
        context.coordinator.textView = tv
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let c = context.coordinator
        c.parent = self
        tv.backgroundColor = palette.paper
        let key = "\(chapterIndex)|\(bookTitle)|\(font.rawValue)|\(size)|\(palette.ink)|\(rules.filterEnabled)|\(String(describing: rules.filterRegex?.pattern))|\(fade)"
        if key != c.renderKey {
            c.renderKey = key
            c.build(self)
            c.highlighted = -1
            c.highlight(current, self)
            // Scroll once the text view has its size and the text is laid out.
            DispatchQueue.main.async {
                tv.layoutIfNeeded()
                tv.layoutManager.ensureLayout(for: tv.textContainer)
                c.scrollToCurrent(animated: false)
            }
            c.lastJump = jumpCount
            c.lastCatchUp = catchUp
            return
        }
        if c.highlighted != current { c.highlight(current, self) }
        if jumpCount != c.lastJump {
            c.lastJump = jumpCount
            if c.suppressScroll { c.suppressScroll = false } else if follow { c.scrollToCurrent(animated: false) }
        } else if catchUp != c.lastCatchUp {
            c.lastCatchUp = catchUp
            c.scrollToCurrent(animated: true)
        } else if follow, c.lastFollowed != current {
            c.scrollToCurrent(animated: true)
        }
        c.reportVisibility()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        weak var textView: UITextView?
        var parent: ChapterTextView?
        var renderKey = ""
        var ranges: [NSRange] = []
        var highlighted = -1
        var lastFollowed = -1
        var lastJump = 0
        var lastCatchUp = 0
        var suppressScroll = false
        var lastVisible = true

        func build(_ v: ChapterTextView) {
            guard let tv = textView else { return }
            let p = v.palette
            let body = v.font.uiFont(size: v.size)
            let para = NSMutableParagraphStyle()
            para.lineHeightMultiple = 1.45
            para.paragraphSpacing = v.size * 0.8
            let out = NSMutableAttributedString()
            let small = NSMutableParagraphStyle()
            small.paragraphSpacing = 6
            out.append(NSAttributedString(string: v.bookTitle.uppercased() + "\n", attributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: p.inkSoft, .kern: 1.2, .paragraphStyle: small]))
            let titleStyle = NSMutableParagraphStyle()
            titleStyle.paragraphSpacing = v.size
            out.append(NSAttributedString(string: v.chapter.title + "\n", attributes: [
                .font: v.font.uiFont(size: v.size * 1.25, bold: true), .foregroundColor: p.ink, .paragraphStyle: titleStyle]))
            ranges = []
            for pIdx in v.chapter.paragraphStarts.indices {
                for sIdx in v.chapter.paragraphRange(pIdx) {
                    let text = TextPipeline.displayText(v.chapter.sentences[sIdx], v.rules)
                    let start = out.length
                    out.append(NSAttributedString(string: text, attributes: [.font: body, .foregroundColor: p.ink, .paragraphStyle: para]))
                    ranges.append(NSRange(location: start, length: out.length - start))
                    out.append(NSAttributedString(string: sIdx + 1 < v.chapter.paragraphRange(pIdx).upperBound ? " " : "\n",
                                                  attributes: [.font: body, .paragraphStyle: para]))
                }
            }
            let end = NSMutableParagraphStyle()
            end.alignment = .center
            end.paragraphSpacingBefore = 20
            out.append(NSAttributedString(string: v.isLast ? "End of the book" : "End of \(v.chapter.title)", attributes: [
                .font: UIFont.italicSystemFont(ofSize: 13), .foregroundColor: p.inkSoft, .paragraphStyle: end]))
            tv.attributedText = out
        }

        func highlight(_ current: Int, _ v: ChapterTextView) {
            guard let storage = textView?.textStorage, !ranges.isEmpty else { return }
            let p = v.palette
            storage.beginEditing()
            let lo = highlighted < 0 ? 0 : min(highlighted, current)
            let hi = highlighted < 0 ? ranges.count - 1 : max(highlighted, current)
            for i in max(0, lo)...min(ranges.count - 1, max(0, hi)) {
                let r = ranges[i]
                storage.removeAttribute(.backgroundColor, range: r)
                storage.addAttribute(.foregroundColor, value: (v.fade && i < current) ? p.inkSoft : p.ink, range: r)
            }
            if ranges.indices.contains(current) {
                storage.addAttribute(.backgroundColor, value: p.glow, range: ranges[current])
            }
            storage.endEditing()
            highlighted = current
        }

        func rect(_ i: Int) -> CGRect? {
            guard let tv = textView, ranges.indices.contains(i) else { return nil }
            let lm = tv.layoutManager
            let glyphs = lm.glyphRange(forCharacterRange: ranges[i], actualCharacterRange: nil)
            var r = lm.boundingRect(forGlyphRange: glyphs, in: tv.textContainer)
            r.origin.y += tv.textContainerInset.top
            return r
        }

        func scrollToCurrent(animated: Bool) {
            guard let tv = textView, let v = parent, let r = rect(v.current) else { return }
            lastFollowed = v.current
            let maxY = max(0, tv.contentSize.height - tv.bounds.height + tv.adjustedContentInset.bottom)
            let y = min(maxY, max(-tv.adjustedContentInset.top, r.minY - tv.bounds.height * 0.35))
            tv.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
            DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? 0.4 : 0.05)) { self.reportVisibility() }
        }

        func reportVisibility() {
            guard let tv = textView, let v = parent, let r = rect(v.current) else { return }
            let top = tv.contentOffset.y + tv.adjustedContentInset.top
            let visible = r.minY > top + 20 && r.maxY < tv.contentOffset.y + tv.bounds.height - 230
            if visible != lastVisible {
                lastVisible = visible
                v.onVisibility(visible)
            }
        }

        /// The sentence under a tap, if any.
        private func sentence(at g: UITapGestureRecognizer) -> Int? {
            guard let tv = textView else { return nil }
            var pt = g.location(in: tv)
            pt.x -= tv.textContainerInset.left
            pt.y -= tv.textContainerInset.top
            let idx = tv.layoutManager.characterIndex(for: pt, in: tv.textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
            return ranges.firstIndex { NSLocationInRange(idx, $0) || idx == NSMaxRange($0) }
        }

        /// One tap moves the place to the sentence.
        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let v = parent, let s = sentence(at: g) else { return }
            suppressScroll = true   // a tap doesn't scroll the text
            v.onTap(s)
        }

        /// Two taps move there and start reading.
        @objc func doubleTapped(_ g: UITapGestureRecognizer) {
            guard let v = parent, let s = sentence(at: g) else { return }
            suppressScroll = true
            v.onDoubleTap(s)
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { parent?.onUserScroll() }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { reportVisibility() }
    }
}
