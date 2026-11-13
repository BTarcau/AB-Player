import Foundation
import Observation
import Security

// MARK: - The cast of a book

enum CastGender: String, Codable { case male, female, unknown }

struct CastCharacter: Codable, Hashable, Identifiable {
    var name: String
    var aliases: [String] = []
    var gender: CastGender = .unknown
    var lines = 0
    /// Kokoro voice id; nil reads this character in the narrator's voice.
    var voice: String?
    var id: String { name }
}

/// Who speaks each paragraph of a book, and the voice for each character.
/// Saved as cast.json in the book's folder.
struct BookCast: Codable {
    var characters: [CastCharacter]
    /// Per chapter, per paragraph: index into `characters`, or -1 for narration.
    var speakers: [[Int]]
    /// Per chapter, per paragraph: dialogue the rules weren't sure of (Claude hasn't checked it).
    var uncertain: [[Bool]]
    var enabled = true
    /// Lines Claude checked, and what it cost.
    var claudeLines = 0
    var claudeCost = 0.0
    var claudeChecked = false

    var uncertainCount: Int { uncertain.reduce(0) { $0 + $1.filter { $0 }.count } }
    var dialogueCount: Int { speakers.reduce(0) { $0 + $1.filter { $0 >= 0 }.count } }

    func fits(_ chapters: [TextChapter]) -> Bool {
        speakers.count == chapters.count && zip(speakers, chapters).allSatisfy { $0.count == $1.paragraphStarts.count }
    }

    /// Counts each character's lines again, drops anyone left with none, and
    /// lists the busiest first.
    mutating func recount() {
        var counts = [Int](repeating: 0, count: characters.count)
        for row in speakers { for s in row where counts.indices.contains(s) { counts[s] += 1 } }
        let keep = characters.indices.filter { counts[$0] > 0 }.sorted { counts[$0] != counts[$1] ? counts[$0] > counts[$1] : $0 < $1 }
        let newIndex = Dictionary(uniqueKeysWithValues: keep.enumerated().map { ($1, $0) })
        characters = keep.map { var c = characters[$0]; c.lines = counts[$0]; return c }
        speakers = speakers.map { $0.map { newIndex[$0] ?? -1 } }
    }
}

// MARK: - Voices for characters

enum CastVoices {
    /// Kokoro voices to hand out, the clearest and most different first.
    static let male = ["am_michael", "bm_george", "am_adam", "bm_daniel", "am_eric", "bm_lewis", "am_liam", "am_onyx",
                       "bm_fable", "am_fenrir", "am_echo", "am_puck"]
    static let female = ["af_heart", "bf_emma", "af_bella", "af_sarah", "bf_isabella", "af_nicole", "af_jessica", "bf_alice",
                         "af_kore", "af_nova", "af_aoede", "bf_lily", "af_river", "af_sky", "af_alloy"]

    private static let femaleWords: Set<String> = ["woman", "girl", "lady", "mother", "wife", "sister", "daughter", "aunt",
        "grandmother", "nun", "queen", "princess", "waitress", "actress", "stewardess", "widow", "bride", "mom", "nurse"]

    /// Gender when the book didn't make it clear: from a role ("the woman"),
    /// or a first name's ending ("Rhoda", "Jackie"); otherwise male.
    static func guess(_ c: CastCharacter) -> CastGender {
        if c.gender != .unknown { return c.gender }
        let words = c.name.lowercased().split(separator: " ").map(String.init)
        if words.contains(where: femaleWords.contains) { return .female }
        if c.name.hasPrefix("The ") { return .male }
        let n = c.name.lowercased()
        if ["a", "ie", "ine", "elle", "ette", "een", "lyn", "beth", "ah"].contains(where: { n.hasSuffix($0) }) { return .female }
        return .male
    }

    /// A different voice for each character, by gender, the busiest first,
    /// skipping the narrator's own Kokoro voice. Voices go round again after a dozen.
    static func assign(_ characters: inout [CastCharacter], narrator: String?) {
        var used = Set(characters.compactMap(\.voice))
        if let narrator { used.insert(narrator) }
        var m = male.filter { !used.contains($0) }.makeIterator()
        var f = female.filter { !used.contains($0) }.makeIterator()
        var mi = 0, fi = 0
        for i in characters.indices where characters[i].voice == nil {
            if guess(characters[i]) == .female {
                characters[i].voice = f.next() ?? Self.female[fi % Self.female.count]; fi += 1
            } else {
                characters[i].voice = m.next() ?? Self.male[mi % Self.male.count]; mi += 1
            }
        }
    }
}

// MARK: - The store

/// Finds a book's characters (on the phone), asks Claude about the lines the
/// rules aren't sure of (only when asked), and keeps the voice choices.
@MainActor @Observable
final class CastStore {
    static let shared = CastStore()

    private(set) var bookID: UUID?
    private(set) var cast: BookCast?
    /// What it's doing, for the sheet ("Finding characters…", "Asking Claude… 3 of 12").
    private(set) var busy: String?
    var message: String?

    @ObservationIgnored private var library: Library?
    /// Called when a book's voices change, so the reader can remake its clips.
    @ObservationIgnored var changed: ((UUID) -> Void)?

    func configure(library: Library) { self.library = library }

    private func url(_ id: UUID) -> URL? {
        guard let library, let book = library.book(id) else { return nil }
        return library.folder(for: book).appendingPathComponent("cast.json")
    }

    /// The saved cast for a book, if it's been worked out and still fits its text.
    func load(_ id: UUID, chapters: [TextChapter]? = nil) {
        guard bookID != id || cast == nil else { return }
        bookID = id
        cast = url(id).flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(BookCast.self, from: $0) }
        if let chapters, let c = cast, !c.fits(chapters) { cast = nil }
        cast?.recount()
    }

    private func save(_ id: UUID) {
        guard let url = url(id), let cast else { return }
        try? JSONEncoder().encode(cast).write(to: url, options: .atomic)
        changed?(id)
    }

    func hasCast(_ id: UUID) -> Bool {
        if bookID == id { return cast != nil }
        return url(id).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    // MARK: Finding characters (rules, on the phone)

    func findCharacters(_ book: Book) async {
        guard let library, busy == nil else { return }
        busy = "Finding characters…"
        defer { busy = nil }
        do {
            let chapters = try await library.parsedText(for: book).chapters
            let result = await Task.detached(priority: .userInitiated) { SpeakerRules.analyze(chapters) }.value
            var characters = result.characters
            let settings = ReaderSettings.shared
            CastVoices.assign(&characters, narrator: settings.source == .kokoro ? settings.kokoroVoice : nil)
            bookID = book.id
            cast = BookCast(characters: characters, speakers: result.speakers, uncertain: result.uncertain)
            save(book.id)
        } catch {
            message = "Couldn't read the book: \(error.localizedDescription)"
        }
    }

    func setEnabled(_ on: Bool) {
        guard let id = bookID, cast != nil else { return }
        cast?.enabled = on
        save(id)
    }

    func setVoice(_ character: String, _ voice: String?) {
        guard let id = bookID, let i = cast?.characters.firstIndex(where: { $0.name == character }) else { return }
        cast?.characters[i].voice = voice
        save(id)
    }

    func remove(_ id: UUID) {
        if let url = url(id) { try? FileManager.default.removeItem(at: url) }
        if bookID == id { cast = nil }
        changed?(id)
    }

    // MARK: For the reader

    /// The voice for each sentence: a Kokoro voice id for a character's line,
    /// nil for the narrator. Empty when character voices are off.
    func sentenceVoices(_ id: UUID, chapters: [TextChapter]) -> [[String?]] {
        load(id, chapters: chapters)
        guard bookID == id, let cast, cast.enabled, cast.fits(chapters), KokoroEngine.unavailableReason == nil else { return [] }
        return chapters.enumerated().map { ci, chapter in
            var out = [String?](repeating: nil, count: chapter.sentences.count)
            for p in chapter.paragraphStarts.indices {
                let who = cast.speakers[ci][p]
                guard cast.characters.indices.contains(who), let voice = cast.characters[who].voice else { continue }
                // Only the sentences with speech in them; narration around the
                // quote stays with the narrator unless it's in the same sentence.
                var inQuote = false
                for s in chapter.paragraphRange(p) {
                    let t = chapter.sentences[s]
                    var speech = inQuote
                    for ch in t {
                        if ch == "\u{201C}" { inQuote = true; speech = true }
                        else if ch == "\u{201D}" { inQuote = false }
                        else if ch == "\"" { inQuote.toggle(); speech = true }
                    }
                    if speech { out[s] = voice }
                }
            }
            return out
        }
    }

    // MARK: Asking Claude (only when asked)

    /// Scenes that have a line the rules weren't sure of, as numbered paragraphs.
    private func scenesToCheck(_ cast: BookCast, _ chapters: [TextChapter]) -> [(text: String, ids: [String])] {
        var out: [(String, [String])] = []
        for (ci, chapter) in chapters.enumerated() {
            let paras = chapter.paragraphStarts.indices.map { p in chapter.paragraphRange(p).map { chapter.sentences[$0] }.joined(separator: " ") }
            var scene: [Int] = []
            func flush() {
                let ids = scene.filter { cast.uncertain[ci][$0] }
                if !ids.isEmpty {
                    let text = scene.map { "[\(ci).\($0)] \(paras[$0])" }.joined(separator: "\n")
                    out.append((text, ids.map { "\(ci).\($0)" }))
                }
                scene = []
            }
            for (p, t) in paras.enumerated() {
                let s = t.trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("* * *") || s.hasPrefix("***") || (s.count < 40 && s.range(of: "[.!?\u{201D}\"]$", options: .regularExpression) == nil) {
                    flush()
                } else {
                    scene.append(p)
                }
            }
            flush()
        }
        return out
    }

    /// What asking Claude would send: scenes, and roughly what share of the book.
    func claudePlan(_ book: Book) async -> (scenes: Int, lines: Int, share: Double, cost: Double)? {
        guard let library, let cast, bookID == book.id,
              let chapters = try? await library.parsedText(for: book).chapters, cast.fits(chapters) else { return nil }
        let scenes = scenesToCheck(cast, chapters)
        let chars = scenes.reduce(0) { $0 + $1.text.count }
        let total = max(1, chapters.reduce(0) { $0 + $1.charCount })
        // Calibrated on In His Image: 1,241 lines checked for 5.8 cents, most of
        // it Claude's thinking before each answer.
        let inTokens = Double(chars) / 3.5 + Double(chars / 40_000 + 1) * 1_500
        let outTokens = Double(cast.uncertainCount) * 80
        return (scenes.count, cast.uncertainCount, Double(chars) / Double(total), (inTokens * 0.10 + outTokens * 0.50) / 1_000_000)
    }

    func askClaude(_ book: Book) async {
        guard let library, busy == nil, var cast, bookID == book.id else { return }
        guard let key = APIKey.load() else { message = "Add your Anthropic API key first."; return }
        busy = "Getting the scenes ready…"
        defer { busy = nil }
        guard let chapters = try? await library.parsedText(for: book).chapters, cast.fits(chapters) else {
            message = "The book's text has changed; find the characters again."
            return
        }
        // A few scenes to a request, so each stays small.
        var batches: [[(text: String, ids: [String])]] = [[]]
        var size = 0
        for s in scenesToCheck(cast, chapters) {
            if size + s.text.count > 40_000, !batches[batches.count - 1].isEmpty { batches.append([]); size = 0 }
            batches[batches.count - 1].append(s); size += s.text.count
        }
        batches.removeAll { $0.isEmpty }
        guard !batches.isEmpty else { message = "There are no lines left to check."; return }

        let castList = cast.characters.map { c in
            let g = c.gender == .male ? "male" : c.gender == .female ? "female" : "unknown"
            return "- \(c.name)" + (c.aliases.isEmpty ? "" : " (also \(c.aliases.joined(separator: ", ")))") + ", \(g)"
        }.joined(separator: "\n")

        var answers: [String: String] = [:]
        var genders: [String: String] = [:]
        var inTok = 0, outTok = 0, done = 0, failed = 0
        var lastError: String?
        busy = "Asking Claude… 0 of \(batches.count)"
        await withTaskGroup(of: Result<ClaudeSpeakers.Reply, Error>.self) { group in
            var next = 0
            while next < min(3, batches.count) {
                let batch = batches[next]; next += 1
                group.addTask { await ClaudeSpeakers.result(key: key, cast: castList, scenes: batch) }
            }
            for await r in group {
                done += 1
                switch r {
                case .success(let reply):
                    answers.merge(reply.speakers) { a, _ in a }
                    genders.merge(reply.genders) { a, _ in a }
                    inTok += reply.inputTokens; outTok += reply.outputTokens
                case .failure(let e):
                    failed += 1; lastError = e.localizedDescription
                }
                busy = "Asking Claude… \(done) of \(batches.count)"
                if next < batches.count {
                    let batch = batches[next]; next += 1
                    group.addTask { await ClaudeSpeakers.result(key: key, cast: castList, scenes: batch) }
                }
            }
        }

        // Fold the answers in: known names to their character, new ones added.
        func norm(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: "^(the|mr\\.?|mrs\\.?|ms\\.?|dr\\.?) ", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        var lookup: [String: Int] = [:]
        for (i, c) in cast.characters.enumerated() {
            lookup[norm(c.name)] = i
            for a in c.aliases { lookup[norm(a)] = lookup[norm(a)] ?? i }
        }
        var changedLines = 0
        for (id, raw) in answers {
            let parts = id.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 2, cast.speakers.indices.contains(parts[0]), cast.speakers[parts[0]].indices.contains(parts[1]) else { continue }
            let (c, p) = (parts[0], parts[1])
            let name = raw.trimmingCharacters(in: .whitespaces)
            var who = -1
            if norm(name) != "narrator" {
                if let i = lookup[norm(name)] ?? lookup.first(where: { norm(name).split(separator: " ").contains(Substring($0.key)) })?.value {
                    who = i
                } else {
                    cast.characters.append(CastCharacter(name: name))
                    who = cast.characters.count - 1
                    lookup[norm(name)] = who
                }
            }
            if cast.speakers[c][p] != who { changedLines += 1 }
            cast.speakers[c][p] = who
            cast.uncertain[c][p] = false
        }
        for i in cast.characters.indices where cast.characters[i].gender == .unknown {
            switch genders[norm(cast.characters[i].name)] {
            case "male": cast.characters[i].gender = .male
            case "female": cast.characters[i].gender = .female
            default: break
            }
        }
        cast.recount()
        let settings = ReaderSettings.shared
        CastVoices.assign(&cast.characters, narrator: settings.source == .kokoro ? settings.kokoroVoice : nil)
        let cost = (Double(inTok) * 0.10 + Double(outTok) * 0.50) / 1_000_000
        cast.claudeLines += answers.count
        cast.claudeCost += cost
        cast.claudeChecked = failed == 0
        self.cast = cast
        save(book.id)
        if failed > 0 {
            message = "Claude checked \(answers.count) lines; \(failed) of \(batches.count) requests failed (\(lastError ?? "")). Try again to finish."
        } else {
            message = "Claude checked \(answers.count) lines and changed \(changedLines). Cost about \(Self.money(cost))."
        }
    }

    static func money(_ v: Double) -> String { v < 0.01 ? "under 1¢" : String(format: "$%.2f", v) }
}

// MARK: - Claude Haiku

/// One request to Claude Haiku: numbered scenes in, a speaker for each asked-about line out.
enum ClaudeSpeakers {
    struct Reply { var speakers: [String: String]; var genders: [String: String] = [:]; var inputTokens: Int; var outputTokens: Int }

    enum Failure: LocalizedError {
        case http(Int, String), refused, unreadable
        var errorDescription: String? {
            switch self {
            case .http(401, _): return "the API key wasn't accepted"
            case .http(let code, let msg): return "error \(code)\(msg.isEmpty ? "" : ": \(msg)")"
            case .refused: return "Claude declined this part"
            case .unreadable: return "Claude's answer couldn't be read"
            }
        }
    }

    static let model = "claude-haiku-5-5"

    private static let system = """
        You identify who speaks each line of dialogue in a novel. You get some scenes, each paragraph \
        prefixed with an id in brackets like [12.40], the book's cast as found so far, and a list of ids to answer. \
        For each listed id, give who speaks the quoted words in that paragraph. Use a cast name exactly as written \
        when it is one of them. Otherwise use the name the book gives the speaker, or a short description such as \
        "unnamed secretary" when the book never names them. Answer "Narrator" when the quotation marks are not \
        speech (a title, a quoted phrase, a scare quote). If a paragraph has speech from more than one person, give \
        the main speaker. Read the surrounding paragraphs: speech often continues across paragraphs, and people \
        are often named only before or after the line. Also, for every speaker you name who is not in the cast \
        or whose gender is unknown there, say whether they are male or female, if the text shows it.
        """

    static func result(key: String, cast: String, scenes: [(text: String, ids: [String])]) async -> Result<Reply, Error> {
        do { return .success(try await ask(key: key, cast: cast, scenes: scenes)) } catch { return .failure(error) }
    }

    static func ask(key: String, cast: String, scenes: [(text: String, ids: [String])]) async throws -> Reply {
        let ids = scenes.flatMap(\.ids)
        let user = "Cast:\n\(cast)\n\nScenes:\n\n" + scenes.map(\.text).joined(separator: "\n\n---\n\n")
            + "\n\nAnswer these ids: " + ids.joined(separator: ", ")
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["lines", "genders"],
            "properties": [
                "lines": [
                    "type": "array",
                    "items": ["type": "object", "additionalProperties": false, "required": ["id", "speaker"],
                              "properties": ["id": ["type": "string"], "speaker": ["type": "string"]]],
                ],
                "genders": [
                    "type": "array",
                    "items": ["type": "object", "additionalProperties": false, "required": ["name", "gender"],
                              "properties": ["name": ["type": "string"], "gender": ["type": "string", "enum": ["male", "female", "unknown"]]]],
                ],
            ],
        ]
        let body: [String: Any] = [
            "model": model, "max_tokens": 16000, "system": system,
            "output_config": ["effort": "medium", "format": ["type": "json_schema", "schema": schema]],
            "messages": [["role": "user", "content": user]],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        var attempt = 0
        while true {
            attempt += 1
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (code == 429 || code >= 500) && attempt < 3 {
                try await Task.sleep(for: .seconds(Double(attempt) * 5))
                continue
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard code == 200, let json else {
                let msg = ((json?["error"] as? [String: Any])?["message"] as? String) ?? ""
                throw Failure.http(code, msg)
            }
            if json["stop_reason"] as? String == "refusal" { throw Failure.refused }
            let usage = json["usage"] as? [String: Any]
            let text = (json["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined()
            guard let parsed = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  let lines = parsed["lines"] as? [[String: Any]] else { throw Failure.unreadable }
            var speakers: [String: String] = [:]
            let wanted = Set(ids)
            for l in lines {
                if let id = l["id"] as? String, let s = l["speaker"] as? String, wanted.contains(id) { speakers[id] = s }
            }
            var genders: [String: String] = [:]
            for g in parsed["genders"] as? [[String: Any]] ?? [] {
                if let n = g["name"] as? String, let v = g["gender"] as? String {
                    genders[n.lowercased().replacingOccurrences(of: "^(the|mr\\.?|mrs\\.?|ms\\.?|dr\\.?) ", with: "", options: .regularExpression)] = v
                }
            }
            return Reply(speakers: speakers, genders: genders, inputTokens: usage?["input_tokens"] as? Int ?? 0,
                         outputTokens: usage?["output_tokens"] as? Int ?? 0)
        }
    }
}

// MARK: - The API key, in the Keychain

enum APIKey {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.bentarcau.lamplight.anthropic",
        kSecAttrAccount as String: "api-key",
    ]

    static func load() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        let key = String(decoding: data, as: UTF8.self)
        return key.isEmpty ? nil : key
    }

    static func save(_ key: String) {
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func remove() { SecItemDelete(query as CFDictionary) }
}
