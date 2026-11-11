@preconcurrency import AVFoundation
import Foundation
import Observation
#if canImport(KokoroTTS)
import CoreML
import KokoroTTS
#endif

/// One spoken sentence, ready to play.
struct Clip: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var duration: Double { Double(buffer.frameLength) / buffer.format.sampleRate }
}

enum VoiceError: LocalizedError {
    case unavailable(String), noAudio, timeout
    var errorDescription: String? {
        switch self {
        case .unavailable(let m): return m
        case .noAudio: return "The voice returned no audio."
        case .timeout: return "Voice generation timed out."
        }
    }
}

// MARK: - Audio helpers

enum ClipAudio {
    /// Every clip is converted to this before it's played.
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!

    static func decode(_ data: Data) throws -> AVAudioPCMBuffer {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw VoiceError.noAudio
        }
        try file.read(into: buf)
        return try convert(buf)
    }

    static func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if input.format == format { return input }
        guard let converter = AVAudioConverter(from: input.format, to: format) else { throw VoiceError.noAudio }
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw VoiceError.noAudio }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .endOfStream; return nil }
            given = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return out
    }

    static func silence(_ seconds: Double) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(1, frames))!
        buf.frameLength = max(1, frames)
        if let ch = buf.floatChannelData { ch[0].update(repeating: 0, count: Int(buf.frameLength)) }
        return buf
    }

    /// Trims silence at the edges to half the gap and caps silent runs inside the
    /// clip at the gap, so sentences flow at an even pace (Lamplight's compressSilence).
    static func compressSilence(_ buf: AVAudioPCMBuffer, gapMs: Int) -> AVAudioPCMBuffer {
        guard let data = buf.floatChannelData?[0], buf.frameLength > 0 else { return buf }
        let n = Int(buf.frameLength)
        let rate = buf.format.sampleRate
        let frameLen = max(1, Int(rate * 0.015))
        let frames = (n + frameLen - 1) / frameLen
        var rms = [Float](repeating: 0, count: frames)
        var peak: Float = 0
        for f in 0..<frames {
            let s = f * frameLen, e = min(n, s + frameLen)
            var sum: Float = 0
            for i in s..<e { sum += data[i] * data[i] }
            rms[f] = (sum / Float(max(1, e - s))).squareRoot()
            peak = max(peak, rms[f])
        }
        let threshold = max(peak * 0.04, 0.004)
        var startF = 0, endF = frames - 1
        while startF < frames && rms[startF] < threshold { startF += 1 }
        while endF > startF && rms[endF] < threshold { endF -= 1 }
        guard endF > startF else { return buf }
        let edgePad = max(1, Int(ceil(Double(gapMs) / 2 / 15)))
        let maxGap = max(1, Int(ceil(Double(gapMs) / 15)))
        let from = max(0, startF - edgePad), to = min(frames - 1, endF + edgePad)
        var kept: [Int] = []
        var f = from
        while f <= to {
            if rms[f] >= threshold { kept.append(f); f += 1; continue }
            let run = f
            while f <= to && rms[f] < threshold { f += 1 }
            kept += (run..<run + min(f - run, maxGap))
        }
        guard let out = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: AVAudioFrameCount(kept.count * frameLen)),
              let dst = out.floatChannelData?[0] else { return buf }
        // Where frames were cut out, fade a few milliseconds out and back in so
        // the join doesn't click.
        let fade = min(frameLen, Int(rate * 0.004))
        var w = 0
        var previous = -2
        for fi in kept {
            let s = fi * frameLen, e = min(n, s + frameLen)
            let joined = previous >= 0 && fi != previous + 1
            if joined {
                for k in 0..<min(fade, w) { dst[w - 1 - k] *= Float(k) / Float(fade) }
            }
            let start = w
            for i in s..<e { dst[w] = data[i]; w += 1 }
            if joined {
                for k in 0..<min(fade, w - start) { dst[start + k] *= Float(k) / Float(fade) }
            }
            previous = fi
        }
        out.frameLength = AVAudioFrameCount(w)
        return out
    }
}

@MainActor @Observable
final class VoiceStatus {
    static let shared = VoiceStatus()
    /// The line above the player ("Buffering… 7 s", "Loading the Kokoro voice…", errors).
    var line = ""
}

// MARK: - Kokoro on this iPhone

/// Kokoro v1.0 running on the iPhone's Neural Engine through Core ML
/// (kokoro-coreml). The Neural Engine keeps working while the screen is locked
/// and leaves the CPU almost idle (about 2%), so iOS lets it read ahead in the
/// background. The GPU is kept out of it, because iOS refuses GPU work from
/// background apps. Text becomes phonemes with Misaki, Kokoro's own
/// phonemizer, in an American or British accent to match the voice.
final class KokoroEngine: @unchecked Sendable {
    static let shared = KokoroEngine()

    /// The English voices in the bundle (built by ios/Scripts/setup-kokoro.sh).
    static let voices = [
        "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore", "af_nicole", "af_nova",
        "af_river", "af_sarah", "af_sky", "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam",
        "am_michael", "am_onyx", "am_puck", "am_santa", "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
        "bm_daniel", "bm_fable", "bm_george", "bm_lewis",
    ]

    static var bundleDir: URL? { Bundle.main.url(forResource: "KokoroRuntime", withExtension: nil) }

    /// Where Core ML keeps the models it compiled for this iPhone.
    static var compiledDir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("KokoroCompiled", isDirectory: true)
    }

    /// True until the models have been compiled once (that first load takes about a minute).
    static var firstLoad: Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: compiledDir.path)) ?? []).isEmpty
    }

    /// Why Kokoro can't run in this build, or nil when it can.
    static var unavailableReason: String? {
        #if targetEnvironment(simulator)
        // Misaki runs on MLX, which needs a real GPU and crashes in the simulator.
        return "The Kokoro voice only runs on a real iPhone, not in the simulator."
        #elseif canImport(KokoroTTS)
        guard let dir = bundleDir, FileManager.default.fileExists(atPath: dir.appendingPathComponent("KokoroRuntimeManifest.json").path) else {
            return "The Kokoro voice models aren't in this build. Run ios/Scripts/setup-kokoro.sh, then build again."
        }
        return nil
        #else
        return "The Kokoro voice engine isn't in this build."
        #endif
    }

    private let lock = NSLock()
    #if canImport(KokoroTTS)
    private var tts: KokoroTTS?
    private var loading: Task<KokoroTTS, Error>?
    #endif

    var isLoaded: Bool {
        #if canImport(KokoroTTS)
        return lock.withLock { tts != nil }
        #else
        return false
        #endif
    }

    /// Loads and warms up the models: a few seconds, or about a minute the first
    /// time, while Core ML compiles them for this iPhone.
    func prepare(voice: String) async throws {
        #if canImport(KokoroTTS)
        _ = try await engine(voice: voice)
        #else
        throw VoiceError.unavailable(Self.unavailableReason ?? "")
        #endif
    }

    /// One sentence of speech. Calls run one at a time.
    func generate(text: String, voice: String, speed: Double) async throws -> AVAudioPCMBuffer {
        #if canImport(KokoroTTS)
        let tts = try await engine(voice: voice)
        let audio = try await tts.synthesize(text, voice: KokoroVoiceID(voice), options: KokoroSynthesisOptions(speed: Float(speed)))
        guard !audio.samples.isEmpty else { throw VoiceError.noAudio }
        return try ClipAudio.convert(try audio.makePCMBuffer())
        #else
        throw VoiceError.unavailable(Self.unavailableReason ?? "")
        #endif
    }

    #if canImport(KokoroTTS)
    private func engine(voice: String) async throws -> KokoroTTS {
        if let reason = Self.unavailableReason { throw VoiceError.unavailable(reason) }
        let task: Task<KokoroTTS, Error> = lock.withLock {
            if let loading { return loading }
            let task = Task { try await Self.load(voice: voice) }
            loading = task
            return task
        }
        do {
            let tts = try await task.value
            lock.withLock { self.tts = tts }
            return tts
        } catch {
            lock.withLock { loading = nil }
            throw error
        }
    }

    private static func load(voice: String) async throws -> KokoroTTS {
        guard let dir = bundleDir else { throw VoiceError.unavailable(unavailableReason ?? "") }
        // Never the ANE+GPU generator: Metal fails in the background.
        setenv("KOKORO_HYBRID_GENERATOR", "0", 1)
        var cache = compiledDir
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? cache.setResourceValues(values)
        let policy = KokoroComputePolicy(duration: .cpuOnly, f0ntrain: .cpuAndNeuralEngine,
                                         decoderPre: .cpuAndNeuralEngine, generator: .cpuAndNeuralEngine)
        let tts = try await KokoroTTS.load(resources: .directory(dir, compiledModelsDirectory: cache), computePolicy: policy)
        try await tts.prewarm(text: "The lamp is lit, and the story can begin.", voice: KokoroVoiceID(voice))
        return tts
    }
    #endif
}

// MARK: - Apple's voice on this iPhone

/// Renders speech to buffers with AVSpeechSynthesizer, one sentence at a time.
final class DeviceVoice: @unchecked Sendable {
    static let shared = DeviceVoice()
    private let synth = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    struct Voice: Identifiable, Hashable { let id: String; let name: String; let detail: String }

    static func voices() -> [Voice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && !$0.identifier.contains("speech.synthesis.voice") && !$0.identifier.contains("eloquence") }
            .sorted { a, b in a.quality.rawValue != b.quality.rawValue ? a.quality.rawValue > b.quality.rawValue : a.name < b.name }
            .map { v in
                let q = v.quality == .premium ? "Premium" : v.quality == .enhanced ? "Enhanced" : "Default"
                return Voice(id: v.identifier, name: v.name, detail: "\(v.language) · \(q)")
            }
    }

    static func defaultVoiceID() -> String {
        let all = voices()
        return (all.first { $0.detail.hasPrefix("en-US") } ?? all.first)?.id ?? ""
    }

    /// Requests run one after another: the synthesizer renders one utterance at a time.
    func generate(text: String, voiceID: String, speed: Double) async throws -> AVAudioPCMBuffer {
        let task: Task<AVAudioPCMBuffer, Error> = lock.withLock {
            let previous = tail
            let task = Task<AVAudioPCMBuffer, Error> {
                await previous?.value
                return try await self.render(text: text, voiceID: voiceID, speed: speed)
            }
            tail = Task { _ = try? await task.value }
            return task
        }
        return try await task.value
    }

    private final class Render: @unchecked Sendable {
        let lock = NSLock()
        var pieces: [AVAudioPCMBuffer] = []
        var done = false
    }

    private func render(text: String, voiceID: String, speed: Double) async throws -> AVAudioPCMBuffer {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AVAudioPCMBuffer, Error>) in
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(identifier: voiceID) ?? AVSpeechSynthesisVoice(language: "en-US")
            let rate = AVSpeechUtteranceDefaultSpeechRate * Float(speed)
            utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, rate))
            let state = Render()
            let finish: (Result<AVAudioPCMBuffer, Error>) -> Void = { result in
                state.lock.lock()
                let already = state.done
                state.done = true
                state.lock.unlock()
                if !already { cont.resume(with: result) }
            }
            synth.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    state.lock.lock()
                    let pieces = state.pieces
                    state.lock.unlock()
                    finish(Result { try Self.join(pieces) })
                    return
                }
                if let c = try? ClipAudio.convert(pcm) {
                    state.lock.lock()
                    state.pieces.append(c)
                    state.lock.unlock()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { finish(.failure(VoiceError.timeout)) }
        }
    }

    private static func join(_ pieces: [AVAudioPCMBuffer]) throws -> AVAudioPCMBuffer {
        let total = pieces.reduce(0) { $0 + Int($1.frameLength) }
        guard total > 0, let out = AVAudioPCMBuffer(pcmFormat: ClipAudio.format, frameCapacity: AVAudioFrameCount(total)),
              let dst = out.floatChannelData?[0] else { throw VoiceError.noAudio }
        var w = 0
        for p in pieces {
            guard let src = p.floatChannelData?[0] else { continue }
            dst.advanced(by: w).update(from: src, count: Int(p.frameLength))
            w += Int(p.frameLength)
        }
        out.frameLength = AVAudioFrameCount(w)
        return out
    }
}
