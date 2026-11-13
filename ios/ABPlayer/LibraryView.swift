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
    /// Shows only audiobooks; separate from the shelf pills.
    @AppStorage("libraryAudioOnly") private var audioOnly = false
    /// Whether the shelf has scrolled under the pills, so the top frosts only then.
    @State private var pillsPinned = false
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

    private var visibleBooks: [Book] { filteredBooks(searching: true) }

    private func filteredBooks(searching: Bool) -> [Book] {
        var list = library.books.filter { book in
            if audioOnly && book.isText { return false }
            switch filter {
            case "all": return true
            case "listening": return book.status == .inProgress
            case "new": return book.status == .notStarted
            case "finished": return book.hasBeenRead
            default: return book.shelves.contains(String(filter.dropFirst(6)))
            }
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        if searching, !q.isEmpty {
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

    /// A series or an author whose books share one tile in the library.
    struct GroupRef: Hashable {
        enum Kind: Hashable { case series, author }
        let kind: Kind
        let key: String
        let name: String
    }

    /// What the library lists: single books, and tiles that stand for a
    /// series (two or more books) or an author (two or more books that aren't
    /// in a series).
    private enum Item: Identifiable {
        case book(Book)
        case group(GroupRef, [Book])
        var id: String {
            switch self {
            case .book(let b): return "b-" + b.id.uuidString
            case .group(let ref, _): return "\(ref.kind)-" + ref.key
            }
        }
        var sortName: String {
            switch self {
            case .book(let b): return b.title
            case .group(let ref, _): return ref.name
            }
        }
        var sortAuthor: String {
            switch self {
            case .book(let b): return b.author
            case .group(let ref, let books): return ref.kind == .author ? ref.name : (books.first?.author ?? "")
            }
        }
    }

    private static func groupKey(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).lowercased() }

    /// Gathers `list` (already filtered and sorted) into tiles. Each tile sits
    /// where its first book would; with Title or Author sort, tiles are placed
    /// by the series or author name instead.
    private func makeItems(_ list: [Book]) -> [Item] {
        var seriesCount: [String: Int] = [:]
        for b in list where !Self.groupKey(b.series).isEmpty { seriesCount[Self.groupKey(b.series), default: 0] += 1 }
        let inSeries = { (b: Book) in seriesCount[Self.groupKey(b.series), default: 0] >= 2 }
        var authorCount: [String: Int] = [:]
        for b in list where !inSeries(b) && !Self.groupKey(b.author).isEmpty { authorCount[Self.groupKey(b.author), default: 0] += 1 }

        func ref(_ b: Book) -> GroupRef? {
            if inSeries(b) {
                return GroupRef(kind: .series, key: Self.groupKey(b.series), name: b.series.trimmingCharacters(in: .whitespaces))
            }
            let a = Self.groupKey(b.author)
            if !a.isEmpty, authorCount[a, default: 0] >= 2 {
                return GroupRef(kind: .author, key: a, name: b.author.trimmingCharacters(in: .whitespaces))
            }
            return nil
        }

        var members: [String: [Book]] = [:]
        var order: [(GroupRef?, Book)] = []
        var seen = Set<String>()
        for b in list {
            guard let r = ref(b) else { order.append((nil, b)); continue }
            let id = "\(r.kind)-" + r.key
            members[id, default: []].append(b)
            if seen.insert(id).inserted { order.append((r, b)) }
        }
        var items: [Item] = order.map { r, b in
            guard let r else { return .book(b) }
            var books = members["\(r.kind)-" + r.key] ?? [b]
            if r.kind == .series {
                books.sort { ($0.seriesIndex ?? .infinity) != ($1.seriesIndex ?? .infinity)
                    ? ($0.seriesIndex ?? .infinity) < ($1.seriesIndex ?? .infinity)
                    : Importer.naturalLess($0.title, $1.title) }
            }
            return .group(r, books)
        }
        switch sort {
        case .title:
            items.sort { Importer.naturalLess($0.sortName, $1.sortName) }
        case .author:
            items.sort { a, b in
                let ka = a.sortAuthor.isEmpty ? "\u{FFFF}" : a.sortAuthor
                let kb = b.sortAuthor.isEmpty ? "\u{FFFF}" : b.sortAuthor
                if ka.localizedCaseInsensitiveCompare(kb) != .orderedSame { return Importer.naturalLess(ka, kb) }
                return Importer.naturalLess(a.sortName, b.sortName)
            }
        case .recent, .added:
            break
        }
        return items
    }

    private var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Search shows matching books on their own; otherwise books are gathered
    /// into series and author tiles (unless that's turned off in Settings).
    private var items: [Item] {
        guard readerSettings.groupSeries, !isSearching else { return visibleBooks.map { .book($0) } }
        return makeItems(visibleBooks)
    }

    /// The books behind a tile, with the current filters applied.
    private func books(in ref: GroupRef) -> [Book] {
        for item in makeItems(filteredBooks(searching: false)) {
            if case .group(let r, let books) = item, r.kind == ref.kind, r.key == ref.key { return books }
        }
        return []
    }

    private var showsReaderMini: Bool { reader.bookID != nil && (lastOpenedText || player.book == nil) }
    private var hasMini: Bool { showsReaderMini || player.book != nil }

    var body: some View {
        NavigationStack {
            miniInset(content)
                .navigationTitle("Lamplight")
                // The bar shows the app's mark and name between Settings and the
                // buttons on the right; the plain title stays for the back button.
                .navigationBarTitleDisplayMode(.inline)
                // The pills' frosting reaches up behind the bar once the shelf
                // scrolls, so the top reads as one band with no seam.
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                .toolbar { toolbar }
                .navigationDestination(for: GroupRef.self) { ref in miniInset(groupDetail(ref)) }
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
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        VStack(alignment: .leading, spacing: 24) {
                            shelf(items)
                            if visibleBooks.isEmpty {
                                Text(emptyMessage)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity).padding(.top, 24)
                            } else {
                                StorageFooter().foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, shelfMargin).padding(.top, 12).padding(.bottom, 24)
                    } header: {
                        // Stays at the top of the screen while the shelf scrolls under it.
                        shelfPills
                            .padding(.vertical, 8)
                            .background {
                                if pillsPinned {
                                    Rectangle().fill(.regularMaterial).padding(.top, -300)
                                }
                            }
                    }
                }
            }
            .background(Color(.systemBackground))
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in
                pillsPinned = y > 2
            }
            .searchable(text: $search, prompt: "Titles, authors, narrators, series")
        }
    }

    private var shelfMargin: CGFloat { sizeClass == .regular ? 24 : 16 }

    /// Covers on a shelf: books one slot wide, series and authors two.
    private func shelf(_ items: [Item]) -> some View {
        ShelfGrid(items: items.map { item in
            switch item {
            case .book(let b): return ShelfCell(id: "b-" + b.id.uuidString, span: 1) { w in AnyView(self.tile(b, width: w)) }
            case .group(let ref, let books):
                return ShelfCell(id: item.id, span: 2) { w in
                    AnyView(NavigationLink(value: ref) {
                        ShelfGroupTile(ref: ref, books: books, isCurrent: books.contains(where: self.isCurrent), slotWidth: w)
                    }
                    .buttonStyle(.plain))
                }
            }
        }, minSlot: sizeClass == .regular ? 140 : 100)
    }

    private func tile(_ book: Book, width: CGFloat, numbered: Bool = false) -> some View {
        ShelfBookTile(book: book, isCurrent: isCurrent(book), width: width,
                      number: numbered ? ShelfBookTile.number(book) : nil)
            .contentShape(Rectangle())
            .onTapGesture { open(book) }
            .contextMenu { menu(for: book) }
    }

    private func isCurrent(_ book: Book) -> Bool { player.bookID == book.id || reader.bookID == book.id }

    private var emptyMessage: String {
        if isSearching { return "No books match “\(search)”." }
        if filter.hasPrefix("shelf:") { return "Nothing on this shelf yet. Long-press a book and choose Shelves to add it." }
        return audioOnly ? "No audiobooks here." : "No books here."
    }

    /// The mini player, on a frosted strip that runs to the bottom of the
    /// screen (behind the search field too), so covers show through faintly.
    private func miniInset<V: View>(_ view: V) -> some View {
        view.safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if showsReaderMini {
                    ReaderMiniPlayer { showReader = true }
                } else if player.book != nil {
                    MiniPlayer { showPlayer = true }
                }
            }
            .padding(.top, hasMini ? 6 : 0)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, ignoresSafeAreaEdges: .bottom)
        }
    }

    /// A series or author opened from its tile: its books, with the
    /// library's filters still applied.
    private func groupDetail(_ ref: GroupRef) -> some View {
        let books = books(in: ref)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(ShelfGroupTile.summary(ref: ref, books: books).uppercased())
                    .font(.caption.weight(.medium)).kerning(0.6).foregroundStyle(.secondary)
                ShelfGrid(items: books.map { b in
                    ShelfCell(id: b.id.uuidString, span: 1) { w in AnyView(self.tile(b, width: w, numbered: ref.kind == .series)) }
                }, minSlot: sizeClass == .regular ? 140 : 100)
            }
            .padding(.horizontal, shelfMargin).padding(.bottom, 24)
        }
        .background(Color(.systemBackground))
        .overlay {
            if books.isEmpty { ContentUnavailableView("No books here", systemImage: "books.vertical") }
        }
        .navigationTitle(ref.name)
        .navigationBarTitleDisplayMode(.large)
    }

    private var shelfPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pill("All", "all")
                pill("In Progress", "listening")
                pill("Not Started", "new")
                ForEach(readerSettings.shelves, id: \.self) { pill($0, "shelf:" + $0) }
                pill("Read", "finished")
                Button { showShelves = true } label: {
                    Label("Edit shelves", systemImage: "pencil").font(.subheadline)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.secondary))
                }
                .tint(.primary)
            }
        }
        .contentMargins(.horizontal, shelfMargin, for: .scrollContent)
    }

    /// The app's mark (the lamp over the book, without the icon's tile) and its name.
    private var titleHeader: some View {
        HStack(alignment: .center, spacing: 7) {
            Image("LamplightMark")
                .resizable().scaledToFit()
                .frame(height: 26)
                .accessibilityHidden(true)
            Text("Lamplight")
                .font(.title3.weight(.bold))
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func pill(_ label: String, _ value: LibraryFilter) -> some View {
        let on = filter == value
        return Button { filter = value } label: {
            Text(label).font(.subheadline.weight(on ? .semibold : .regular))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(on ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
                .foregroundStyle(on ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Settings", systemImage: "gearshape") { showSettings = true }
        }
        ToolbarItem(placement: .principal) { titleHeader }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                audioOnly.toggle()
            } label: {
                Label(audioOnly ? "Showing Audiobooks Only" : "Show Audiobooks Only",
                      systemImage: audioOnly ? "headphones.circle.fill" : "headphones")
            }
            .accessibilityAddTraits(audioOnly ? .isSelected : [])
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
        if library.cover(for: book) != nil {
            if library.usesTitleCover(book) {
                Button("Use Page as Cover", systemImage: "doc.richtext") { library.mutate(book.id) { $0.titleCover = false } }
            } else {
                Button("Use Title Cover", systemImage: "character.book.closed") { library.mutate(book.id) { $0.titleCover = true } }
            }
        }
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
        if !book.finished {
            Button("Mark as Read", systemImage: "checkmark.circle") { markFinished(book) }
        }
        if book.hasBeenRead {
            Button("Mark as Unread", systemImage: "arrow.uturn.backward") { markUnread(book) }
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

    /// Clears the read mark. A book sitting at its end goes back to the start;
    /// one you're reading again keeps its place.
    private func markUnread(_ book: Book) {
        if book.finished {
            if book.isText {
                restart(book)
            } else {
                library.mutate(book.id) { $0.finished = false; $0.position = 0 }
                if player.bookID == book.id { player.jumpPaused(to: 0) }
            }
        }
        library.mutate(book.id) { $0.readAt = nil }
    }
}

/// One cell of the shelf: a book (one slot) or a series/author (two).
struct ShelfCell: Identifiable {
    let id: String
    let span: Int
    let view: (CGFloat) -> AnyView
}

/// Lays cells out in rows of equal slots, like a bookshelf. A two-slot cell
/// that doesn't fit at the end of a row waits for the next row while single
/// books fill the gap, so rows stay full and the order stays close.
struct ShelfGrid: View {
    let items: [ShelfCell]
    var minSlot: CGFloat = 100
    var spacing: CGFloat = 14
    @State private var width: CGFloat = 0

    private var columns: Int { max(3, Int((width + spacing) / (minSlot + spacing))) }
    private var slot: CGFloat { max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)) }

    private func rows() -> [[ShelfCell]] {
        let cols = columns
        var queue = items[...]
        var waiting: [ShelfCell] = []
        var rows: [[ShelfCell]] = []
        while !queue.isEmpty || !waiting.isEmpty {
            var row: [ShelfCell] = []
            var used = 0
            while let w = waiting.first, used + min(w.span, cols) <= cols {
                row.append(w); used += min(w.span, cols); waiting.removeFirst()
            }
            while used < cols, let next = queue.first {
                let span = min(next.span, cols)
                if used + span <= cols {
                    row.append(next); used += span; queue.removeFirst()
                } else if span > 1 {
                    waiting.append(next); queue.removeFirst()
                } else {
                    break
                }
            }
            if row.isEmpty { break }
            rows.append(row)
        }
        return rows
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 26) {
            if width > 0 {
                ForEach(Array(rows().enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(row) { cell in
                            let span = CGFloat(min(cell.span, columns))
                            cell.view(slot)
                                .frame(width: slot * span + spacing * (span - 1), alignment: .leading)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// Words for a book's place, like "67% Read" and "3 HOURS TO GO".
enum ShelfText {
    static func status(_ book: Book) -> String {
        switch book.status {
        case .finished: return "Read"
        case .notStarted: return "New"
        case .inProgress:
            let pct = Int((book.progress * 100).rounded(.down))
            if pct == 0 {
                if book.hasBeenRead { return book.isText ? "Reading Again" : "Listening Again" }
                return "Just Started"
            }
            return "\(pct)% " + (book.isText ? "Read" : "Listened")
        }
    }

    static func time(_ book: Book) -> String {
        let speed = book.isText ? max(0.1, UserDefaults.standard.object(forKey: "rd.speed") as? Double ?? 1) : max(0.1, book.speed)
        switch book.status {
        case .finished: return ""
        case .notStarted: return duration(book.totalTime / speed)
        case .inProgress: return duration(book.remaining / speed) + " to go"
        }
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(max(1, minutes)) min" }
        let hours = Int((seconds / 3600).rounded())
        return "\(hours) hour\(hours == 1 ? "" : "s")"
    }
}

/// A book on the shelf: the cover standing on the shelf line (tall for
/// ebooks, square for audiobooks), then how far along it is.
struct ShelfBookTile: View {
    let book: Book
    let isCurrent: Bool
    let width: CGFloat
    /// Its place in the series ("1", "2.5"), shown on a series' own screen.
    var number: String? = nil

    static func number(_ book: Book) -> String? {
        book.seriesIndex.map { $0.rounded() == $0 ? String(Int($0)) : String($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Color.clear
                .frame(width: width, height: width * 1.5)
                .overlay(alignment: .bottomLeading) {
                    CoverView(book: book, width: width, corner: 3)
                        .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
                        .overlay(alignment: .bottomTrailing) {
                            if !book.isText {
                                Image(systemName: BookKind.audiobookIcon)
                                    .font(.caption2.weight(.bold)).foregroundStyle(.white)
                                    .padding(5).background(.black.opacity(0.55), in: Circle()).padding(5)
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            if book.hasBeenRead {
                                Image(systemName: "checkmark")
                                    .font(.caption2.weight(.heavy)).foregroundStyle(.white)
                                    .padding(5).background(.green, in: Circle()).padding(5)
                                    .accessibilityHidden(true)
                            }
                        }
                        .overlay(alignment: .bottomLeading) {
                            if isCurrent {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.caption2.weight(.bold)).foregroundStyle(.white)
                                    .padding(5).background(Color.accentColor, in: Circle()).padding(5)
                                    .accessibilityHidden(true)
                            }
                        }
                }
            if let number {
                Text("BOOK \(number)")
                    .font(.caption2.weight(.bold)).kerning(0.6).foregroundStyle(.tint)
            }
            HStack(spacing: 4) {
                Text(ShelfText.status(book)).lineLimit(1)
            }
            .font(.subheadline)
            Text(ShelfText.time(book).uppercased())
                .font(.caption2.weight(.medium)).kerning(0.6)
                .foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((number.map { "Book \($0), " } ?? "") + book.title + (book.author.isEmpty ? "" : ", \(book.author)")
                            + ", \(ShelfText.status(book))" + (book.hasBeenRead && !book.finished ? ", read before" : ""))
    }
}

/// A series or author on the shelf, two slots wide: its covers overlapping,
/// the one you're reading in front, then the name and how many books.
struct ShelfGroupTile: View {
    let ref: LibraryView.GroupRef
    let books: [Book]
    let isCurrent: Bool
    let slotWidth: CGFloat

    static func summary(ref: LibraryView.GroupRef, books: [Book]) -> String {
        var parts = [ref.kind == .series ? "Series" : "Author", "\(books.count) books"]
        let reading = books.filter { $0.status == .inProgress }.count
        if reading > 0 { parts.append("\(reading) in progress") }
        let read = books.filter(\.hasBeenRead).count
        if read > 0 { parts.append(read == books.count ? "all read" : "\(read) read") }
        return parts.joined(separator: " · ")
    }

    /// One short line for the shelf: how much of it you've read once you've
    /// read any, otherwise how many books and how many you're in.
    static func shortSummary(ref: LibraryView.GroupRef, books: [Book]) -> String {
        let kind = ref.kind == .series ? "Series" : "Author"
        let read = books.filter(\.hasBeenRead).count
        if read > 0 { return "\(kind) · " + (read == books.count ? "all \(books.count) read" : "\(read) of \(books.count) read") }
        let reading = books.filter { $0.status == .inProgress }.count
        return "\(kind) · \(books.count) books" + (reading > 0 ? " · \(reading) in progress" : "")
    }

    private var shown: [Book] {
        let lead = books.filter { $0.status == .inProgress }.max { ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast) } ?? books.first
        guard let lead else { return [] }
        return Array(([lead] + books.filter { $0.id != lead.id }).prefix(3))
    }

    var body: some View {
        let total = slotWidth * 2 + 14
        let covers = shown
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .bottomLeading) {
                ForEach(Array(covers.enumerated()).reversed(), id: \.element.id) { i, book in
                    let w = slotWidth * [1.0, 0.92, 0.84][i]
                    let x = covers.count < 2 ? 0 : (total - w) * CGFloat(i) / CGFloat(max(covers.count - 1, 1)) * (covers.count == 2 ? 0.55 : 1)
                    CoverView(book: book, width: w, corner: 3)
                        .shadow(color: .black.opacity(0.22), radius: 3, x: -1, y: 2)
                        .offset(x: x)
                }
            }
            .frame(width: total, height: slotWidth * 1.5, alignment: .bottomLeading)
            HStack(spacing: 4) {
                if isCurrent { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint) }
                Text(ref.name).lineLimit(1)
            }
            .font(.subheadline)
            Text(Self.shortSummary(ref: ref, books: books).uppercased())
                .font(.caption2.weight(.medium)).kerning(0.6)
                .foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(ref.name), \(Self.summary(ref: ref, books: books))")
        .accessibilityAddTraits(.isButton)
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
