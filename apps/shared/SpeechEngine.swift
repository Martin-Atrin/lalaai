import AVFoundation
import Foundation
import Speech

/// Streaming transcription events. `volatile` text is the not-yet-final tail and replaces the previous volatile text.
enum TranscriptEvent: Sendable {
    case volatile(String)
    case final(String)
}

/// Pluggable on-device ASR. Default: Apple SpeechAnalyzer (Neural Engine, macOS 26).
/// A Parakeet (FluidAudio/CoreML) engine can conform to the same protocol.
@MainActor
protocol SpeechEngine: AnyObject {
    var onEvent: ((TranscriptEvent) -> Void)? { get set }
    var onLevel: ((Float) -> Void)? { get set }
    func start(locale: Locale, contextualStrings: [String]) async throws
    func stop() async
}

enum SpeechEngineError: LocalizedError {
    case unsupportedLocale(String)
    case noAudioFormat
    case micDenied
    var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let l): return "On-device transcription does not support \(l)"
        case .noAudioFormat: return "No compatible audio format"
        case .micDenied: return "Microphone access denied (System Settings → Privacy → Microphone)"
        }
    }
}

@MainActor
final class AppleSpeechEngine: SpeechEngine {
    var onEvent: ((TranscriptEvent) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onStatus: ((String) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var module: (any SpeechModule)?
    private var resultsTask: Task<Void, Never>?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private let audio = AudioCapture()

    /// Every on-device speech locale: SpeechTranscriber (newest model) plus DictationTranscriber, which covers
    /// many more languages (Thai, Czech, Polish, Russian, Vietnamese, Arabic, Hindi…).
    static func supportedLocales() async -> [Locale] {
        var seen = Set<String>()
        var out: [Locale] = []
        for l in await SpeechTranscriber.supportedLocales + DictationTranscriber.supportedLocales where seen.insert(l.identifier).inserted {
            out.append(l)
        }
        return out
    }

    /// Which engine a locale runs on (shown in Setup).
    static func engineName(for id: String) async -> String {
        await speechTranscriberLocale(for: Locale(identifier: id)) != nil ? "SpeechAnalyzer" : "Dictation"
    }

    func start(locale requested: Locale, contextualStrings: [String]) async throws {
        let fileInput = ProcessInfo.processInfo.environment["LALAAI_AUDIO_FILE"] // demo/test: play a recording instead of the mic
        if fileInput == nil { guard await AVCaptureDevice.requestAccess(for: .audio) else { throw SpeechEngineError.micDenied } }
        // Prefer the newest SpeechTranscriber model; fall back to DictationTranscriber for the languages only it covers.
        let transcriber: any SpeechModule
        let results: AsyncThrowingStream<(String, Bool), Error>
        if let locale = await Self.speechTranscriberLocale(for: requested) {
            let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
            transcriber = t
            results = Self.texts(t.results) { (String($0.text.characters), $0.isFinal) }
        } else if let locale = await Self.pick(requested, from: DictationTranscriber.supportedLocales) {
            let t = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                         reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
            transcriber = t
            results = Self.texts(t.results) { (String($0.text.characters), $0.isFinal) }
        } else {
            throw SpeechEngineError.unsupportedLocale(requested.identifier)
        }
        self.module = transcriber

        // Download the on-device model on first use. Languages outside the preinstalled set must be
        // reserved for this app first, or the download ends in "Not Installing".
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            let loc = (transcriber as? any LocaleDependentSpeechModule)?.selectedLocales.first ?? requested
            if !(await AssetInventory.reservedLocales).contains(loc) {
                // Free a slot if we're at the system limit, then reserve.
                if (await AssetInventory.reservedLocales).count >= AssetInventory.maximumReservedLocales,
                   let oldest = await AssetInventory.reservedLocales.first {
                    _ = await AssetInventory.release(reservedLocale: oldest)
                }
                _ = try? await AssetInventory.reserve(locale: loc)
            }
        }
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onStatus?("Downloading speech model…")
            try await req.downloadAndInstall()
        }
        onStatus?("Listening")

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechEngineError.noAudioFormat
        }
        let context = AnalysisContext()
        if !contextualStrings.isEmpty { context.contextualStrings[.general] = Array(contextualStrings.prefix(100)) }

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(64))
        inputContinuation = cont
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.setContext(context)
        try await analyzer.prepareToAnalyze(in: format)

        resultsTask = Task { [weak self] in
            do {
                for try await (raw, isFinal) in results {
                    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    await MainActor.run {
                        if isFinal { self?.pendingSince = nil }
                        else { self?.maybeForceFinalize(pendingChars: text.count) }
                        if isFinal { if !text.isEmpty { self?.onEvent?(.final(text)) } }
                        else { self?.onEvent?(.volatile(text)) }
                    }
                }
            } catch {
                await MainActor.run { self?.onStatus?("Transcriber stopped: \(error.localizedDescription)") }
            }
        }

        try await analyzer.start(inputSequence: stream)
        let onBuf: @Sendable (AVAudioPCMBuffer) -> Void = { buf in cont.yield(AnalyzerInput(buffer: buf)) }
        let onLvl: @Sendable (Float) -> Void = { [weak self] lvl in Task { @MainActor in self?.onLevel?(lvl) } }
        if let fileInput { try audio.startFile(URL(fileURLWithPath: fileInput), targetFormat: format, onBuffer: onBuf, onLevel: onLvl) }
        else { try audio.start(targetFormat: format, onBuffer: onBuf, onLevel: onLvl) }
    }

    // Continuous speakers (and languages without sentence punctuation, like Thai) can go a long time without
    // a natural final. Force a segment boundary so captions and translations commit in readable chunks.
    private var pendingSince: Date?
    private var forcing = false
    private func maybeForceFinalize(pendingChars: Int) {
        let now = Date()
        if pendingSince == nil { pendingSince = now }
        guard !forcing, let analyzer, pendingChars > 160 || now.timeIntervalSince(pendingSince!) > 12 else { return }
        forcing = true
        pendingSince = nil
        Task {
            try? await analyzer.finalize(through: nil)
            await MainActor.run { self.forcing = false }
        }
    }

    /// `supportedLocale(equivalentTo:)` echoes unsupported locales back (th_TH → th_TH), so match against the real lists.
    static func speechTranscriberLocale(for l: Locale) async -> Locale? {
        pick(l, from: await SpeechTranscriber.supportedLocales)
    }

    /// Exact identifier match first, then same language (e.g. de_AT → de_DE).
    static func pick(_ l: Locale, from list: [Locale]) -> Locale? {
        if let exact = list.first(where: { $0.identifier == l.identifier }) { return exact }
        return list.first { $0.language.languageCode == l.language.languageCode && $0.language.script == l.language.script }
    }

    /// Adapts either transcriber's result sequence to (text, isFinal).
    private static func texts<S: AsyncSequence & Sendable>(_ seq: S, _ map: @escaping @Sendable (S.Element) -> (String, Bool)) -> AsyncThrowingStream<(String, Bool), Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    for try await r in seq { cont.yield(map(r)) }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    func stop() async {
        audio.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        module = nil
        onLevel?(0)
    }
}

/// Mic capture → converted PCM buffers in the analyzer's preferred format.
final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?

    func start(targetFormat: AVAudioFormat, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void, onLevel: @escaping @Sendable (Float) -> Void) throws {
        #if os(iOS)
        // iPhone: record from the mic (or a plugged-in / Bluetooth lav mic) without being ducked.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothHFP, .defaultToSpeaker, .mixWithOthers])
        try session.setActive(true)
        #endif
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: targetFormat)
        converter?.primeMethod = .none
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            guard let self else { return }
            onLevel(Self.rms(buffer))
            if let out = self.convert(buffer, to: targetFormat) { onBuffer(out) }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        fileTimer?.cancel()
        fileTimer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private var fileTimer: DispatchSourceTimer?

    /// Streams an audio file in real time (100ms chunks), as if it were the mic.
    func startFile(_ url: URL, targetFormat: AVAudioFormat, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void, onLevel: @escaping @Sendable (Float) -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        converter = AVAudioConverter(from: fmt, to: targetFormat)
        let chunk = AVAudioFrameCount(fmt.sampleRate / 10)
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        t.schedule(deadline: .now(), repeating: .milliseconds(100))
        t.setEventHandler { [weak self] in
            guard let self, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { return }
            if (try? file.read(into: buf, frameCount: chunk)) == nil || buf.frameLength == 0 {
                file.framePosition = 0 // loop the demo recording
                return
            }
            onLevel(Self.rms(buf))
            if let out = self.convert(buf, to: targetFormat) { onBuffer(out) }
        }
        fileTimer = t
        t.resume()
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return err == nil && out.frameLength > 0 ? out : nil
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        if n == 0 { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-6))
        return max(0, min(1, (db + 55) / 50))
    }
}
