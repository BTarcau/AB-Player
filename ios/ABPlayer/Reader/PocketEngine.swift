@preconcurrency import AVFoundation
import Foundation
import os
import UIKit
#if canImport(SherpaOnnx)
import SherpaOnnx
#endif

/// Kyutai's Pocket TTS (CC BY 4.0) through sherpa-onnx, copying a voice from a
/// short reference clip in the bundle (ios/PocketVoices/, see setup-pocket.sh).
/// Runs on the CPU only: iOS refuses GPU work from background apps, and ONNX
/// Runtime's CPU provider never touches Metal.
final class PocketEngine: @unchecked Sendable {
    static let shared = PocketEngine()

    /// The cloned voices in the bundle, by file name ("andrei").
    static let voices: [String] = {
        guard let dir = bundleDir?.appendingPathComponent("voices"),
              let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return files.filter { $0.hasSuffix(".wav") }.map { ($0 as NSString).deletingPathExtension }.sorted()
    }()

    static var bundleDir: URL? { Bundle.main.url(forResource: "PocketRuntime", withExtension: nil) }

    /// Fixed so a voice sounds the same from one sentence to the next.
    static let seed = 42, temperature = 0.7, steps = 4
    /// CPU threads for ONNX Runtime.
    static let threads = 2
    /// Never anything but the CPU (see above).
    static let provider = "cpu"

    static var unavailableReason: String? {
        #if canImport(SherpaOnnx)
        guard let dir = bundleDir, FileManager.default.fileExists(atPath: dir.appendingPathComponent("lm_main.int8.onnx").path) else {
            return "The Pocket voice model isn't in this build. Run ios/Scripts/setup-pocket.sh, then build again."
        }
        if voices.isEmpty { return "No Pocket voice clip is in this build. Add one to ios/PocketVoices/ and run setup-pocket.sh." }
        return nil
        #else
        return "The Pocket voice engine isn't in this build."
        #endif
    }

    /// Generation is CPU-bound and blocks, so it runs on its own thread, one sentence at a time.
    private let queue = DispatchQueue(label: "lamplight.pocket", qos: .userInitiated)
    #if canImport(SherpaOnnx)
    private var tts: SherpaOnnxOfflineTtsWrapper?
    #endif
    private var references: [String: [Float]] = [:]
    private let lock = NSLock()
    private var loaded = false

    var isLoaded: Bool { lock.withLock { loaded } }

    /// Frees the model (about 270 MB); the next sentence loads it again, which takes a moment.
    func unload() {
        queue.async {
            #if canImport(SherpaOnnx)
            self.tts = nil
            #endif
            self.references = [:]
            self.lock.withLock { self.loaded = false }
        }
    }

    func prepare(voice: String) async throws {
        try await onQueue { try self.loadIfNeeded(voice: voice) }
    }

    /// One sentence of speech at 24 kHz mono, at the narrator's own pace.
    func generate(text: String, voice: String) async throws -> AVAudioPCMBuffer {
        try await onQueue { try self.synthesize(text: text, voice: voice) }
    }

    private func onQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result { try work() }) }
        }
    }

    // Everything below runs on `queue`.

    private func loadIfNeeded(voice: String) throws {
        #if canImport(SherpaOnnx)
        if let reason = Self.unavailableReason { throw VoiceError.unavailable(reason) }
        if references[voice] == nil { references[voice] = try Self.readClip(voice) }
        guard tts == nil, let dir = bundleDir else { return }
        let started = Date()
        assert(Self.provider == "cpu", "Pocket must stay off the GPU")
        let path = { (name: String) in dir.appendingPathComponent(name).path }
        // sherpa-onnx copies the config's strings while creating the engine, so
        // they only need to live until then.
        let made: SherpaOnnxOfflineTtsWrapper = autoreleasepool {
            let pocket = sherpaOnnxOfflineTtsPocketModelConfig(
                lmFlow: path("lm_flow.int8.onnx"), lmMain: path("lm_main.int8.onnx"),
                encoder: path("encoder.onnx"), decoder: path("decoder.int8.onnx"),
                textConditioner: path("text_conditioner.onnx"), vocabJson: path("vocab.json"),
                tokenScoresJson: path("token_scores.json"))
            let model = sherpaOnnxOfflineTtsModelConfig(numThreads: Self.threads, debug: 0, provider: Self.provider, pocket: pocket)
            var config = sherpaOnnxOfflineTtsConfig(model: model)
            return SherpaOnnxOfflineTtsWrapper(config: &config)
        }
        guard made.tts != nil else { throw VoiceError.unavailable("The Pocket voice model couldn't be loaded.") }
        tts = made
        lock.withLock { loaded = true }
        PocketLog.write(String(format: "loaded in %.1f s, memory %.0f MB", Date().timeIntervalSince(started), PocketLog.memoryMB()))
        #endif
    }

    private var bundleDir: URL? { Self.bundleDir }

    /// Pocket rambles on for half a minute when a sentence has quotation marks
    /// around it, so they go, and so do square brackets (apostrophes stay, as plain ones). Nil when there's
    /// nothing to say, like a "* * *" scene break.
    static func speakable(_ text: String) -> String? {
        var t = text.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
        t = t.replacingOccurrences(of: "[\"\u{201C}\u{201D}\u{201E}\u{00AB}\u{00BB}]", with: "", options: .regularExpression)
        // Square brackets trip it up too: footnote marks like [12] go, other
        // bracketed words are read without the brackets.
        t = t.replacingOccurrences(of: "\\[\\s*\\d+\\s*\\]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "[\\[\\]]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        // Single quotes used as quotation marks, not apostrophes inside words.
        t = t.replacingOccurrences(of: "(^|\\s)'|'($|\\s|[.,;:!?])", with: "$1$2", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.rangeOfCharacter(from: .alphanumerics) == nil ? nil : t
    }

    private func synthesize(text rawText: String, voice: String) throws -> AVAudioPCMBuffer {
        #if canImport(SherpaOnnx)
        guard let text = Self.speakable(rawText) else { return ClipAudio.silence(0.4) }
        try loadIfNeeded(voice: voice)
        guard let tts, let reference = references[voice] else { throw VoiceError.noAudio }
        var config = SherpaOnnxGenerationConfigSwift()
        config.referenceAudio = reference
        config.referenceSampleRate = 24_000
        config.numSteps = Self.steps
        // A ceiling on length (12.5 frames a second), well above any real reading
        // of the text, in case the model still doesn't stop.
        let maxFrames = Int(12.5 * (3 + Double(text.count) * 0.15))
        config.extra = ["seed": Self.seed, "temperature": Self.temperature, "max_reference_audio_len": 16.0,
                        "max_frames": maxFrames]
        let wall = Date(), cpu = PocketLog.cpuSeconds()
        let audio = tts.generateWithConfig(text: text, config: config, callback: nil, arg: nil)
        let took = Date().timeIntervalSince(wall), cpuTook = PocketLog.cpuSeconds() - cpu
        let samples = audio.samples
        guard !samples.isEmpty, audio.sampleRate == 24_000,
              let buf = AVAudioPCMBuffer(pcmFormat: ClipAudio.format, frameCapacity: AVAudioFrameCount(samples.count)),
              let dst = buf.floatChannelData?[0] else { throw VoiceError.noAudio }
        samples.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: samples.count) }
        buf.frameLength = AVAudioFrameCount(samples.count)
        let seconds = Double(samples.count) / 24_000
        PocketLog.write(String(format: "sentence %d chars: %.2f s audio in %.2f s (RTF %.2f), CPU %.2f s (CPU RTF %.2f), memory %.0f MB",
                               text.count, seconds, took, took / seconds, cpuTook, cpuTook / seconds, PocketLog.memoryMB())
                        + " | " + text)
        return buf
        #else
        throw VoiceError.unavailable(Self.unavailableReason ?? "")
        #endif
    }

    private static func readClip(_ voice: String) throws -> [Float] {
        guard let url = bundleDir?.appendingPathComponent("voices/\(voice).wav") else { throw VoiceError.noAudio }
        let file = try AVAudioFile(forReading: url)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw VoiceError.noAudio
        }
        try file.read(into: buf)
        let mono = try ClipAudio.convert(buf)
        guard let p = mono.floatChannelData?[0] else { throw VoiceError.noAudio }
        return Array(UnsafeBufferPointer(start: p, count: Int(mono.frameLength)))
    }
}

/// Measurements for test runs (debug builds launched with -pocketSpike): a line
/// per event in Library/Caches/pocket-spike.log and the system log.
enum PocketLog {
    private static let logger = Logger(subsystem: "com.bentarcau.lamplight", category: "pocket")
    private static let lock = NSLock()
    static var url: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("pocket-spike.log")
    }

    static func write(_ message: String) {
        guard ReaderPlayer.spikeRun else { return }
        let at = Date()
        DispatchQueue.main.async {
            let state = MainActor.assumeIsolated { UIApplication.shared.applicationState == .background ? "bg" : "fg" }
            append(message, at: at, state: state)
        }
    }

    private static func append(_ message: String, at: Date, state: String) {
        let thermal = ["nominal", "fair", "serious", "critical"][ProcessInfo.processInfo.thermalState.rawValue]
        let line = "\(ISO8601DateFormatter().string(from: at)) [\(state), \(thermal)] \(message)\n"
        logger.info("\(line, privacy: .public)")
        lock.withLock {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    static func cpuSeconds() -> Double { Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)) / 1e9 }

    /// The memory iOS counts against the app (what Xcode's gauge shows).
    static func memoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
