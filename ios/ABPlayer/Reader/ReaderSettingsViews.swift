import SwiftUI
import UniformTypeIdentifiers

/// What the Settings screen is showing on top of itself. The sheets live on the
/// Settings screen, not on these sections: the sections refresh while a book is
/// read (measured speed, status line), and a sheet attached to a refreshing list
/// section gets closed as it is rebuilt.
@MainActor @Observable
final class SettingsPresentation {
    var showVoice = false
    var showShelves = false
    var pickWatchFolder = false
    var pickBackup = false
    var pickBackupFolder = false
    /// Bumped when the backup folder changes (it lives in UserDefaults, which views don't observe).
    var backupFolderTick = 0
    /// The backup folder waiting to be saved to Files.
    var backupURL: URL?
}

/// Settings for ebooks (voice, display, words) or for the whole library
/// (shelves, series, watched folder, backup), depending on `part`.
struct ReaderSettingsSections: View {
    enum Part { case ebooks, library }
    var part: Part
    @Environment(ReaderSettings.self) private var settings
    @Environment(ReaderPlayer.self) private var reader
    @Environment(Library.self) private var library
    @Environment(VoiceStatus.self) private var status
    @State private var gap = 80.0
    @Environment(SettingsPresentation.self) private var present
    @State private var working = false

    var body: some View {
        switch part {
        case .ebooks: ebookSections
        case .library: librarySections
        }
    }

    @ViewBuilder private var ebookSections: some View {
        @Bindable var settings = settings
        Section {
            Picker("Voice", selection: Binding(get: { settings.source }, set: { settings.source = $0; reader.clearAudio() })) {
                ForEach(VoiceSource.allCases) { Text($0.label).tag($0) }
            }
            Button { present.showVoice = true } label: {
                LabeledContent("Voice and speed", value: "\(voiceName) · \(String(format: "%.2g×", settings.speed))")
            }
            .tint(.primary)
            Picker("Skip buttons move by", selection: $settings.skipUnit) {
                ForEach(SkipUnit.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading) {
                LabeledContent("Pause between sentences", value: "\(Int(gap)) ms")
                Slider(value: $gap, in: 50...500, step: 10) { editing in
                    if !editing { settings.gapMs = Int(gap); reader.clearAudio() }
                }
            }
            if let m = reader.measuredSpeed {
                LabeledContent("Measured voice speed", value: String(format: "%.1f×", m.timesFaster))
                    .accessibilityHint(String(format: "Makes speech %.1f times as fast as it's read, plus %.1f seconds a clip, from %d clips", m.timesFaster, m.fixed, m.clips))
            } else {
                LabeledContent("Measured voice speed", value: "—")
            }
            Button("Clear prepared audio") {
                reader.clearAudio()
                status.line = "Prepared audio cleared."
                Task { try? await Task.sleep(for: .seconds(1.5)); if status.line == "Prepared audio cleared." { status.line = "" } }
            }
        } header: {
            Label("Ebooks Read Aloud", systemImage: BookKind.ebookIcon)
        } footer: {
            Text(settings.source == .kokoro
                 ? (KokoroEngine.unavailableReason ?? "Kokoro runs on this \(ThisDevice.name)'s Neural Engine. Nothing is sent anywhere, it works offline, and it keeps reading ahead while the screen is locked.")
                 : "Apple's built-in voices. Kokoro sounds more natural.")
            + Text(status.line.isEmpty ? "" : "\n\n" + status.line)
        }
        .onAppear { gap = Double(settings.gapMs) }

        Section("Ebook display") {
            NavigationLink("Text size, font and theme") { Form { DisplayControls() }.navigationTitle("Ebook Display") }
        }

        Section {
            Toggle(isOn: Binding(get: { settings.filterEnabled }, set: { settings.filterEnabled = $0; reader.clearAudio() })) {
                VStack(alignment: .leading) {
                    Text("Filter strong language in ebooks")
                    Text("Muted in speech, masked on screen").font(.caption).foregroundStyle(.secondary)
                }
            }
            NavigationLink { FilterWordsView() } label: {
                LabeledContent("Words to filter", value: settings.filterWords.isEmpty ? "none added" : "\(settings.filterWords.count) added")
            }
            NavigationLink { PronunciationView() } label: {
                LabeledContent("Pronunciation rules", value: "\(settings.pronunciationRules.count) rule\(settings.pronunciationRules.count == 1 ? "" : "s")")
            }
        } header: {
            Text("Words")
        } footer: {
            Text("The filter list is shared: audiobooks use it when Mute Strong Language is on in that book's player (the speaker button at the top). Pronunciation rules are for ebooks.")
        }
    }

    @ViewBuilder private var librarySections: some View {
        @Bindable var settings = settings
        Section {
            Button { present.showShelves = true } label: { LabeledContent("Shelves", value: "\(settings.shelves.count)") }.tint(.primary)
            Toggle("Group books by series", isOn: $settings.groupSeries)
            if let name = library.watchedFolderName {
                LabeledContent("Watched folder", value: name)
                Text(library.watchedLastScan.map { "Last checked " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not checked yet")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Check now") { Task { await library.scanWatchedFolder(announce: true) } }
                Button("Change folder") { present.pickWatchFolder = true }
                Button("Stop watching", role: .destructive) { library.stopWatching() }
            } else {
                Button("Watch a folder for new ebooks") { present.pickWatchFolder = true }
            }
        } header: {
            Label("Library", systemImage: "books.vertical")
        } footer: {
            Text("Shelves and series apply to audiobooks and ebooks. New EPUBs and PDFs in the watched folder (and its subfolders) are added each time the app opens. They arrive without a shelf; a book you delete isn't added again.")
        }

        Section {
            let _ = present.backupFolderTick
            let folder = library.backupFolderName
            Button {
                working = true
                Task {
                    if folder != nil {
                        await library.backUpToFolder()
                    } else {
                        do { present.backupURL = try await library.makeBackupFolder() } catch { library.message = "Could not make the backup: \(error.localizedDescription)" }
                    }
                    working = false
                }
            } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(folder.map { "Back up to “\($0)”" } ?? "Back up")
                        Text("Books stored in the app, every book's place and bookmarks, and your settings").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if working { ProgressView() } else {
                        Text((UserDefaults.standard.object(forKey: "rd.lastBackup") as? Date)?.formatted(date: .abbreviated, time: .omitted) ?? "Never")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.primary)
            .disabled(working)
            if let folder {
                LabeledContent("Backup folder", value: folder)
                Button("Change backup folder") { present.pickBackupFolder = true }
                Button("Save a copy elsewhere…") {
                    working = true
                    Task {
                        do { present.backupURL = try await library.makeBackupFolder() } catch { library.message = "Could not make the backup: \(error.localizedDescription)" }
                        working = false
                    }
                }
                .disabled(working)
                Button("Stop using this folder", role: .destructive) {
                    library.forgetBackupFolder()
                    present.backupFolderTick += 1
                }
            } else {
                Button("Choose a backup folder (iCloud Drive)") { present.pickBackupFolder = true }
            }
            Button { present.pickBackup = true } label: {
                VStack(alignment: .leading) {
                    Text("Restore or merge from a backup")
                    Text("Adds what is missing; newer positions win; nothing is deleted").font(.caption).foregroundStyle(.secondary)
                }
            }
            .tint(.primary)
        } header: {
            Text("Back up and sync")
        } footer: {
            Text("Choose a folder in iCloud Drive once and every backup is saved there, then uploaded by iOS; restore it after reinstalling or on another device. A backup holds the ebooks and audiobooks stored in the app, with their audio. Books already in another folder aren't copied again: linked audiobooks, and ebooks still in the watched folder. Their place, bookmarks and shelves come back when they're linked or added again.")
        }
    }

    private var voiceName: String {
        settings.source == .kokoro ? friendlyVoiceName(settings.kokoroVoice).name
            : DeviceVoice.voices().first { $0.id == settings.deviceVoice }?.name ?? "Default"
    }
}

/// Attaches Settings' sheets and file pickers to a view that stays put.
struct SettingsPresenters: ViewModifier {
    @Bindable var present: SettingsPresentation
    @Environment(Library.self) private var library
    @Environment(ReaderPlayer.self) private var reader

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $present.showVoice) { VoiceSheet() }
            .sheet(isPresented: $present.showShelves) { ShelvesSheet() }
            .sheet(item: Binding(get: { present.backupURL.map(ShareItem.init) }, set: { if $0 == nil { present.backupURL = nil } })) { item in
                ExportFolderPicker(url: item.url) { saved in
                    if saved { library.backupSaved(); library.message = "Backup saved." }
                    // The temporary copy (clones of the book folders) goes either way.
                    try? FileManager.default.removeItem(at: item.url.deletingLastPathComponent())
                    present.backupURL = nil
                }
                .ignoresSafeArea()
            }
            .fileImporter(isPresented: $present.pickWatchFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { library.setWatchedFolder(url) }
            }
            .fileImporter(isPresented: $present.pickBackupFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    library.setBackupFolder(url)
                    present.backupFolderTick += 1
                }
            }
            .fileImporter(isPresented: $present.pickBackup, allowedContentTypes: [.folder, .zip]) { result in
                if case .success(let url) = result {
                    Task {
                        if Importer.isDirectory(url) {
                            await library.restoreBackupFolder(url)
                        } else {
                            await library.importBackup(url)
                        }
                        reader.clearAudio()
                    }
                }
            }
            .fileDialogDefaultDirectory(library.backupFolderURL())
    }
}

private struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// Saves a folder to Files or iCloud Drive (copied there; the app's own copy stays).
struct ExportFolderPicker: UIViewControllerRepresentable {
    let url: URL
    var done: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let done: (Bool) -> Void
        init(done: @escaping (Bool) -> Void) { self.done = done }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done(true) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done(false) }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct FilterWordsView: View {
    @Environment(ReaderSettings.self) private var settings
    @Environment(ReaderPlayer.self) private var reader
    @Environment(Player.self) private var player
    @State private var text = ""

    var body: some View {
        Form {
            Section {
                TextField("e.g. wordone, wordtwo", text: $text, axis: .vertical)
                    .lineLimit(3...8)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Extra words, separated by commas")
            } footer: {
                Text("Added to the built-in list. Matched words, and words starting with them, are muted in speech and masked on screen in ebooks, and muted in audiobooks that have Mute Strong Language on.")
            }
        }
        .navigationTitle("Words to filter")
        .onAppear { text = settings.filterWords.joined(separator: ", ") }
        .onDisappear {
            let words = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if words != settings.filterWords { settings.filterWords = words; reader.clearAudio(); player.refreshMute() }
        }
    }
}

struct PronunciationView: View {
    @Environment(ReaderSettings.self) private var settings
    @Environment(ReaderPlayer.self) private var reader
    @State private var find = ""
    @State private var replace = ""
    @State private var matchCase = false

    var body: some View {
        Form {
            Section {
                if settings.pronunciationRules.isEmpty { Text("No rules yet").foregroundStyle(.secondary) }
                ForEach(settings.pronunciationRules) { rule in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("“\(rule.find)” → " + (rule.replace.isEmpty ? "skip" : "“\(rule.replace)”"))
                            if rule.matchCase { Text("match case").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button { reader.preview(rule.replace.isEmpty ? rule.find : rule.replace) } label: { Image(systemName: "play.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Preview")
                    }
                }
                .onDelete { settings.pronunciationRules.remove(atOffsets: $0); reader.clearAudio() }
            } footer: {
                Text("Fixes names or words the voice gets wrong, wherever they appear. Speech only; the text on screen is unchanged.")
            }
            Section("Add a rule") {
                TextField("As written (e.g. Ludger)", text: $find).autocorrectionDisabled()
                TextField("Say instead (blank = skip)", text: $replace).autocorrectionDisabled()
                Toggle("Match case", isOn: $matchCase)
                HStack {
                    Button("Preview", systemImage: "play.circle") { reader.preview(replace.isEmpty ? find : replace) }
                        .buttonStyle(.borderless).disabled(find.isEmpty && replace.isEmpty)
                    Spacer()
                    Button("Add rule") {
                        settings.pronunciationRules.append(PronunciationRule(find: find.trimmingCharacters(in: .whitespaces), replace: replace, matchCase: matchCase))
                        find = ""; replace = ""; matchCase = false
                        reader.clearAudio()
                    }
                    .buttonStyle(.borderless)
                    .disabled(find.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .navigationTitle("Pronunciation")
    }
}
