@preconcurrency import AVFoundation
import Foundation
import Observation
#if canImport(SherpaOnnxC)
import SherpaOnnxC
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

    /// Removes Kokoro's high-frequency hiss (mostly 9–12 kHz, stronger in the int8
    /// model) with two cascaded low-pass filters at 8.5 kHz. Speech sits well below.
    static func removeHiss(_ buf: AVAudioPCMBuffer, cutoff: Double = 8500) -> AVAudioPCMBuffer {
        guard let x = buf.floatChannelData?[0], buf.frameLength > 0 else { return buf }
        let n = Int(buf.frameLength)
        let w0 = 2 * Double.pi * cutoff / buf.format.sampleRate
        let alpha = sin(w0) / (2 * 0.7071)
        let a0 = 1 + alpha
        let b0 = (1 - cos(w0)) / 2 / a0, b1 = (1 - cos(w0)) / a0, b2 = b0
        let a1 = -2 * cos(w0) / a0, a2 = (1 - alpha) / a0
        for _ in 0..<2 {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in 0..<n {
                let xi = Double(x[i])
                let yi = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = xi; y2 = y1; y1 = yi
                x[i] = Float(yi)
            }
        }
        return buf
    }
}

@MainActor @Observable
final class VoiceStatus {
    static let shared = VoiceStatus()
    /// The line above the player ("Buffering… 7 s", "Loading the Kokoro voice…", errors).
    var line = ""
}

// MARK: - Kokoro on this iPhone

/// Kokoro v1.0 running on the iPhone's CPU through sherpa-onnx and ONNX Runtime.
/// The CPU (unlike the GPU) keeps working while the screen is locked, so it can
/// keep reading ahead in the background. Text becomes phonemes with the
/// espeak-ng (the model's own phonemizer), in an American or British accent.
final class KokoroEngine: @unchecked Sendable {
    static let shared = KokoroEngine()

    /// The model's English voices, in its speaker order (ids 0–27).
    static let voices = [
        "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore", "af_nicole", "af_nova",
        "af_river", "af_sarah", "af_sky", "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam",
        "am_michael", "am_onyx", "am_puck", "am_santa", "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
        "bm_daniel", "bm_fable", "bm_george", "bm_lewis",
    ]

    static var modelDir: URL? { Bundle.main.url(forResource: "KokoroModel", withExtension: nil) }

    /// Why Kokoro can't run in this build, or nil when it can.
    static var unavailableReason: String? {
        #if canImport(SherpaOnnxC)
        guard let dir = modelDir, FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.onnx").path) else {
            return "The Kokoro voice model isn't in this build. Run ios/Scripts/setup-kokoro.sh, then build again."
        }
        return nil
        #else
        return "The Kokoro voice engine isn't in this build. Run ios/Scripts/setup-kokoro.sh, then build again."
        #endif
    }

    private let lock = NSLock()
    private var accent = ""
    #if canImport(SherpaOnnxC)
    private var tts: OpaquePointer?
    #endif

    var isLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        #if canImport(SherpaOnnxC)
        return tts != nil
        #else
        return false
        #endif
    }

    /// Loads the model (a few seconds). British voices use the British lexicon.
    func prepare(voice: String) throws {
        lock.lock(); defer { lock.unlock() }
        try load(british: voice.hasPrefix("b"))
    }

    /// One sentence of speech. Calls run one at a time.
    func generate(text: String, voice: String, speed: Double) throws -> AVAudioPCMBuffer {
        #if canImport(SherpaOnnxC)
        lock.lock(); defer { lock.unlock() }
        try load(british: voice.hasPrefix("b"))
        let sid = Int32(Self.voices.firstIndex(of: voice) ?? 3)
        guard let audio = SherpaOnnxOfflineTtsGenerate(tts, text, sid, Float(speed)) else { throw VoiceError.noAudio }
        defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
        let n = Int(audio.pointee.n)
        guard n > 0, let samples = audio.pointee.samples,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(audio.pointee.sample_rate), channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
              let dst = buf.floatChannelData?[0] else { throw VoiceError.noAudio }
        dst.update(from: samples, count: n)
        buf.frameLength = AVAudioFrameCount(n)
        return ClipAudio.removeHiss(try ClipAudio.convert(buf))
        #else
        throw VoiceError.unavailable(Self.unavailableReason ?? "")
        #endif
    }

    #if canImport(SherpaOnnxC)
    /// Creates a sherpa-onnx Kokoro engine. `lang` is the espeak-ng accent.
    private static func makeTTS(dir: URL, model: URL, lang: String) -> OpaquePointer? {
        // C strings must stay alive while the engine is created.
        var owned: [UnsafeMutablePointer<CChar>] = []
        func c(_ s: String) -> UnsafePointer<CChar> { let p = strdup(s)!; owned.append(p); return UnsafePointer(p) }
        defer { owned.forEach { free($0) } }
        var config = SherpaOnnxOfflineTtsConfig()
        config.model.kokoro.model = c(model.path)
        config.model.kokoro.voices = c(dir.appendingPathComponent("voices.bin").path)
        config.model.kokoro.tokens = c(dir.appendingPathComponent("tokens.txt").path)
        config.model.kokoro.data_dir = c(dir.appendingPathComponent("espeak-ng-data").path)
        config.model.kokoro.lexicon = c(dir.appendingPathComponent(lang == "en-us" ? "lexicon-us-en.txt" : "lexicon-gb-en.txt").path)
        config.model.kokoro.lang = c(lang)
        config.model.kokoro.dict_dir = c("")
        config.model.kokoro.length_scale = 1
        config.model.num_threads = Int32(max(2, min(4, ProcessInfo.processInfo.activeProcessorCount - 2)))
        config.model.provider = c("cpu")
        config.model.debug = 0
        config.max_num_sentences = 1
        config.silence_scale = 0.2
        return SherpaOnnxCreateOfflineTts(&config)
    }
    #endif

    private func load(british: Bool) throws {
        #if canImport(SherpaOnnxC)
        // espeak-ng voice names: "en-gb" isn't one (it fails to load and every
        // sentence comes back silent); Received Pronunciation is "en-gb-x-rp".
        let key = british ? "en-gb-x-rp" : "en-us"
        if tts != nil && accent == key { return }
        if let old = tts { SherpaOnnxDestroyOfflineTts(old); tts = nil }
        guard Self.unavailableReason == nil, let dir = Self.modelDir else {
            throw VoiceError.unavailable(Self.unavailableReason ?? "")
        }
        tts = Self.makeTTS(dir: dir, model: dir.appendingPathComponent("model.onnx"), lang: key)
        guard tts != nil else { throw VoiceError.unavailable("Kokoro couldn't load its voice model.") }
        accent = key
        #else
        throw VoiceError.unavailable(Self.unavailableReason ?? "")
        #endif
    }
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
