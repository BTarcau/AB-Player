import Foundation

/// Sentence splitting, the language filter, the pronunciation dictionary and the
/// small rewrites that make a voice read more naturally. Ported from Lamplight's
/// text.js; the on-screen text is never changed except for the filter's masking.
enum TextPipeline {
    // Kokoro can clip the end of very long inputs, so longer sentences are split
    // further at natural pause points. Affects speech and highlighting only.
    static let maxTTSChars = 200

    // MARK: Sentence splitting

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func replace(_ text: String, _ re: NSRegularExpression, _ template: String) -> String {
        re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func matches(_ text: String, _ re: NSRegularExpression) -> [String] {
        re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func splitOnPunct(_ text: String, _ punct: String) -> [String] {
        let p = NSRegularExpression.escapedPattern(for: punct)
        let re = regex("[^\(p)]+\(p)+(?:\\s+|$)|[^\(p)]+$")
        let parts = matches(text, re)
        guard parts.count >= 2 else { return [text] }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func hardWrap(_ text: String, _ maxChars: Int) -> [String] {
        var out: [String] = []
        var cur = ""
        for word in text.split(separator: " ") {
            if !cur.isEmpty && cur.count + 1 + word.count > maxChars {
                out.append(cur)
                cur = String(word)
            } else {
                cur = cur.isEmpty ? String(word) : cur + " " + word
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private static func splitLongClause(_ text: String, _ maxChars: Int) -> [String] {
        guard text.count > maxChars else { return [text] }
        var parts = splitOnPunct(text, ";")
        if parts.count == 1 { parts = splitOnPunct(text, ",") }
        if parts.count == 1 { return hardWrap(text, maxChars) }
        return parts.flatMap { splitLongClause($0.trimmingCharacters(in: .whitespaces), maxChars) }
    }

    // Abbreviations and initials ("Mr.", "C. S. Lewis") aren't sentence ends.
    private static let abbrRE = regex(#"\b(Mr|Mrs|Ms|Dr|St|Mt|Prof|Rev|Gen|Col|Capt|Lt|Sgt|Sr|Jr|vs|etc|Ph\.D|i\.e|e\.g)\."#)
    private static let initialRE = regex(#"\b([A-Z])\.(?=\s*[A-Z]\.|\s+[A-Z]\b)"#)
    // ". . ." is one pause, not three sentence ends: before a capital it still
    // ends the sentence ("..."), otherwise it becomes "…", which doesn't.
    private static let spacedEllipsisBeforeCapitalRE = regex(#"\.(?:\s\.){2,}(?=\s+["'“‘]?[A-Z])"#)
    private static let spacedEllipsisRE = regex(#"\.(?:\s\.){2,}"#)
    private static let sentenceRE = regex(#"[^.!?]+[.!?]+[)\]'"’”]*(?:\s+|$)|[^.!?]+$"#)

    static let dialogueTagVerbs = "said|asked|replied|answered|cried|shouted|whispered|muttered|exclaimed|continued|added|began|called|retorted|murmured|sighed|snapped|gasped|sobbed|roared|growled|chuckled|laughed|wondered|declared|announced|remarked|grumbled|protested|went on"

    // "Are you coming?" asked Peter. — one thought, not two sentences.
    private static let dialogueEndRE = regex(#"([?!])(['"’”]+)(\s+)(?=(?:\w+\s+)?(?:\#(dialogueTagVerbs))\b)"#, .caseInsensitive)
    private static let quotedEndRE = regex(#"[.!?][)\]'"’”]+\s*$"#)
    /// Extra beat after a line of dialogue ends with nothing following it.
    static let dialogueEndPause: TimeInterval = 0.22

    static func endsQuotedDialogue(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return quotedEndRE.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }

    static func splitSentences(_ text: String) -> [String] {
        var cleaned = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return [] }
        cleaned = replace(cleaned, spacedEllipsisBeforeCapitalRE, "...")
        cleaned = replace(cleaned, spacedEllipsisRE, "…")
        cleaned = replace(cleaned, abbrRE, "$1\u{1}")
        cleaned = replace(cleaned, initialRE, "$1\u{1}")
        // ? -> \u{2}, ! -> \u{3} when a speech tag follows
        let ns = NSMutableString(string: cleaned)
        for m in dialogueEndRE.matches(in: cleaned, range: NSRange(location: 0, length: ns.length)).reversed() {
            let punct = ns.substring(with: m.range(at: 1))
            ns.replaceCharacters(in: m.range(at: 1), with: punct == "?" ? "\u{2}" : "\u{3}")
        }
        cleaned = ns as String
        var rough = matches(cleaned, sentenceRE)
        if rough.isEmpty { rough = [cleaned] }
        let restored = rough.map {
            $0.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\u{1}", with: ".")
                .replacingOccurrences(of: "\u{2}", with: "?")
                .replacingOccurrences(of: "\u{3}", with: "!")
        }.filter { $0.count > 1 }
        return restored.flatMap { splitLongClause($0, maxTTSChars) }
    }

    // MARK: Language filter

    static let defaultBadWords = ["fuck", "shit", "bitch", "bastard", "asshole", "cunt", "slut", "whore", "dick", "cock", "pussy", "twat", "douche", "goddamn", "bullshit"]

    static func badWordsRegex(extraWords: [String]) -> NSRegularExpression? {
        let words = (defaultBadWords + extraWords).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        let escaped = words.map(NSRegularExpression.escapedPattern(for:))
        return try? NSRegularExpression(pattern: "\\b(" + escaped.joined(separator: "|") + ")\\w*", options: .caseInsensitive)
    }

    /// On screen: first letter kept, the rest masked ("s***").
    static func displayText(_ text: String, _ settings: TextRules) -> String {
        guard settings.filterEnabled, let re = settings.filterRegex else { return text }
        let ns = NSMutableString(string: text)
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let word = ns.substring(with: m.range)
            let masked = String(word.prefix(1)) + String(repeating: "*", count: max(1, word.count - 1))
            ns.replaceCharacters(in: m.range, with: masked)
        }
        return ns as String
    }

    // MARK: Speech-only rewrites

    private static let titleExpansions = [
        "Mr": "Mister", "Mrs": "Missus", "Dr": "Doctor", "Prof": "Professor",
        "Gen": "General", "Col": "Colonel", "Capt": "Captain", "Lt": "Lieutenant",
        "Sgt": "Sergeant", "Rev": "Reverend", "Sr": "Senior", "Jr": "Junior",
    ]
    private static let titleRE = regex("\\b(" + titleExpansions.keys.joined(separator: "|") + ")\\.")
    private static let dialogueCommaRE = regex(#",(\s*['"’”]+)(\s+)(?=(?:\w+\s+)?(?:\#(dialogueTagVerbs))\b)"#, .caseInsensitive)

    /// What the voice is given for a sentence: pronunciation rules, spoken titles,
    /// filtered words removed, and pause cues the voice understands.
    static func speechText(_ text: String, _ settings: TextRules) -> String {
        var out = applyPronunciation(text, settings.pronunciationRules)
        let ns = NSMutableString(string: out)
        for m in titleRE.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
            let word = ns.substring(with: m.range(at: 1))
            ns.replaceCharacters(in: m.range, with: titleExpansions[word] ?? word)
        }
        out = ns as String
        if settings.filterEnabled, let re = settings.filterRegex {
            out = replace(out, re, "").replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        // Em dashes and "(" get a comma: a pause cue the voice knows.
        out = out.replacingOccurrences(of: #"\s*—\s*"#, with: ", ", options: .regularExpression)
            .replacingOccurrences(of: "(", with: ", ")
        return replace(out, dialogueCommaRE, "$1$2")
    }

    static func applyPronunciation(_ text: String, _ rules: [PronunciationRule]) -> String {
        guard !rules.isEmpty else { return text }
        var out = text
        for rule in rules where !rule.find.isEmpty {
            let pattern = NSRegularExpression.escapedPattern(for: rule.find)
            guard let re = try? NSRegularExpression(pattern: pattern, options: rule.matchCase ? [] : .caseInsensitive) else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: rule.replace))
        }
        return out.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// A snapshot of the word settings, safe to use off the main thread.
struct TextRules: @unchecked Sendable {
    var filterEnabled = true
    var filterRegex: NSRegularExpression?
    var pronunciationRules: [PronunciationRule] = []
}

struct PronunciationRule: Codable, Hashable, Identifiable {
    var id = UUID()
    var find: String
    var replace: String
    var matchCase = false
}

// MARK: - Parsed text

/// A chapter split into paragraphs of sentences.
struct TextChapter: Codable, Hashable {
    var title: String
    var sentences: [String]
    /// Paragraph number of each sentence.
    var sentenceParagraph: [Int]
    /// First sentence of each paragraph.
    var paragraphStarts: [Int]

    var charCount: Int { sentences.reduce(0) { $0 + $1.count } }

    func paragraphRange(_ p: Int) -> Range<Int> {
        let start = paragraphStarts[p]
        let end = p + 1 < paragraphStarts.count ? paragraphStarts[p + 1] : sentences.count
        return start..<end
    }

    init?(title: String, paragraphs: [String]) {
        var sentences: [String] = []
        var sentenceParagraph: [Int] = []
        var starts: [Int] = []
        for text in paragraphs {
            let s = TextPipeline.splitSentences(text)
            guard !s.isEmpty else { continue }
            starts.append(sentences.count)
            sentenceParagraph += Array(repeating: starts.count - 1, count: s.count)
            sentences += s
        }
        guard !sentences.isEmpty else { return nil }
        self.title = title
        self.sentences = sentences
        self.sentenceParagraph = sentenceParagraph
        self.paragraphStarts = starts
    }
}

struct ParsedText: Codable {
    var chapters: [TextChapter]
    var title: String = ""
    var author: String = ""
    var subjects: [String] = []
    var series: String = ""
    var seriesIndex: Double?
    var cover: Data?
}
