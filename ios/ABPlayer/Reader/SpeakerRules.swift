import Foundation

/// Works out who speaks each paragraph of dialogue in a book, with text rules
/// only (no AI, nothing leaves the phone): speech tags ("said Hansen"), action
/// beats, who is addressed, who's in the scene, and the best-fitting sequence
/// of speakers for each scene as a whole, so a named line later on can correct
/// the guesses before it. About 90% right on the test chapters; the lines it
/// isn't sure of are marked so Claude can be asked about them.
enum SpeakerRules {
    struct Result {
        var characters: [CastCharacter]
        /// Per chapter, per paragraph: index into `characters`, or -1 for narration.
        var speakers: [[Int]]
        /// Per chapter, per paragraph: true for dialogue the rules aren't sure of.
        var uncertain: [[Bool]]
    }

    // MARK: Text helpers

    private static func re(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: o)
    }

    private struct Match {
        let groups: [String?]
        let range: NSRange
        subscript(_ i: Int) -> String? { groups.indices.contains(i) ? groups[i] : nil }
    }

    private static func all(_ r: NSRegularExpression, _ s: String) -> [Match] {
        let ns = s as NSString
        return r.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            Match(groups: (0..<m.numberOfRanges).map { i in
                let g = m.range(at: i)
                return g.location == NSNotFound ? nil : ns.substring(with: g)
            }, range: m.range)
        }
    }

    private static func first(_ r: NSRegularExpression, _ s: String) -> Match? {
        let ns = s as NSString
        guard let m = r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Match(groups: (0..<m.numberOfRanges).map { i in
            let g = m.range(at: i)
            return g.location == NSNotFound ? nil : ns.substring(with: g)
        }, range: m.range)
    }

    private static func has(_ r: NSRegularExpression, _ s: String) -> Bool { first(r, s) != nil }

    private static let verbs: Set<String> = Set("""
        said asked replied answered added explained interrupted continued whispered shouted cried called told \
        admitted agreed offered urged responded countered groaned growled advised directed volunteered contradicted asserted \
        concluded began mumbled pled pleaded affirmed interjected erupted allowed winced insisted demanded announced muttered \
        yelled screamed laughed sighed suggested observed noted remarked repeated warned wondered stated declared conceded \
        confirmed corrected protested objected joked teased snapped barked murmured breathed gasped exclaimed \
        inquired queried probed pressed prompted ventured guessed commented acknowledged assured promised returned \
        retorted mused reasoned recalled reminded finished started went says asks replies sobbed roared chuckled grumbled
        """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    private static let stop: Set<String> = Set("""
        The A An He She It They We I You His Her Their Our My Your This That These Those There Then When What \
        Who Why How Where But And Or So If As At In On Of For With From By To Not No Yes Oh Well Now Just Mr Mrs Ms Dr \
        Professor Colonel Ambassador Sir General President Captain Father Mother God Lord Jesus Christ Chapter Monday Tuesday \
        Wednesday Thursday Friday Saturday Sunday January February March April May June July August September October \
        November December UN US Okay OK Hey Hi Hello Thanks Thank Please Even After Before Still Only Maybe Perhaps \
        Meanwhile Although Though Because While Once Inside Outside Later Soon Again Also Both Each Every Most Some Many
        """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    private static let cap = "[A-Z][a-z]+(?:[-'][A-Z]?[a-z]+)?"
    private static let notRoles: Set<String> = ["as", "on", "with", "one", "other", "others", "arrival", "in", "at", "of", "to", "for",
        "from", "by", "and", "or", "but", "that", "this", "same", "next", "last", "first", "rest", "two", "three", "news", "door",
        "phone", "words", "voice", "room", "time", "way", "end", "line", "call", "question", "answer", "silence", "crowd"]

    /// A paragraph as narration and speech, in order. An opening quote with no
    /// closing one runs to the end (the speech carries on into the next paragraph).
    private static func split(_ t: String) -> [(speech: Bool, text: String)] {
        var out: [(Bool, String)] = []
        var inq = false, buf = ""
        for ch in t {
            if (ch == "\u{201C}" || (ch == "\"" && !inq)) && !inq {
                if !buf.isEmpty { out.append((false, buf)) }
                buf = ""; inq = true
            } else if (ch == "\u{201D}" || ch == "\"") && inq {
                out.append((true, buf)); buf = ""; inq = false
            } else {
                buf.append(ch)
            }
        }
        if !buf.isEmpty { out.append((inq, buf)) }
        return out
    }

    private static let speechEndRE = re("[,.?!\u{2014}-]\\s*$")

    /// Real speech, not a scare quote: a quote that starts the paragraph, or ends like speech.
    private static func isDialogue(_ segs: [(speech: Bool, text: String)]) -> Bool {
        for (i, s) in segs.enumerated() where s.speech {
            if i == 0 || has(speechEndRE, s.text) { return true }
        }
        return false
    }

    /// True when the paragraph's last quote is never closed: the speech goes on in the next one.
    private static func endsOpen(_ t: String) -> Bool { split(t).last?.speech == true && !t.hasSuffix("\u{201D}") && !t.hasSuffix("\"") }

    // MARK: Speech tags

    private static let afterRE = re("^,?\\s*(?:(the (?:[A-Za-z]+ ){0,2}[a-z]+)|(\(cap)(?: \(cap))?)|([Hh]e|[Ss]he))\\s+(?:[a-z]+ly\\s+)?([a-z]+)\\b")
    private static let afterRoleNameRE = re("^,?\\s*(?:[a-z]+ ){0,2}[a-z]+ (?:[A-Z][a-z]*\\.? )?(\(cap)(?: \(cap))?)\\s+(?:[a-z]+ly\\s+)?([a-z]+)\\b")
    private static let invertedRE = re("^,?\\s*([a-z]+)\\s+(?:[a-z]+ly\\s+)?(the [A-Za-z]+(?:'s)?(?: [a-z]+)?|\(cap)(?: \(cap))?)\\b")
    private static let beforeRE = re("(?:^|[.!?]\\s+)(?:Then\\s+)?(\(cap)(?: \(cap))?|[Hh]e|[Ss]he)\\s+(?:[a-z]+ly\\s+)?([a-z]+)\\b[^.!?]*[,:]\\s*$")

    /// Subjects of speech tags in a stretch of narration next to a quote.
    private static func tagSubjects(_ narr: String, after: Bool, before: Bool) -> [String] {
        let n = narr.trimmingCharacters(in: .whitespaces)
        if after {
            if let m = first(afterRE, n), let v = m[4], verbs.contains(v) {
                if let s = m[1] ?? m[2] { return [s] }
                if let s = m[3] { return [s.lowercased()] }
            }
            if let m = first(afterRoleNameRE, n), let v = m[2], verbs.contains(v), let s = m[1] { return [s] }
            if let m = first(invertedRE, n), let v = m[1], verbs.contains(v), let s = m[2] { return [s] }
        }
        if before, let m = first(beforeRE, n), let v = m[2], verbs.contains(v), let s = m[1] {
            return [s == "He" || s == "She" ? s.lowercased() : s]
        }
        return []
    }

    private static func tags(_ segs: [(speech: Bool, text: String)]) -> [String] {
        var res: [String] = []
        for (i, s) in segs.enumerated() where !s.speech {
            let after = i > 0 && segs[i - 1].speech
            let before = i + 1 < segs.count && segs[i + 1].speech
            if after || before { res += tagSubjects(s.text, after: after, before: before) }
        }
        return res
    }

    // MARK: Who the characters are

    private static let bigramRE = re("\\b(\(cap)) (\(cap))\\b")
    private static let titleRE = re("^(?:[A-Z][a-z]+-[A-Z][a-z]+|Ambassador|Secretary|General|Director|Minister|President|Inspector|Professor|Doctor|Senator|Governor|Judge|Agent|Officer|Lt|Sergeant|Prime|Chief|Bishop|Cardinal|Pope|Rabbi|King|Queen|Prince|Princess|Lady|Lord|Saint|St)$")
    private static let participleRE = re("(ly|ing|ed)$")
    private static let wordRE = re("[A-Za-z']+")
    private static let sentenceSplitRE = re("(?<=[.!?])\\s+")
    private static let heShe = re("^(He|She)\\b")
    private static let titleNameRE = re("\\b(Mr|Mrs|Ms|Miss)\\.? (\(cap))")
    private static let fem = "daughter|daughters|wife|mother|sister|aunt|niece|granddaughter|girlfriend|grandmother|widow|bride|girl|girls|woman|lady|mom|actress|grandniece"
    private static let masc = "son|sons|husband|father|brother|uncle|nephew|grandson|boyfriend|grandfather|widower|groom|boy|man|dad|actor|grandnephew"
    private static let depart = re("\\b(?:left|leaves|walked out|walked away|stormed away|stormed out|hung up|departed|went home)\\b")
    private static let capWordRE = re("\\b(\(cap))\\b(?!['\u{2019}]s)")
    private static let capPlainRE = re("\\b\(cap)\\b")
    private static let subjRE = re("(?:^|[.!?]\\s+)(?:Then |Suddenly |Finally )?(\(cap))\\b(?!['\u{2019}]s)")
    private static let addressedRE = re("(?:^|[,.!?]\\s+)(\(cap))[,!?.]|,\\s*(\(cap))[.!?]")
    private static let headingEndRE = re("[.!?\u{201D}\"]$")
    private static let chapterRE = re("^Chapter \\d+$", .caseInsensitive)

    private static func words(_ s: String) -> [String] { all(wordRE, s).compactMap { $0[0] } }
    private static func sentences(_ s: String) -> [String] {
        let ns = s as NSString
        var out: [String] = [], start = 0
        for m in sentenceSplitRE.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
            start = m.range.location + m.range.length
        }
        out.append(ns.substring(from: start))
        return out
    }

    // MARK: Analysis

    /// The whole book: who the characters are, and who speaks each paragraph.
    static func analyze(_ chapters: [TextChapter]) -> Result {
        let paras: [[String]] = chapters.map { c in
            c.paragraphStarts.indices.map { p in c.paragraphRange(p).map { c.sentences[$0] }.joined(separator: " ") }
        }
        let flat = paras.flatMap { $0 }
        let alltext = flat.joined(separator: " ")

        // Pass 1: names seen in speech tags, and full names.
        var tagCount: [String: Int] = [:]
        for t in flat where t.contains("\u{201C}") || t.contains("\"") {
            for s in tags(split(t)) where s.first?.isUppercase == true {
                for w in s.split(separator: " ").map(String.init) where !stop.contains(w) { tagCount[w, default: 0] += 1 }
            }
        }
        var bigrams: [String: Int] = [:]   // "A B"
        for m in all(bigramRE, alltext) {
            guard let a = m[1], let b = m[2], !stop.contains(a), !stop.contains(b) else { continue }
            bigrams["\(a) \(b)", default: 0] += 1
        }
        var names = Set(tagCount.keys.filter { !has(participleRE, $0) })
        for w in names {
            let total = all(re("\\b\(NSRegularExpression.escapedPattern(for: w))\\b"), alltext).count
            let afterThe = all(re("\\b(?:the|of|of the) \(NSRegularExpression.escapedPattern(for: w))\\b"), alltext).count
            if total > 0 && afterThe * 2 >= total { names.remove(w) }
        }
        var canon: [String: String] = Dictionary(uniqueKeysWithValues: names.map { ($0, $0) })
        var surnameOwners: [String: [String: Int]] = [:]
        let pairs = bigrams.map { (k, c) -> (String, String, Int) in
            let p = k.split(separator: " ").map(String.init); return (p[0], p[1], c)
        }
        for (a, b, c) in pairs where c >= 2 && (names.contains(a) || names.contains(b)) && !has(titleRE, a) {
            surnameOwners[b, default: [:]][a, default: 0] += c
        }
        for (a, b, c) in pairs.sorted(by: { $0.2 != $1.2 ? $0.2 > $1.2 : ($0.0, $0.1) < ($1.0, $1.1) }) {
            guard c >= 2, names.contains(a) || names.contains(b), !has(titleRE, a) else { continue }
            let head = names.contains(a) ? a : b
            let owners = surnameOwners[b] ?? [:]
            if let top = owners.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }), top.key == a,
               top.value * 3 >= 2 * owners.values.reduce(0, +) {
                canon[b] = canon[a] ?? head
                if canon[a] == nil { canon[a] = head }
            }
        }
        func root(_ w: String) -> String {
            var w = w, seen: Set<String> = []
            while let n = canon[w], n != w, !seen.contains(w) { seen.insert(w); w = n }
            return w
        }
        let alias: [String: String] = Dictionary(uniqueKeysWithValues: canon.keys.map { ($0, root($0)) })

        // Gender.
        var votes: [String: (m: Int, f: Int)] = [:]
        func vote(_ c: String, _ female: Bool, _ n: Int = 1) {
            var v = votes[c] ?? (0, 0)
            if female { v.f += n } else { v.m += n }
            votes[c] = v
        }
        for t in flat {
            let narr = split(t).filter { !$0.speech }.map(\.text).joined(separator: " ")
            let sents = sentences(narr.trimmingCharacters(in: .whitespaces))
            for (k, sent) in sents.enumerated() {
                let ws = words(sent)
                guard let w0 = ws.first, let c = alias[w0], !(ws.count > 1 && alias[ws[1]] != nil) else { continue }
                for w in ws.dropFirst() {
                    if alias[w] != nil { break }
                    let l = w.lowercased()
                    if l == "he" || l == "himself" { vote(c, false); break }
                    if l == "she" || l == "herself" { vote(c, true); break }
                }
                if k + 1 < sents.count, let m = first(heShe, sents[k + 1]) { vote(c, m[1] == "She") }
            }
            for m in all(titleNameRE, t) {
                guard let title = m[1], let nm = m[2], let c = alias[nm], (surnameOwners[nm]?.count ?? 0) <= 1 else { continue }
                vote(c, title != "Mr", 3)
            }
        }
        for (female, list) in [(false, masc), (true, fem)] {
            for m in all(re("\\b(?:\(list)),? (\(cap))(?: and (\(cap)))?\\b"), alltext) {
                for nm in [m[1], m[2]].compactMap({ $0 }) { if let c = alias[nm] { vote(c, female, 3) } }
            }
            for m in all(re("\\b(\(cap)),? (?:his|her|their|the) (?:\\w+ )?(?:\(list))\\b"), alltext) {
                if let nm = m[1], let c = alias[nm] { vote(c, female, 3) }
            }
        }
        func gender(_ c: String) -> Character {
            let v = votes[c] ?? (0, 0)
            return v.m > v.f ? "m" : v.f > v.m ? "f" : "?"
        }

        func resolve(_ subj: String, _ before: String) -> String? {
            if subj == "he" || subj == "she" { return subj }
            if subj.hasPrefix("the ") {
                var role = String(subj.split(separator: " ").last ?? "")
                if role.hasSuffix("'s") { role.removeLast(2) }
                // "the as", "the one": not someone speaking.
                if notRoles.contains(role.lowercased()) || subj.contains("\u{2019}") {
                    return nil
                }
                let r = re("\\b(?i:\(NSRegularExpression.escapedPattern(for: role)))\\.? (?:\(cap) )?(\(cap))\\b")
                for m in all(r, before).reversed() { if let n = m[1], let a = alias[n] { return a } }
                return role.lowercased()
            }
            for w in subj.split(separator: " ") { if let a = alias[String(w)] { return a } }
            return nil
        }

        func namesIn(_ text: String) -> [String] {
            var out: [String] = [], prevEnd = -2
            for m in all(capWordRE, text) {
                guard let w = m[1], let a = alias[w] else { continue }
                if m.range.location == prevEnd + 1 && !out.isEmpty { prevEnd = m.range.location + m.range.length; continue }
                out.append(a); prevEnd = m.range.location + m.range.length
            }
            return out
        }

        struct Evidence {
            var tag: String?, pron: Character?
            var subj: [String] = [], ment: [String] = [], before: [String] = [], spoken: [String] = []
            var addressed: Set<String> = []
        }
        func evidence(_ t: String, _ history: String) -> Evidence {
            let segs = split(t)
            let narr = segs.filter { !$0.speech }.map(\.text).joined(separator: " ")
            let speech = segs.filter(\.speech).map(\.text)
            var e = Evidence()
            for x in speech {
                for m in all(addressedRE, x) { if let w = m[1] ?? m[2], let a = alias[w] { e.addressed.insert(a) } }
            }
            let subs = tags(segs).compactMap { resolve($0, history + " " + t) }
            if let s = subs.first {
                if s == "he" || s == "she" { e.pron = s == "he" ? "m" : "f" } else { e.tag = s }
            }
            e.subj = all(subjRE, narr.trimmingCharacters(in: .whitespaces)).compactMap { $0[1].flatMap { alias[$0] } }
            e.ment = namesIn(narr)
            if let lead = segs.first, !lead.speech { e.before = namesIn(lead.text) }
            e.spoken = speech.flatMap { x in all(capPlainRE, x).compactMap { $0[0].flatMap { alias[$0] } } }
            return e
        }

        func cost(_ c: String, _ e: Evidence, _ contPrev: String?) -> Double {
            if let p = contPrev { return c == p ? 0 : 20 }
            if e.addressed.contains(c) { return 8 }
            if let tag = e.tag { return c == tag ? 0 : 12 }
            var k = 0.0
            if let pron = e.pron {
                let g: Character = c.first?.isLowercase == true ? "?" : gender(c)
                let okg = { (x: String) in (gender(x) == pron || gender(x) == "?") && !e.addressed.contains(x) }
                let here = e.before.filter(okg).suffix(1).first ?? e.ment.first(where: okg)
                if let h = here { return c == h ? 0 : 6 }
                k += g == pron ? 0 : (g == "?" ? 1 : 6)
            } else if let b = e.before.last {
                k += c == b ? 0 : (e.ment.contains(c) ? 1 : 3)
            } else if let s = e.subj.first {
                k += c == s ? 0 : (e.ment.contains(c) ? 1 : 3)
            } else if let m = e.ment.first {
                k += c == m ? 0 : 1.5
            }
            return k
        }

        struct Line {
            let ch: Int, p: Int, e: Evidence, cont: Bool, fresh: [String], freshAfter: Bool
            let seen: Set<String>, gone: Set<String>, age: [String: Int], prevAddr: Set<String>, prevSpoken: Set<String>
        }

        var speakerName: [[String?]] = paras.map { Array(repeating: nil, count: $0.count) }
        var uncertain: [[Bool]] = paras.map { Array(repeating: false, count: $0.count) }

        // Pass 2: the best speaker sequence for each scene.
        func solve(_ scene: [Line]) {
            guard !scene.isEmpty else { return }
            var castSet = Set<String>()
            for l in scene { castSet.formUnion(l.e.ment); if let t = l.e.tag { castSet.insert(t) } }
            // Nobody named in the scene: leave it to the narrator, and to Claude if asked.
            guard !castSet.isEmpty else {
                for l in scene { uncertain[l.ch][l.p] = true }
                return
            }
            let cast = castSet.sorted()
            let n = cast.count
            // State (previous speaker, speaker); index n is "nobody yet".
            let none = n
            var score = [Double](repeating: .infinity, count: (n + 1) * (n + 1))
            score[none * (n + 1) + none] = 0
            var back: [[Int32]] = []   // per line: for each state (b, c), the previous state's a
            for l in scene {
                var next = [Double](repeating: .infinity, count: (n + 1) * (n + 1))
                var from = [Int32](repeating: -1, count: (n + 1) * (n + 1))
                for a in 0...n {
                    for b in 0...n {
                        let sc = score[a * (n + 1) + b]
                        guard sc.isFinite else { continue }
                        for ci in 0..<n {
                            let c = cast[ci]
                            let contPrev: String? = l.cont && b < n ? cast[b] : nil
                            var tr: Double
                            if l.cont { tr = 0 }
                            else if b == none { tr = l.fresh.contains(c) ? 0 : 0.5 }
                            else if ci == b { tr = l.freshAfter ? 1.5 : 3.0 }
                            else if a < n && ci == a { tr = 0 }
                            else if l.fresh.contains(c) { tr = 0.6 }
                            else { tr = 1.6 }
                            if l.gone.contains(c) { tr += 4 }
                            tr += min(2.0, 0.3 * Double(l.age[c] ?? 99))
                            if l.prevAddr.contains(c) && !l.cont { tr -= 1.0 }
                            if l.prevSpoken.contains(c) && !l.cont { tr -= 0.4 }
                            if !l.seen.contains(c) { tr += 0.8 }
                            let v = sc + cost(c, l.e, contPrev) + tr
                            let key = b * (n + 1) + ci
                            if v < next[key] { next[key] = v; from[key] = Int32(a) }
                        }
                    }
                }
                score = next
                back.append(from)
            }
            var best = 0
            for i in score.indices where score[i] < score[best] { best = i }
            var b = best / (n + 1), c = best % (n + 1)
            for i in stride(from: scene.count - 1, through: 0, by: -1) {
                let l = scene[i]
                if c < n { speakerName[l.ch][l.p] = cast[c] }
                uncertain[l.ch][l.p] = !(l.cont || l.e.tag != nil)
                let a = Int(back[i][b * (n + 1) + c])
                c = b; b = a
            }
        }

        var history = ""
        for (ci, list) in paras.enumerated() {
            var scene: [Line] = [], seen = Set<String>(), fresh: [String] = [], gone = Set<String>(), openQ = false
            var lastSeen: [String: Int] = [:], prevAddr = Set<String>(), prevSpoken = Set<String>()
            for (pi, raw) in list.enumerated() {
                let t = raw.trimmingCharacters(in: .whitespaces)
                let heading = has(chapterRE, t) || t.hasPrefix("* * *") || t.hasPrefix("***") || (t.count < 40 && !has(headingEndRE, t))
                if heading {
                    solve(scene)
                    scene = []; seen = []; fresh = []; gone = []; openQ = false
                    lastSeen = [:]; prevAddr = []; prevSpoken = []
                    continue
                }
                let segs = split(t)
                let e = evidence(t, history)
                history = String((history + " " + t).suffix(6000))
                let isDlg = (t.contains("\u{201C}") || t.contains("\"")) && isDialogue(segs)
                let narr = segs.filter { !$0.speech }.map(\.text).joined(separator: " ")
                for sent in sentences(narr) where has(depart, sent) {
                    if let c = words(sent).compactMap({ alias[$0] }).first { gone.insert(c) }
                }
                let idx = pi
                if isDlg {
                    let cont = openQ && (t.hasPrefix("\u{201C}") || t.hasPrefix("\""))
                    var age = lastSeen.mapValues { idx - $0 }
                    for c in e.ment { age[c] = 0 }
                    scene.append(Line(ch: ci, p: pi, e: e, cont: cont, fresh: fresh + e.ment, freshAfter: !fresh.isEmpty,
                                      seen: seen.union(e.ment), gone: gone, age: age, prevAddr: prevAddr, prevSpoken: prevSpoken))
                    prevAddr = e.addressed; prevSpoken = Set(e.spoken)
                    for c in e.ment { gone.remove(c) }
                    fresh = []
                    openQ = endsOpen(t)
                } else {
                    fresh = Array((fresh + e.ment).suffix(6))
                    if !has(depart, narr) { for c in e.ment { gone.remove(c) } }
                    openQ = false
                }
                seen.formUnion(e.ment)
                for c in e.ment + e.spoken + (e.tag.map { [$0] } ?? []) { lastSeen[c] = idx }
            }
            solve(scene)
        }

        // The cast, most lines first.
        var lines: [String: Int] = [:]
        for row in speakerName { for s in row { if let s { lines[s, default: 0] += 1 } } }
        let order = lines.keys.sorted { lines[$0]! != lines[$1]! ? lines[$0]! > lines[$1]! : $0 < $1 }
        let index = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let characters = order.map { name -> CastCharacter in
            // Shown by the name the book uses most ("Hansen", not "Jon").
            let group = [name] + alias.filter { $0.value == name && $0.key != name }.map(\.key).sorted()
            let uses = group.map { w in all(re("\\b\(NSRegularExpression.escapedPattern(for: w))\\b"), alltext).count }
            let shown = group.count > 1 ? group[uses.indices.max { uses[$0] < uses[$1] } ?? 0] : name
            let display = shown.first?.isLowercase == true ? "The " + shown : shown
            let aliases = group.filter { $0 != shown }
            let g = gender(name)
            return CastCharacter(name: display, aliases: aliases, gender: g == "m" ? .male : g == "f" ? .female : .unknown, lines: lines[name]!)
        }
        return Result(characters: characters,
                      speakers: speakerName.map { $0.map { $0.flatMap { index[$0] } ?? -1 } },
                      uncertain: uncertain)
    }
}
