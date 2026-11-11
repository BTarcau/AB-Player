import AVKit
import SwiftUI

/// The book's cover, or a coloured tile with its initials.
struct CoverView: View {
    @Environment(Library.self) private var library
    let book: Book
    var size: CGFloat? = nil
    var corner: CGFloat = 8

    var body: some View {
        Group {
            if let image = library.cover(for: book) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                let hue = Self.hue(book.title)
                LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.55),
                                        Color(hue: (hue + 0.11).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.32)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay {
                        GeometryReader { geo in
                            Text(Self.initials(book.title))
                                .font(.system(size: geo.size.width * 0.32, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.9))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
            }
        }
        .frame(width: size, height: size)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .accessibilityHidden(true)
    }

    static func hue(_ s: String) -> Double {
        var h = 0
        for scalar in s.unicodeScalars { h = (h * 31 + Int(scalar.value)) % 360 }
        return Double(h) / 360
    }

    static func initials(_ title: String) -> String {
        let words = title.split { !$0.isLetter && !$0.isNumber }
        let s = words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return s.isEmpty ? "♪" : s
    }
}

/// AirPlay / Bluetooth output picker.
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .secondaryLabel
        view.activeTintColor = UIColor(named: "AccentColor")
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

/// The kind line under a book's title: what it is, then where you are in it.
/// "Audiobook · 42% · 3h 10m left" / "Ebook · EPUB · ≈4h 17m · 23 chapters".
func bookSubtitle(_ book: Book) -> String {
    var parts: [String]
    if let t = book.text {
        let speed = max(0.1, UserDefaults.standard.object(forKey: "rd.speed") as? Double ?? 1)
        switch book.status {
        case .finished:
            parts = ["Ebook", "Finished"]
        case .notStarted:
            let n = t.chapterTitles.count
            parts = ["Ebook", t.format.uppercased(), "≈" + Fmt.long(book.totalTime / speed), "\(n) chapter\(n == 1 ? "" : "s")"]
        case .inProgress:
            parts = ["Ebook", "\(Int(book.progress * 100))%", "≈\(Fmt.long(book.remaining / speed)) left"]
        }
    } else {
        switch book.status {
        case .finished:
            parts = ["Audiobook", "Finished"]
        case .notStarted:
            let n = book.chapters.count
            parts = ["Audiobook", Fmt.long(book.duration), "\(n) chapter\(n == 1 ? "" : "s")"]
        case .inProgress:
            parts = ["Audiobook", "\(Int(book.progress * 100))%", "\(Fmt.long(book.remaining / book.speed)) left"]
        }
    }
    if book.link != nil { parts.append("Linked") }
    return parts.joined(separator: " · ")
}

/// The one icon pair used for the two kinds everywhere in the app.
enum BookKind {
    static func icon(_ book: Book) -> String { book.isText ? ebookIcon : audiobookIcon }
    static let audiobookIcon = "headphones"
    static let ebookIcon = "text.book.closed"
}

/// Bottom-of-screen message that clears itself.
struct ToastOverlay: View {
    @Environment(Library.self) private var library

    var body: some View {
        if let message = library.message {
            Text(message)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
                .padding(.horizontal, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(3.5))
                    withAnimation { library.message = nil }
                }
                .onTapGesture { withAnimation { library.message = nil } }
        }
    }
}

struct ImportOverlay: View {
    @Environment(Library.self) private var library

    var body: some View {
        if let status = library.importStatus {
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text(status).multilineTextAlignment(.center).font(.subheadline)
                }
                .padding(24)
                .frame(maxWidth: 300)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }
}

/// The book being read aloud, at the bottom of the library.
struct ReaderMiniPlayer: View {
    @Environment(ReaderPlayer.self) private var reader
    var open: () -> Void

    var body: some View {
        if let book = reader.book {
            let info = reader.positionInfo
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    CoverView(book: book, size: 44, corner: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reader.chapter?.title ?? book.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(book.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button { reader.previous() } label: { Image(systemName: "arrow.counterclockwise").font(.title3.weight(.semibold)) }
                        .accessibilityLabel("Previous \(ReaderSettings.shared.skipUnit.rawValue)")
                    Button { reader.togglePlay() } label: {
                        Group {
                            if reader.state == .preparing { ProgressView() }
                            else { Image(systemName: reader.state == .idle ? "play.fill" : "pause.fill").font(.title2) }
                        }
                        .frame(width: 36, height: 36)
                    }
                    .accessibilityLabel(reader.state == .idle ? "Play" : "Pause")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 10)
                ProgressView(value: info.chapterTotal > 0 ? min(1, info.chapterElapsed / info.chapterTotal) : 0)
                    .progressViewStyle(.linear).scaleEffect(y: 0.6)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 10).padding(.bottom, 4)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .accessibilityAction(named: "Open reader", open)
        }
    }
}

/// Add and remove shelves (genres). A book can sit on several.
struct ShelvesSheet: View {
    @Environment(ReaderSettings.self) private var settings
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var newShelf = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(settings.shelves, id: \.self) { shelf in
                        let n = library.books.filter { $0.shelves.contains(shelf) }.count
                        VStack(alignment: .leading) {
                            Text(shelf)
                            Text("\(n) book\(n == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets {
                            let shelf = settings.shelves[i]
                            for b in library.books where b.shelves.contains(shelf) {
                                library.mutate(b.id) { $0.shelves.removeAll { $0 == shelf } }
                            }
                        }
                        settings.shelves.remove(atOffsets: offsets)
                    }
                    .onMove { settings.shelves.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    Text("A book can sit on several shelves. \"Finished\" fills itself when a book reaches the end.")
                }
                Section("Add a shelf") {
                    HStack {
                        TextField("New shelf, e.g. History", text: $newShelf).onSubmit(add)
                        Button("Add", action: add).disabled(newShelf.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle("Shelves")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func add() {
        let name = newShelf.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !settings.shelves.contains(name) else { return }
        settings.shelves.append(name)
        newShelf = ""
    }
}
