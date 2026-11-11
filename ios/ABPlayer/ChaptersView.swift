import SwiftUI

struct ChaptersView: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var editingNote: Bookmark?
    @State private var noteText = ""

    var body: some View {
        NavigationStack {
            Group {
                if let book = player.book {
                    if tab == 0 { chapters(book) } else { bookmarks(book) }
                }
            }
            .safeAreaInset(edge: .top) {
                Picker("View", selection: $tab) {
                    Text("Chapters").tag(0)
                    Text("Bookmarks").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.bottom, 8)
                .background(.bar)
            }
            .navigationTitle(player.book?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Bookmark Note", isPresented: Binding(get: { editingNote != nil }, set: { if !$0 { editingNote = nil } })) {
                TextField("Note", text: $noteText)
                Button("Save") { saveNote() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func chapters(_ book: Book) -> some View {
        let current = book.chapterIndex(at: player.currentTime)
        return ScrollViewReader { proxy in
            List {
                ForEach(Array(book.chapters.enumerated()), id: \.offset) { i, chapter in
                    let (start, end) = book.chapterBounds(i)
                    Button {
                        player.goToChapter(i)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chapter.title)
                                    .fontWeight(i == current ? .semibold : .regular)
                                    .foregroundStyle(i < current ? .secondary : .primary)
                                Text(Fmt.clock(start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if i == current {
                                Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill").foregroundStyle(.tint)
                            }
                            Text(Fmt.clock(end - start)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .tint(.primary)
                    .id(i)
                }
            }
            .listStyle(.plain)
            .onAppear { proxy.scrollTo(current, anchor: .center) }
        }
    }

    private func bookmarks(_ book: Book) -> some View {
        List {
            Section {
                Button("Add Bookmark at \(Fmt.clock(player.currentTime))", systemImage: "bookmark.fill") {
                    player.addBookmark()
                }
            }
            Section {
                ForEach(book.bookmarks.sorted { $0.time < $1.time }) { mark in
                    Button {
                        player.jump(to: mark.time)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(Fmt.clock(mark.time)).font(.headline.monospacedDigit())
                                Text(book.chapters[safe: book.chapterIndex(at: mark.time)]?.title ?? "")
                                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if !mark.note.isEmpty { Text(mark.note).font(.subheadline) }
                            Text(mark.created.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tint(.primary)
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            library.mutate(book.id) { $0.bookmarks.removeAll { $0.id == mark.id } }
                        }
                        Button("Note", systemImage: "square.and.pencil") {
                            noteText = mark.note
                            editingNote = mark
                        }
                    }
                }
            } footer: {
                if book.bookmarks.isEmpty {
                    Text("Tap the bookmark button while listening to save a spot. Swipe a bookmark to add a note or delete it.")
                }
            }
        }
    }

    private func saveNote() {
        guard let mark = editingNote, let id = player.bookID else { return }
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        library.mutate(id) { book in
            if let i = book.bookmarks.firstIndex(where: { $0.id == mark.id }) { book.bookmarks[i].note = text }
        }
        editingNote = nil
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
