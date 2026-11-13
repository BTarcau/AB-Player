import Observation
import SwiftUI
import UIKit

enum VoiceSource: String, CaseIterable, Identifiable {
    /// Kokoro, running on this iPhone.
    case kokoro
    /// Apple's built-in voices.
    case device
    /// Pocket TTS, copying a narrator's voice from a reference clip, on this iPhone's CPU.
    case pocket
    var id: String { rawValue }
    var label: String {
        switch self {
        case .kokoro: return "Kokoro"
        case .device: return "\(ThisDevice.name) voice"
        case .pocket: return PocketEngine.voices.count == 1 ? PocketEngine.voices[0].capitalized : "Cloned"
        }
    }
}

enum SkipUnit: String, CaseIterable, Identifiable {
    case sentence, paragraph
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum ReaderTheme: String, CaseIterable, Identifiable {
    case paper, dark, auto
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Lamplight's five reading fonts, mapped to fonts that ship with iOS.
enum ReaderFont: String, CaseIterable, Identifiable {
    case newYork, charter, georgia, avenir, system
    var id: String { rawValue }
    var label: String {
        switch self {
        case .newYork: return "New York"
        case .charter: return "Charter"
        case .georgia: return "Georgia"
        case .avenir: return "Avenir"
        case .system: return "System"
        }
    }

    func uiFont(size: CGFloat, bold: Bool = false) -> UIFont {
        let weight: UIFont.Weight = bold ? .semibold : .regular
        switch self {
        case .newYork:
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            return base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? base
        case .charter: return UIFont(name: bold ? "Charter-Bold" : "Charter-Roman", size: size) ?? .systemFont(ofSize: size)
        case .georgia: return UIFont(name: bold ? "Georgia-Bold" : "Georgia", size: size) ?? .systemFont(ofSize: size)
        case .avenir: return UIFont(name: bold ? "AvenirNext-DemiBold" : "AvenirNext-Regular", size: size) ?? .systemFont(ofSize: size)
        case .system: return .systemFont(ofSize: size, weight: weight)
        }
    }

    func font(size: CGFloat) -> Font { Font(uiFont(size: size)) }
}

/// Lamplight's paper and dark colours.
struct ReaderPalette {
    let paper, paper2, card, ink, inkSoft, lamp, lampDark, brass, glow, danger: UIColor

    static let paperTheme = ReaderPalette(
        paper: .init(hex: 0xECE6D6), paper2: .init(hex: 0xE2DAC5), card: .white, ink: .init(hex: 0x2B2620),
        inkSoft: .init(hex: 0x6B6355), lamp: .init(hex: 0x3F5D48), lampDark: .init(hex: 0x2B4234),
        brass: .init(hex: 0xAD8A52), glow: UIColor(red: 173 / 255, green: 138 / 255, blue: 82 / 255, alpha: 0.30),
        danger: .init(hex: 0xB4512F))
    static let darkTheme = ReaderPalette(
        paper: .init(hex: 0x1B1F1A), paper2: .init(hex: 0x262B23), card: .init(hex: 0x232821), ink: .init(hex: 0xE9E4D4),
        inkSoft: .init(hex: 0xA8A192), lamp: .init(hex: 0x6FA37E), lampDark: .init(hex: 0x8FC29E),
        brass: .init(hex: 0xD9B577), glow: UIColor(red: 217 / 255, green: 181 / 255, blue: 119 / 255, alpha: 0.24),
        danger: .init(hex: 0xE08A6A))

    static func resolve(_ theme: ReaderTheme, _ scheme: ColorScheme) -> ReaderPalette {
        switch theme {
        case .paper: return .paperTheme
        case .dark: return .darkTheme
        case .auto: return scheme == .dark ? .darkTheme : .paperTheme
        }
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Everything the reader remembers between launches (Lamplight's "lamplight:*" settings).
@MainActor @Observable
final class ReaderSettings {
    static let shared = ReaderSettings()
    @ObservationIgnored private let d = UserDefaults.standard

    static let defaultShelves = ["Christian", "Biography", "Sci-fi", "Classics"]

    var source: VoiceSource { didSet { d.set(source.rawValue, forKey: "rd.source") } }
    var kokoroVoice: String { didSet { d.set(kokoroVoice, forKey: "rd.kokoroVoice") } }
    var deviceVoice: String { didSet { d.set(deviceVoice, forKey: "rd.deviceVoice") } }
    var pocketVoice: String { didSet { d.set(pocketVoice, forKey: "rd.pocketVoice") } }
    var speed: Double { didSet { d.set(speed, forKey: "rd.speed") } }
    var gapMs: Int { didSet { d.set(gapMs, forKey: "rd.gapMs") } }
    var skipUnit: SkipUnit { didSet { d.set(skipUnit.rawValue, forKey: "rd.skipUnit") } }

    var fontSize: Double { didSet { d.set(fontSize, forKey: "rd.fontSize") } }
    var font: ReaderFont { didSet { d.set(font.rawValue, forKey: "rd.font") } }
    var theme: ReaderTheme { didSet { d.set(theme.rawValue, forKey: "rd.theme") } }
    var follow: Bool { didSet { d.set(follow, forKey: "rd.follow") } }
    var fadeRead: Bool { didSet { d.set(fadeRead, forKey: "rd.fadeRead") } }

    var filterEnabled: Bool { didSet { d.set(filterEnabled, forKey: "rd.filterEnabled") } }
    var filterWords: [String] { didSet { d.set(filterWords, forKey: "rd.filterWords"); filterRegexCache = nil } }
    var pronunciationRules: [PronunciationRule] {
        didSet { d.set(try? JSONEncoder().encode(pronunciationRules), forKey: "rd.pronunciation") }
    }

    var shelves: [String] { didSet { d.set(shelves, forKey: "rd.shelves") } }
    var groupSeries: Bool { didSet { d.set(groupSeries, forKey: "rd.groupSeries") } }

    /// Seconds of speech per character at 1×, learned from the clips made so far.
    var secPerChar: Double { didSet { d.set(secPerChar, forKey: TextTiming.key) } }

    @ObservationIgnored private var filterRegexCache: NSRegularExpression??

    var rules: TextRules {
        if filterRegexCache == nil { filterRegexCache = .some(TextPipeline.badWordsRegex(extraWords: filterWords)) }
        return TextRules(filterEnabled: filterEnabled, filterRegex: filterRegexCache ?? nil, pronunciationRules: pronunciationRules)
    }

    /// The speed the voice reads at. The cloned narrator keeps his own pace; the
    /// speed setting is there for Kokoro, which reads too fast.
    var voiceSpeed: Double { source == .pocket ? 1 : speed }

    var currentVoice: String {
        switch source {
        case .kokoro: return kokoroVoice
        case .device: return deviceVoice
        case .pocket: return pocketVoice
        }
    }

    private init() {
        source = VoiceSource(rawValue: d.string(forKey: "rd.source") ?? "") ?? .kokoro
        kokoroVoice = d.string(forKey: "rd.kokoroVoice") ?? "af_heart"
        deviceVoice = d.string(forKey: "rd.deviceVoice") ?? ""
        pocketVoice = d.string(forKey: "rd.pocketVoice") ?? "andrei"
        speed = d.object(forKey: "rd.speed") as? Double ?? 1
        gapMs = d.object(forKey: "rd.gapMs") as? Int ?? 80
        skipUnit = SkipUnit(rawValue: d.string(forKey: "rd.skipUnit") ?? "") ?? .sentence
        fontSize = d.object(forKey: "rd.fontSize") as? Double ?? 19
        font = ReaderFont(rawValue: d.string(forKey: "rd.font") ?? "") ?? .newYork
        theme = ReaderTheme(rawValue: d.string(forKey: "rd.theme") ?? "") ?? .paper
        follow = d.object(forKey: "rd.follow") as? Bool ?? true
        fadeRead = d.object(forKey: "rd.fadeRead") as? Bool ?? true
        filterEnabled = d.object(forKey: "rd.filterEnabled") as? Bool ?? true
        filterWords = d.stringArray(forKey: "rd.filterWords") ?? []
        pronunciationRules = (d.data(forKey: "rd.pronunciation")).flatMap { try? JSONDecoder().decode([PronunciationRule].self, from: $0) } ?? []
        shelves = d.stringArray(forKey: "rd.shelves") ?? Self.defaultShelves
        groupSeries = d.object(forKey: "rd.groupSeries") as? Bool ?? true
        secPerChar = TextTiming.secPerChar
    }

    // MARK: Shelves

    /// Shelves suggested by an EPUB's subjects, only for shelves that exist.
    func suggestShelves(_ subjects: [String]) -> [String] {
        let rules: [(String, String)] = [
            ("Christian", "christian|religio|bible|biblical|devotion|theolog|gospel|church|faith"),
            ("Biography", "biograph|memoir|autobiograph|diary|letters"),
            ("Sci-fi", "science fiction|sci-?fi|space opera"),
            ("Classics", "classic"),
        ]
        let text = subjects.joined(separator: " | ")
        return rules.filter { shelves.contains($0.0) && text.range(of: $0.1, options: [.regularExpression, .caseInsensitive]) != nil }.map(\.0)
    }
}

/// Speech-length estimates that views and models can read from any thread.
enum TextTiming {
    static let key = "rd.secPerChar"
    static var secPerChar: Double {
        let v = UserDefaults.standard.double(forKey: key)
        return v > 0 ? v : 0.075
    }
}

/// Kokoro voice ids ("af_heart") as names: a/b = American/British, f/m = female/male.
func friendlyVoiceName(_ id: String) -> (name: String, detail: String) {
    let chars = Array(id)
    guard chars.count > 3, id.contains("_") else { return (id, "") }
    let region = chars[0] == "a" ? "American" : chars[0] == "b" ? "British" : String(chars[0]).uppercased()
    let gender = chars[1] == "f" ? "female" : chars[1] == "m" ? "male" : ""
    let name = String(id.dropFirst(3)).capitalized
    return (name, "\(region) \(gender)".trimmingCharacters(in: .whitespaces))
}
