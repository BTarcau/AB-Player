import SwiftUI

/// A book's characters and their voices: find them on the phone with text
/// rules, optionally have Claude Haiku check the lines the rules weren't sure
/// of, and pick a voice for each. Opened from a book's long-press menu and
/// from the reader's player.
struct CharacterVoicesSheet: View {
    let book: Book
    @Environment(ReaderPlayer.self) private var reader
    @Environment(ReaderSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var store = CastStore.shared
    @State private var plan: (scenes: Int, lines: Int, share: Double, cost: Double)?
    @State private var keyDraft = ""
    @State private var hasKey = APIKey.load() != nil
    @State private var confirmAgain = false

    private var cast: BookCast? { store.bookID == book.id ? store.cast : nil }

    var body: some View {
        NavigationStack {
            List {
                if let busy = store.busy {
                    Section { HStack(spacing: 10) { ProgressView(); Text(busy) } }
                }
                if let message = store.message {
                    Section { Text(message).font(.subheadline) }
                }
                if let cast {
                    castSections(cast)
                } else {
                    Section {
                        Text("Lamplight can read each character's lines in a voice of their own, with the narrator reading the rest.")
                        Button("Find Characters", systemImage: "person.2.wave.2") { Task { await store.findCharacters(book); await refreshPlan() } }
                            .disabled(store.busy != nil)
                    } footer: {
                        Text("Works out who says what on this \(ThisDevice.name), in a second or two. Nothing leaves the device. It gets about 9 lines in 10 right; Claude can check the rest afterwards.")
                    }
                }
                if KokoroEngine.unavailableReason != nil {
                    Section { Text("Character voices use Kokoro, which isn't available here.").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Character Voices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                store.message = nil
                store.load(book.id)
                await refreshPlan()
            }
            .confirmationDialog("Find characters again?", isPresented: $confirmAgain, titleVisibility: .visible) {
                Button("Find Again", role: .destructive) { Task { await store.findCharacters(book); await refreshPlan() } }
            } message: {
                Text("Your voice choices and Claude's corrections for this book will be replaced.")
            }
        }
    }

    private func refreshPlan() async { plan = await store.claudePlan(book) }

    /// The narrator in Kokoro too, or back to the cloned narrator.
    private func kokoroOnly(_ on: Bool) {
        if on {
            settings.source = .kokoro
        } else {
            settings.source = PocketEngine.unavailableReason == nil ? .pocket : .device
        }
        reader.clearAudio()
    }

    private func setNarrator(_ source: VoiceSource, _ voice: String) {
        settings.source = source
        switch source {
        case .kokoro: settings.kokoroVoice = voice
        case .pocket: settings.pocketVoice = voice
        case .device: settings.deviceVoice = voice
        }
        reader.clearAudio()
    }

    @ViewBuilder private func castSections(_ cast: BookCast) -> some View {
        Section {
            Toggle("Read characters in their own voices", isOn: Binding(get: { cast.enabled }, set: { store.setEnabled($0) }))
        } footer: {
            Text("\(cast.characters.count) characters, \(cast.dialogueCount) lines of dialogue. The narrator keeps your chosen voice.")
        }

        Section {
            if cast.uncertainCount == 0 {
                Label(cast.claudeLines > 0 ? "Claude has checked every uncertain line." : "The rules were sure of every line.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else if hasKey {
                Button("Improve with Claude", systemImage: "sparkles") { Task { await store.askClaude(book); await refreshPlan() } }
                    .disabled(store.busy != nil)
            } else {
                SecureField("Anthropic API key", text: $keyDraft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save Key") { APIKey.save(keyDraft); keyDraft = ""; hasKey = APIKey.load() != nil }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Claude")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if cast.uncertainCount > 0, let plan {
                    Text("Sends the \(plan.scenes) scenes with lines the rules weren't sure of (\(plan.lines) lines, about \(Int((plan.share * 100).rounded()))% of the book's text) to Claude Haiku at Anthropic, using your API key. About \(CastStore.money(plan.cost)). Only when you tap it.")
                }
                if cast.claudeLines > 0 {
                    Text("Claude has checked \(cast.claudeLines) lines for this book, for about \(CastStore.money(cast.claudeCost)).")
                }
                if hasKey {
                    Button("Remove API key") { APIKey.remove(); hasKey = false }.font(.footnote)
                }
            }
        }

        Section {
            Toggle(isOn: Binding(get: { settings.source == .kokoro }, set: { kokoroOnly($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kokoro only")
                    Text("The narrator reads in Kokoro too: quicker to start and lighter on memory.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(KokoroEngine.unavailableReason != nil)
        }

        Section("Characters") {
            NarratorRow(preview: { reader.preview("The lamp is lit, and the story can begin.") }, choose: setNarrator)
            ForEach(cast.characters) { c in
                CharacterRow(character: c, preview: { voice in
                    reader.preview("I hadn't expected to see you here, not tonight.", kokoroVoice: voice)
                }, choose: { store.setVoice(c.name, $0) })
            }
        }

        Section {
            Button("Find Characters Again", systemImage: "arrow.clockwise") { confirmAgain = true }
                .disabled(store.busy != nil)
            Button("Remove Character Voices", systemImage: "trash", role: .destructive) { store.remove(book.id) }
                .disabled(store.busy != nil)
        }
    }
}

/// The narrator's voice, chosen here as well as in Voice settings.
private struct NarratorRow: View {
    @Environment(ReaderSettings.self) private var settings
    let preview: () -> Void
    let choose: (VoiceSource, String) -> Void

    private var current: String {
        switch settings.source {
        case .kokoro: return friendlyVoiceName(settings.kokoroVoice).name
        case .pocket: return settings.pocketVoice.capitalized
        case .device: return DeviceVoice.voices().first { $0.id == settings.deviceVoice }?.name ?? "Device"
        }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Narrator").font(.body.weight(.semibold))
                Text(settings.source == .pocket ? "Cloned voice · everything that isn't dialogue" : "Everything that isn't dialogue")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Menu {
                if PocketEngine.unavailableReason == nil {
                    Section("Cloned") {
                        ForEach(PocketEngine.voices, id: \.self) { v in
                            Button { choose(.pocket, v) } label: {
                                if settings.source == .pocket && settings.pocketVoice == v { Label(v.capitalized, systemImage: "checkmark") } else { Text(v.capitalized) }
                            }
                        }
                    }
                }
                if KokoroEngine.unavailableReason == nil {
                    Section("Kokoro") {
                        ForEach(KokoroEngine.voices, id: \.self) { v in
                            let f = friendlyVoiceName(v)
                            Button { choose(.kokoro, v) } label: {
                                if settings.source == .kokoro && settings.kokoroVoice == v { Label("\(f.name) · \(f.detail)", systemImage: "checkmark") } else { Text("\(f.name) · \(f.detail)") }
                            }
                        }
                    }
                }
            } label: {
                Text(current).font(.subheadline)
            }
            Button(action: preview) { Image(systemName: "play.circle").font(.title3) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Hear the narrator")
        }
    }
}

private struct CharacterRow: View {
    let character: CastCharacter
    let preview: (String) -> Void
    let choose: (String?) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(character.name).font(.body.weight(.semibold))
                Text("\(character.lines) line\(character.lines == 1 ? "" : "s")" + (character.aliases.isEmpty ? "" : " · also \(character.aliases.joined(separator: ", "))"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Menu {
                Button("Narrator's voice") { choose(nil) }
                Section("Female") { ForEach(KokoroEngine.voices.filter { $0.dropFirst().hasPrefix("f") }, id: \.self) { v in voiceButton(v) } }
                Section("Male") { ForEach(KokoroEngine.voices.filter { $0.dropFirst().hasPrefix("m") }, id: \.self) { v in voiceButton(v) } }
            } label: {
                Text(character.voice.map { friendlyVoiceName($0).name } ?? "Narrator").font(.subheadline)
            }
            if let v = character.voice {
                Button { preview(v) } label: { Image(systemName: "play.circle").font(.title3) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Hear \(character.name)'s voice")
            }
        }
    }

    private func voiceButton(_ v: String) -> some View {
        let f = friendlyVoiceName(v)
        return Button { choose(v) } label: {
            if character.voice == v { Label("\(f.name) · \(f.detail)", systemImage: "checkmark") } else { Text("\(f.name) · \(f.detail)") }
        }
    }
}
