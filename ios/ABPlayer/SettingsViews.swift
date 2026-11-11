import PhotosUI
import SwiftUI

struct SettingsView: View {
    @Environment(Player.self) private var player
    @State private var present = SettingsPresentation()
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Settings.skipBack) private var skipBack = 15
    @AppStorage(Settings.skipForward) private var skipForward = 30
    @AppStorage(Settings.smartRewind) private var smartRewind = true
    // SF Symbols has gobackward/goforward icons for these values.
    private let intervals = [5, 10, 15, 30, 45, 60, 75, 90]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Skip back", selection: $skipBack) {
                        ForEach(intervals, id: \.self) { Text("\($0) seconds").tag($0) }
                    }
                    Picker("Skip forward", selection: $skipForward) {
                        ForEach(intervals, id: \.self) { Text("\($0) seconds").tag($0) }
                    }
                    Toggle("Smart Rewind", isOn: $smartRewind)
                } header: {
                    Label("Audiobooks", systemImage: BookKind.audiobookIcon)
                } footer: {
                    Text("Smart Rewind goes back a little when you resume: 2 seconds after a short pause, up to 20 seconds after an hour or more. After a phone call it always goes back 3 seconds.")
                }
                ReaderSettingsSections(part: .ebooks)
                ReaderSettingsSections(part: .library)
                Section {
                    NavigationLink("How to add books") { HowToAddView(embedded: true) }
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                } header: {
                    Label("App", systemImage: "sparkles")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: skipBack) { player.updateSkipIntervals() }
            .onChange(of: skipForward) { player.updateSkipIntervals() }
        }
        .environment(present)
        .modifier(SettingsPresenters(present: present))
    }
}

struct HowToAddView: View {
    var embedded = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let content = List {
            Section {
                Text("**Link an Audiobook Folder** plays a folder where it is, in iCloud Drive or Files. Nothing is copied, and iCloud files download when needed. Choose **Keep Downloaded** on the folder in Files to listen offline.")
                Text("**Copy Audiobook Folders into App** copies them in, so they're always available offline. Pick a folder of book folders to add them all at once.")
                Text("**Copy Audio Files as One Audiobook** adds the selected files as one book. Several M4B files with different titles become separate audiobooks.")
                Text("Files play in name order, so number them: `01 Intro.mp3`, `02 Chapter One.mp3`. Subfolders called `CD1`, `Disc 2`, `Part 3` stay together as one book. Chapters inside M4B files are used.")
            } header: {
                Label("Audiobooks", systemImage: BookKind.audiobookIcon)
            } footer: {
                Text("MP3, M4A, M4B, AAC, WAV, FLAC, AIFF and CAF. DRM-protected Audible (AAX) and Ogg files can't be played.")
            }
            Section {
                Text("**Add an Ebook** copies EPUB or PDF files in. Their text is read aloud by the natural voice (Kokoro), on this iPhone.")
                Text("**Watch a Folder for Ebooks** adds every new EPUB and PDF in a folder (and its subfolders) each time Lamplight opens.")
                Text("Chapters come from the EPUB's contents or the PDF's bookmarks. Title, author, series and cover come from the file.")
            } header: {
                Label("Ebooks", systemImage: BookKind.ebookIcon)
            } footer: {
                Text("DRM-protected EPUBs (from most stores) and scanned PDFs (pictures of pages) can't be read.")
            }
            Section("Either kind") {
                Text("Copy audiobook folders, EPUBs or PDFs into **Files › On My iPhone › Lamplight**. They're added the next time you open Lamplight, and the copies there are removed. With a Mac, you can drag them onto Lamplight in Finder (under **Files**).")
                Text("Share a file from another app and choose **Lamplight**, or use **Open in…**.")
                Text("Title, author and narrator can be changed any time with **Edit Details**.")
            }
        }
        .navigationTitle("Adding Books")
        .navigationBarTitleDisplayMode(.inline)

        if embedded {
            content
        } else {
            NavigationStack {
                content.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
        }
    }
}

struct EditBookView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    let book: Book
    @State private var title = ""
    @State private var author = ""
    @State private var narrator = ""
    @State private var series = ""
    @State private var seriesNumber = ""
    @State private var shelves: [String] = []
    @State private var photo: PhotosPickerItem?
    @Environment(ReaderSettings.self) private var readerSettings

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        CoverView(book: library.book(book.id) ?? book, size: 160, corner: 12)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    PhotosPicker("Choose Cover from Photos", selection: $photo, matching: .images)
                }
                Section("Details") {
                    TextField("Title", text: $title)
                    TextField("Author", text: $author)
                    if !book.isText { TextField("Narrator", text: $narrator) }
                }
                Section {
                    TextField("Series name", text: $series)
                    TextField("Number in series", text: $seriesNumber).keyboardType(.decimalPad)
                } header: {
                    Text("Series")
                } footer: {
                    Text("Books in the same series sit together in the library, in order.")
                }
                Section("Shelves") {
                    if readerSettings.shelves.isEmpty {
                        Text("No shelves yet. Add some under Edit shelves in the library.").foregroundStyle(.secondary)
                    }
                    ForEach(readerSettings.shelves, id: \.self) { shelf in
                        Toggle(shelf, isOn: Binding(
                            get: { shelves.contains(shelf) },
                            set: { on in if on { shelves.append(shelf) } else { shelves.removeAll { $0 == shelf } } }))
                    }
                }
                Section {
                    if let t = book.text {
                        LabeledContent("Format", value: t.format.uppercased())
                        LabeledContent("File", value: t.sourceName)
                        LabeledContent("Length", value: "about " + Fmt.long(book.totalTime))
                        LabeledContent("Chapters", value: "\(t.chapterTitles.count)")
                        if !t.subjects.isEmpty { LabeledContent("Subjects", value: t.subjects.joined(separator: ", ")) }
                    } else {
                        LabeledContent("Location", value: library.locationDescription(book))
                        LabeledContent("Length", value: Fmt.long(book.duration))
                        LabeledContent("Files", value: "\(book.tracks.count)")
                        LabeledContent("Chapters", value: "\(book.chapters.count)")
                    }
                    LabeledContent("Added", value: book.createdAt.formatted(date: .abbreviated, time: .omitted))
                }
            }
            .navigationTitle("Edit Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                title = book.title
                author = book.author
                narrator = book.narrator
                series = book.series
                seriesNumber = book.seriesIndex.map { $0.rounded() == $0 ? String(Int($0)) : String($0) } ?? ""
                shelves = book.shelves
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        library.setCover(data, for: book)
                        if player.bookID == book.id { player.refreshArtwork() }
                    }
                }
            }
        }
    }

    private func save() {
        library.mutate(book.id) {
            $0.title = title.trimmingCharacters(in: .whitespaces)
            $0.author = author.trimmingCharacters(in: .whitespaces)
            $0.narrator = narrator.trimmingCharacters(in: .whitespaces)
            let newSeries = series.trimmingCharacters(in: .whitespaces)
            let newIndex = newSeries.isEmpty ? nil : Double(seriesNumber.replacingOccurrences(of: ",", with: "."))
            if newSeries != $0.series || newIndex != $0.seriesIndex {
                $0.series = newSeries
                $0.seriesIndex = newIndex
                $0.seriesManual = true
            }
            $0.shelves = shelves
        }
        if player.bookID == book.id { player.updateNowPlaying() }
        dismiss()
    }
}
