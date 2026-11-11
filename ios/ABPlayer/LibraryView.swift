import SwiftUI
import UniformTypeIdentifiers

enum AddMode {
    case linkFolders, copyFolders, files, ebooks, watchFolder
    var types: [UTType] {
        switch self {
        case .files: return [.audio]
        case .ebooks: return [UTType(filenameExtension: "epub") ?? .data, .pdf]
        default: return [.folder]
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case recent = "Recently opened", title = "Title", author = "Author", added = "Recently added"
    var id: String { rawValue }
}

/// What the library shows: "all", "listening", "new", "finished" or "shelf:<name>".
typealias LibraryFilter = String

struct LibraryView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(ReaderPlayer.self) private var reader
    @Environment(ReaderSettings.self) private var readerSettings
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var search = ""
    @AppStorage("libraryShelf") private var filter: LibraryFilter = "all"
    @AppStorage("librarySort") private var sort: LibrarySort = .recent
    @AppStorage("lastOpenedText") private var lastOpenedText = false
    @State private var showPlayer = false
    @State private var showReader = false
    @State private var showSettings = false
    @State private var showHowTo = false
    @State private var showShelves = false
    /// The picker's mode stays set after it closes, so its result knows whether to link or copy.
    @State private var pickerMode: AddMode = .linkFolders
    @State private var showPicker = false
    @State private var editing: Book?
    @State private var confirmDelete: Book?

    private var visibleBooks: [Book] {
        var list = library.books.filter { book in
            switch filter {
            case "all": return true
            case "listening": return book.status == .inProgress
            case "new": return book.status == .notStarted
            case "finished": return book.status == .finished
            default: return book.shelves.contains(String(filter.dropFirst(6)))
            }
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter {
                $0.title.localizedCaseInsensitiveContains(q) || $0.author.localizedCaseInsensitiveContains(q)
                    || $0.narrator.localizedCaseInsensitiveContains(q) || $0.series.localizedCaseInsensitiveContains(q)
            }
        }
        switch sort {
        case .recent:
            list.sort { ($0.lastPlayed ?? .distantPast, $0.createdAt) > ($1.lastPlayed ?? .distantPast, $1.createdAt) }
        case .title:
            list.sort { Importer.naturalLess($0.title, $1.title) }
        case .author:
            list.sort { a, b in
                // Books without an author go last.
                let ka = a.author.isEmpty ? "\u{FFFF}" : a.author
                let kb = b.author.isEmpty ? "\u{FFFF}" : b.author
                if ka.localizedCaseInsensitiveCompare(kb) != .orderedSame { return Importer.naturalLess(ka, kb) }
                return Importer.naturalLess(a.title, b.title)
            }
        case .added:
            list.sort { $0.createdAt > $1.createdAt }
        }
        return list
    }

    /// Runs of single books, and series of two or more visible books gathered
    /// where their most recent member would sit, in series order.
    private enum Group: Identifiable {
        case books([Book])
        case series(String, [Book])
        var id: String {
            switch self {
            case .books(let b): return "b-" + (b.first?.id.uuidString ?? "")
            case .series(let name, _): return "s-" + name
            }
        }
    }

    private var groups: [Group] {
        let list = visibleBooks
        guard readerSettings.groupSeries else { return [.books(list)] }
        let key = { (b: Book) in b.series.trimmingCharacters(in: .whitespaces).lowercased() }
        var counts: [String: Int] = [:]
        for b in list where !key(b).isEmpty { counts[key(b), default: 0] += 1 }
        var out: [Group] = []
        var placed = Set<String>()
        var run: [Book] = []
        for b in list {
            let k = key(b)
            if !k.isEmpty, counts[k, default: 0] >= 2 {
                guard !placed.contains(k) else { continue }
                placed.insert(k)
                if !run.isEmpty { out.append(.books(run)); run = [] }
                let members = list.filter { key($0) == k }.sorted {
                    ($0.seriesIndex ?? .infinity, $1.lastPlayed ?? .distantPast) < ($1.seriesIndex ?? .infinity, $0.lastPlayed ?? .distantPast)
                }
                out.append(.series(b.series, members))
            } else {
                run.append(b)
            }
        }
        if !run.isEmpty { out.append(.books(run)) }
        return out
    }

    private var showsReaderMini: Bool { reader.bookID != nil && (lastOpenedText || player.book == nil) }
    private var hasMini: Bool { showsReaderMini || player.book != nil }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Lamplight")
                .toolbar { toolbar }
                .safeAreaInset(edge: .bottom) {
                    if showsReaderMini {
                        ReaderMiniPlayer { showReader = true }
                    } else if player.book != nil {
                        MiniPlayer { showPlayer = true }
                    }
                }
        }
        .overlay(alignment: .bottom) { ToastOverlay().padding(.bottom, hasMini ? 150 : 80) }
        .overlay { ImportOverlay() }
        .animation(.default, value: library.message)
        .sheet(isPresented: $showPlayer) { PlayerView() }
        .fullScreenCover(isPresented: $showReader) { ReaderView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showHowTo) { HowToAddView() }
        .sheet(isPresented: $showShelves) { ShelvesSheet() }
        .sheet(item: $editing) { book in EditBookView(book: book) }
        .fileImporter(isPresented: $showPicker,
                      allowedContentTypes: pickerMode.types,
                      allowsMultipleSelection: pickerMode != .watchFolder) { result in
            let mode = pickerMode
            if case .success(let urls) = result {
                if mode == .watchFolder {
                    if let url = urls.first { library.setWatchedFolder(url) }
                } else {
                    Task { await library.importItems(urls, link: mode == .linkFolders) }
                }
            }
        }
        .confirmationDialog("Delete “\(confirmDelete?.title ?? "")” from this \(ThisDevice.name)?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Book", role: .destructive) {
                if let book = confirmDelete { delete(book) }
            }
        } message: {
            Text("Its progress and bookmarks are removed. Your original files are not affected.")
        }
        .onChange(of: readerSettings.shelves) { _, shelves in
            if filter.hasPrefix("shelf:"), !shelves.contains(String(filter.dropFirst(6))) { filter = "all" }
        }
    }

    @ViewBuilder private var content: some View {
        if library.books.isEmpty {
            ContentUnavailableView {
                Label("No books yet", systemImage: "books.vertical")
            } description: {
                Text("Lamplight plays **audiobooks** (a folder of audio files is one book) and reads **ebooks** (EPUB or PDF) aloud with a natural voice.")
            } actions: {
                Button("Add an Audiobook", systemImage: BookKind.audiobookIcon) { pick(.linkFolders) }.buttonStyle(.borderedProminent)
                Button("Add an Ebook", systemImage: BookKind.ebookIcon) { pick(.ebooks) }.buttonStyle(.borderedProminent)
                Button("Other ways to add books") { showHowTo = true }
            }
        } else if sizeClass == .regular {
            grid
        } else {
            List {
                Section {
                    shelfPills
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
                ForEach(groups) { group in
                    switch group {
                    case .books(let list):
                        Section { ForEach(list) { row($0, inSeries: false) } }
                    case .series(let name, let list):
                        Section {
                            ForEach(list) { row($0, inSeries: true) }
                        } header: {
                            let done = list.filter(\.finished).count
                            HStack {
                                Text(name).font(.headline.weight(.bold)).textCase(nil).foregroundStyle(.primary)
                                Spacer()
                                Text("\(list.count) books" + (done > 0 ? " · \(done) finished" : "")).textCase(nil)
                            }
                        }
                    }
                }
                Section {
                } footer: {
                    if visibleBooks.isEmpty {
                        Text(!search.isEmpty ? "No books match “\(search)”."
                             : filter.hasPrefix("shelf:") ? "Nothing on this shelf yet. Long-press a book and choose Shelves to add it." : "No books here.")
                            .frame(maxWidth: .infinity).padding(.top, 24)
                    } else {
                        StorageFooter()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: "Titles, authors, narrators, series")
        }
    }

    /// iPad (and other wide windows): covers on a shelf instead of a list.
    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                shelfPills
                ForEach(groups) { group in
                    switch group {
                    case .books(let list):
                        tiles(list, inSeries: false)
                    case .series(let name, let list):
                        VStack(alignment: .leading, spacing: 12) {
                            let done = list.filter(\.finished).count
                            HStack(alignment: .firstTextBaseline) {
                                Text(name).font(.title3.weight(.bold))
                                Spacer()
                                Text("\(list.count) books" + (done > 0 ? " · \(done) finished" : ""))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            tiles(list, inSeries: true)
                        }
                    }
                }
                if visibleBooks.isEmpty {
                    Text(!search.isEmpty ? "No books match “\(search)”."
                         : filter.hasPrefix("shelf:") ? "Nothing on this shelf yet. Long-press a book and choose Shelves to add it." : "No books here.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 24)
                } else {
                    StorageFooter().foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .searchable(text: $search, prompt: "Titles, authors, narrators, series")
    }

    private func tiles(_ list: [Book], inSeries: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 24, alignment: .top)],
                  alignment: .leading, spacing: 28) {
            ForEach(list) { book in
                BookTile(book: book, isCurrent: player.bookID == book.id || reader.bookID == book.id, inSeries: inSeries)
                    .contentShape(Rectangle())
                    .onTapGesture { open(book) }
                    .contextMenu { menu(for: book) }
            }
        }
    }

    private var shelfPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pill("All", "all")
                pill("In Progress", "listening")
                pill("Not Started", "new")
                ForEach(readerSettings.shelves, id: \.self) { pill($0, "shelf:" + $0) }
                pill("Finished", "finished")
                Button { showShelves = true } label: {
                    Label("Edit shelves", systemImage: "pencil").font(.subheadline)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.secondary))
                }
                .tint(.primary)
            }
            .padding(.horizontal, 4)
        }
    }

    private func pill(_ label: String, _ value: LibraryFilter) -> some View {
        let on = filter == value
        return Button { filter = value } label: {
            Text(label).font(.subheadline.weight(on ? .semibold : .regular))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(on ? Color.accentColor : Color(.secondarySystemGroupedBackground), in: Capsule())
                .foregroundStyle(on ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func row(_ book: Book, inSeries: Bool) -> some View {
        BookRow(book: book, isCurrent: player.bookID == book.id || reader.bookID == book.id, inSeries: inSeries)
            .contentShape(Rectangle())
            .onTapGesture { open(book) }
            .contextMenu { menu(for: book) }
            .swipeActions(edge: .trailing) {
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = book }
                Button("Edit", systemImage: "pencil") { editing = book }
            }
            .swipeActions(edge: .leading) {
                if book.finished {
                    Button("Unfinished", systemImage: "arrow.uturn.backward") { markUnfinished(book) }
                } else {
                    Button("Finished", systemImage: "checkmark") { markFinished(book) }.tint(.green)
                }
            }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Settings", systemImage: "gearshape") { showSettings = true }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(LibrarySort.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            Menu {
                Section("Audiobook") {
                    Button("Link an Audiobook Folder", systemImage: "link") { pick(.linkFolders) }
                    Button("Copy Audiobook Folders into App", systemImage: "square.and.arrow.down") { pick(.copyFolders) }
                    Button("Copy Audio Files as One Audiobook", systemImage: BookKind.audiobookIcon) { pick(.files) }
                }
                Section("Ebook (EPUB or PDF, read aloud)") {
                    Button("Add an Ebook", systemImage: BookKind.ebookIcon) { pick(.ebooks) }
                    Button("Watch a Folder for Ebooks", systemImage: "eye") { pick(.watchFolder) }
                }
                Divider()
                Button("Other Ways to Add Books", systemImage: "questionmark.circle") { showHowTo = true }
            } label: {
                Label("Add Book", systemImage: "plus")
            }
        }
    }

    @ViewBuilder private func menu(for book: Book) -> some View {
        Button(book.isText ? "Read Aloud" : "Listen", systemImage: BookKind.icon(book)) {
            if book.isText {
                lastOpenedText = true
                Task { await reader.open(book); reader.play() }
            } else {
                lastOpenedText = false
                player.open(book, autoplay: true)
            }
        }
        Button("Edit Details", systemImage: "pencil") { editing = book }
        Menu {
            ForEach(readerSettings.shelves, id: \.self) { shelf in
                Toggle(shelf, isOn: Binding(
                    get: { library.book(book.id)?.shelves.contains(shelf) ?? false },
                    set: { on in library.mutate(book.id) { b in if on { b.shelves.append(shelf) } else { b.shelves.removeAll { $0 == shelf } } } }))
            }
            Divider()
            Button("Edit Shelves…", systemImage: "pencil") { showShelves = true }
        } label: {
            Label("Shelves", systemImage: "books.vertical")
        }
        if book.link != nil {
            Button("Rescan Folder", systemImage: "arrow.clockwise") { rescan(book) }
        }
        Button("Start Over", systemImage: "backward.end") { restart(book) }
        if book.finished {
            Button("Mark as Unfinished", systemImage: "arrow.uturn.backward") { markUnfinished(book) }
        } else {
            Button("Mark as Finished", systemImage: "checkmark.circle") { markFinished(book) }
        }
        Divider()
        Button("Delete from \(ThisDevice.name)", systemImage: "trash", role: .destructive) { confirmDelete = book }
    }

    private func open(_ book: Book) {
        if book.isText {
            lastOpenedText = true
            showReader = true
            Task { await reader.open(book) }
        } else {
            lastOpenedText = false
            player.open(book)
            showPlayer = true
        }
    }

    private func delete(_ book: Book) {
        if player.bookID == book.id { player.close() }
        if reader.bookID == book.id { reader.close() }
        library.delete(book)
    }

    private func pick(_ mode: AddMode) {
        pickerMode = mode
        showPicker = true
    }

    private func rescan(_ book: Book) {
        let wasCurrent = player.bookID == book.id
        if wasCurrent { player.pause() }
        Task {
            // Reopen so the player picks up the new file list.
            if await library.rescan(book), wasCurrent, let updated = library.book(book.id) {
                player.close()
                player.open(updated)
            }
        }
    }

    private func restart(_ book: Book) {
        if book.isText {
            if reader.bookID == book.id { reader.seek(0, 0) }
            library.mutate(book.id) {
                $0.finished = false
                $0.text?.chapter = 0; $0.text?.sentence = 0; $0.text?.charsRead = 0; $0.text?.positionAt = Date()
            }
            return
        }
        library.mutate(book.id) { $0.position = 0; $0.finished = false }
        if player.bookID == book.id { player.jumpPaused(to: 0) }
    }

    private func markFinished(_ book: Book) {
        if player.bookID == book.id { player.pause() }
        if reader.bookID == book.id { reader.pause() }
        library.mutate(book.id) {
            $0.finished = true
            $0.position = $0.duration
            if let t = $0.text { $0.text?.charsRead = t.totalChars }
        }
    }

    private func markUnfinished(_ book: Book) {
        if book.isText { restart(book); return }
        library.mutate(book.id) { $0.finished = false; $0.position = 0 }
        if player.bookID == book.id { player.jumpPaused(to: 0) }
    }
}

struct BookRow: View {
    let book: Book
    let isCurrent: Bool
    var inSeries = false

    var body: some View {
        HStack(spacing: 14) {
            CoverView(book: book, width: 68, corner: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(book.title).font(.headline).lineLimit(2)
                if !book.author.isEmpty {
                    Text(book.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if isCurrent { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint) }
                    Image(systemName: BookKind.icon(book)).foregroundStyle(.tint).accessibilityHidden(true)
                    Text(bookSubtitle(book))
                }
                .font(.caption).foregroundStyle(.secondary)
                let tags = seriesTag + book.shelves
                if !tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag).font(.caption2.weight(.medium))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                        }
                    }
                    .lineLimit(1)
                }
                ProgressView(value: book.progress)
                    .tint(book.finished ? .green : .accentColor)
                    .opacity(book.status == .notStarted ? 0 : 1)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var seriesTag: [String] {
        guard !book.series.isEmpty else { return [] }
        let n = book.seriesIndex.map { $0.rounded() == $0 ? String(Int($0)) : String($0) }
        if inSeries { return [n.map { "#" + $0 } ?? "Series"] }
        return [book.series + (n.map { " #" + $0 } ?? "")]
    }
}

/// A book in the iPad grid: its cover standing on the shelf (tall for ebooks,
/// square for audiobooks), then title, author and progress.
struct BookTile: View {
    let book: Book
    let isCurrent: Bool
    var inSeries = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Every tile reserves a tall cover's height, so the titles line up.
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay(alignment: .bottom) {
                    CoverView(book: book, corner: 8)
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                        .overlay(alignment: .topTrailing) {
                            if book.finished {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title3).foregroundStyle(.white, .green).padding(6)
                            }
                        }
                }
            HStack(spacing: 4) {
                if isCurrent { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint).font(.caption) }
                Text(book.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            }
            if let detail = detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 6) {
                Image(systemName: BookKind.icon(book)).foregroundStyle(.tint).accessibilityHidden(true)
                Text(bookSubtitle(book)).lineLimit(2)
            }
            .font(.caption2).foregroundStyle(.secondary)
            ProgressView(value: book.progress)
                .tint(book.finished ? .green : .accentColor)
                .opacity(book.status == .notStarted ? 0 : 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String? {
        if inSeries, let n = book.seriesIndex { return "#\(n.rounded() == n ? String(Int(n)) : String(n))" + (book.author.isEmpty ? "" : " · \(book.author)") }
        return book.author.isEmpty ? nil : book.author
    }
}

struct StorageFooter: View {
    @Environment(Library.self) private var library
    @State private var text = ""

    var body: some View {
        VStack(spacing: 4) {
            Text(text)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
        }
        .font(.footnote)
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .task(id: library.books.count) { text = await library.storageSummary() }
    }
}

struct MiniPlayer: View {
    @Environment(Player.self) private var player
    var open: () -> Void

    var body: some View {
        if let book = player.book {
            let i = book.chapterIndex(at: player.currentTime)
            let (start, end) = book.chapterBounds(i)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    CoverView(book: book, size: 44, corner: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.chapters.indices.contains(i) ? book.chapters[i].title : book.title)
                            .font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(book.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button { player.skip(-Settings.back) } label: {
                        Image(systemName: "gobackward.\(Int(Settings.back))").font(.title3)
                    }
                    .accessibilityLabel("Back \(Int(Settings.back)) seconds")
                    Button { player.togglePlay() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2).frame(width: 36, height: 36)
                    }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 10)
                ProgressView(value: end > start ? (player.currentTime - start) / (end - start) : 0)
                    .progressViewStyle(.linear).scaleEffect(y: 0.6)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 10).padding(.bottom, 4)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .accessibilityAction(named: "Open player", open)
        }
    }
}
