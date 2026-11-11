import SwiftUI

// MARK: - Contents and search

struct ContentsSheet: View {
    @Environment(ReaderPlayer.self) private var reader
    @Environment(ReaderSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    let palette: ReaderPalette
    @State private var query = ""
    @State private var results: [Hit] = []
    @State private var capped = false

    struct Hit: Identifiable {
        let id: String
        let chapter: Int
        let sentence: Int
        let snippet: AttributedString
        let chapterTitle: String
    }

    var body: some View {
        NavigationStack {
            List {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    chapterList
                } else {
                    searchResults
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search this book")
            .onSubmit(of: .search) { if let first = results.first { go(first.chapter, first.sentence) } }
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(150))
                search()
            }
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var chapterList: some View {
        ScrollViewReader { proxy in
            ForEach(Array(reader.chapters.enumerated()), id: \.offset) { i, chapter in
                Button { go(i, 0) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chapter.title).fontWeight(i == reader.ch ? .semibold : .regular)
                            Text("about \(Fmt.long(Double(chapter.charCount) * reader.secPerCharNow))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if i < reader.ch {
                            Text("read").font(.caption).foregroundStyle(.secondary)
                        } else if i == reader.ch {
                            Text("\(chapter.sentences.isEmpty ? 0 : reader.s * 100 / chapter.sentences.count)%")
                                .font(.caption.monospacedDigit()).foregroundStyle(Color(palette.brass))
                        }
                    }
                }
                .tint(.primary)
                .listRowBackground(i == reader.ch ? Color(palette.glow) : nil)
                .id(i)
            }
            .onAppear { proxy.scrollTo(reader.ch, anchor: .center) }
        }
    }

    @ViewBuilder private var searchResults: some View {
        if results.isEmpty {
            Text("Nothing found for “\(query)”").foregroundStyle(.secondary)
        } else {
            Section {
                ForEach(results) { hit in
                    Button { go(hit.chapter, hit.sentence) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(hit.snippet).font(.subheadline)
                            Text(hit.chapterTitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tint(.primary)
                }
            } footer: {
                Text(capped ? "First 100 matches shown. Add a word to narrow it down."
                     : "\(results.count) match\(results.count == 1 ? "" : "es")")
            }
        }
    }

    private func go(_ c: Int, _ s: Int) {
        reader.seek(c, s)
        dismiss()
    }

    /// Case-insensitive literal search; the first match per sentence, up to 100.
    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = []; capped = false; return }
        var hits: [Hit] = []
        outer: for (c, chapter) in reader.chapters.enumerated() {
            for (s, sentence) in chapter.sentences.enumerated() {
                guard let r = sentence.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
                let before = sentence[..<r.lowerBound]
                let after = sentence[r.upperBound...]
                let pre = (before.count > 60 ? "…" : "") + String(before.suffix(60))
                let post = String(after.prefix(90)) + (after.count > 90 ? "…" : "")
                var snippet = AttributedString(TextPipeline.displayText(pre, settings.rules))
                var match = AttributedString(String(sentence[r]))
                match.backgroundColor = Color(palette.glow)
                match.font = .subheadline.weight(.semibold)
                snippet += match
                snippet += AttributedString(TextPipeline.displayText(post, settings.rules))
                hits.append(Hit(id: "\(c)-\(s)", chapter: c, sentence: s, snippet: snippet, chapterTitle: chapter.title))
                if hits.count >= 100 { break outer }
            }
        }
        results = hits
        capped = hits.count >= 100
    }
}

// MARK: - Display (Aa)

struct DisplaySheet: View {
    @Environment(ReaderSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { DisplayControls() }
                .navigationTitle("Display")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Text size, font, theme, follow along and fade; shared by the Aa sheet and Settings.
struct DisplayControls: View {
    @Environment(ReaderSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section("Text size") {
            HStack {
                Text("A").font(.system(size: 14))
                Slider(value: $settings.fontSize, in: 14...30, step: 1).accessibilityLabel("Text size")
                Text("A").font(.system(size: 26))
            }
        }
        Section("Font") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(ReaderFont.allCases) { f in
                        Button { settings.font = f } label: {
                            VStack(spacing: 4) {
                                Text("Aa").font(f.font(size: 24))
                                Text(f.label).font(.caption2)
                            }
                            .frame(width: 72, height: 64)
                            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(settings.font == f ? Color.accentColor : .secondary.opacity(0.3), lineWidth: settings.font == f ? 2 : 1))
                        }
                        .tint(.primary)
                        .accessibilityAddTraits(settings.font == f ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            }
        }
        Section {
            Picker("Theme", selection: $settings.theme) {
                ForEach(ReaderTheme.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle(isOn: $settings.follow) {
                VStack(alignment: .leading) {
                    Text("Follow along")
                    Text("Keep the sentence being read in view").font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Fade text already read", isOn: $settings.fadeRead)
        }
    }
}

// MARK: - Voice and speed

struct VoiceSheet: View {
    @Environment(ReaderPlayer.self) private var reader
    @Environment(ReaderSettings.self) private var settings
    @Environment(VoiceStatus.self) private var status
    @Environment(\.dismiss) private var dismiss
    @State private var fineSpeed = 1.0

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            List {
                Section("Speed") {
                    HStack {
                        ForEach([0.8, 1.0, 1.2, 1.5, 2.0], id: \.self) { s in
                            Button(String(format: "%.1f×", s)) { setSpeed(s) }
                                .buttonStyle(.bordered)
                                .tint(abs(settings.speed - s) < 0.01 ? .accentColor : .secondary)
                                .font(.subheadline.monospacedDigit())
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("Fine speed  \(String(format: "%.2f×", fineSpeed))").font(.subheadline)
                        Slider(value: $fineSpeed, in: 0.6...2.0, step: 0.05) { editing in
                            if !editing { setSpeed(fineSpeed) }
                        }
                    }
                }
                Section {
                    Picker("Voice", selection: Binding(get: { settings.source }, set: { settings.source = $0; reader.clearAudio() })) {
                        ForEach(VoiceSource.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Button("Hear the selected voice", systemImage: "play.circle") {
                        reader.preview("The lamp is lit, and the story can begin.")
                    }
                }
                Section {
                    if settings.source == .kokoro {
                        if let reason = KokoroEngine.unavailableReason {
                            Text(reason).foregroundStyle(.secondary)
                        }
                        ForEach(KokoroEngine.voices, id: \.self) { id in
                            let name = friendlyVoiceName(id)
                            row(name.name, name.detail, selected: settings.kokoroVoice == id) {
                                settings.kokoroVoice = id
                                reader.clearAudio()
                            }
                        }
                    } else {
                        ForEach(DeviceVoice.voices()) { v in
                            row(v.name, v.detail, selected: settings.deviceVoice == v.id) {
                                settings.deviceVoice = v.id
                                reader.clearAudio()
                            }
                        }
                    }
                } header: {
                    Text("Voice")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if settings.source == .device {
                            Text("Better voices can be downloaded in the iPhone's Settings › Accessibility › Spoken Content › Voices.")
                        }
                        if !status.line.isEmpty { Text(status.line) }
                    }
                }
            }
            .navigationTitle("Voice & speed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { fineSpeed = settings.speed }
        }
    }

    private func row(_ name: String, _ detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading) {
                    Text(name)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
        .tint(.primary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func setSpeed(_ s: Double) {
        fineSpeed = s
        reader.setSpeed(s)
    }

}
