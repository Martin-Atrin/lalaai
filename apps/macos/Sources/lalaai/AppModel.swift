import AppKit
import Carbon.HIToolbox
import Foundation
import Observation

struct TranscriptLine: Identifiable, Equatable {
    let id: Int
    var text: String
    var final: Bool
    var translations: [String: String] = [:]
}

enum JobState: Equatable { case running, done(String), failed(String) }

/// Central state + orchestration: mic → ASR → translation → relay; Q&A; icebreaker agent via MCP.
@MainActor
@Observable
final class AppModel: MCPContext {
    var config = Config.load() {
        didSet {
            if persistConfig, config != oldValue { config.save() }
            if config.panelsAboveFullscreen != oldValue.panelsAboveFullscreen { panels.applyLevel() }
            if config.targetLangs != oldValue.targetLangs || config.presenterLocale != oldValue.presenterLocale { ensureExtended() }
        }
    }
    /// Env overrides (tests/demos) are session-only and must never overwrite the presenter's saved settings.
    @ObservationIgnored private var persistConfig = !ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("LALAAI_") && $0 != "LALAAI_NO_MIC" && $0 != "LALAAI_DEBUG_WINDOWS" }

    // session
    var room: RoomInfo?
    var joinURL: String?
    var relayState: RelayClient.State = .disconnected
    var isStarting = false
    var isTranscribing = false
    var level: Float = 0
    var status = "Idle"
    var lastError: String? { didSet { if let lastError { FileHandle.standardError.write("lalaai error: \(lastError)\n".data(using: .utf8)!) } } }
    var attendees = 0
    var byLang: [String: Int] = [:]

    // content
    var lines: [TranscriptLine] = []
    var questions: [QuestionFull] = []
    var jobs: [String: IcebreakerJob] = [:]
    var jobStates: [String: JobState] = [:]
    var presentation: Presentation?
    var llmCheck: String?
    var llmCheckOK: Bool?
    var llmTesting = false
    /// Outcome of the most recent icebreaker agent run, shown in the AI card.
    var lastAgentResult: (ok: Bool, text: String)?
    @ObservationIgnored private var toolCalls = 0
    /// Floating panels currently on screen (kept by PanelManager so SwiftUI can observe it).
    var openPanels: Set<String> = []

    // capabilities
    var translationLangs: [String] = []
    /// Apple's own languages vs. the extra ones handled by the on-device NLLB helper.
    var appleLangs: Set<String> = []
    var extendedLangs: Set<String> = []
    let extended = ExtendedTranslator()
    var speechLocales: [Locale] = []
    var missingPairs: [(String, String)] = []
    var downloadingPairs = false

    @ObservationIgnored private var relay: RelayClient?
    @ObservationIgnored private let translator = Translator()
    @ObservationIgnored private var engine: SpeechEngine?
    @ObservationIgnored private var mcp: MCPServer?
    @ObservationIgnored private var segId = Int(Date().timeIntervalSince1970) * 100
    @ObservationIgnored private var finalized: Set<Int> = []
    @ObservationIgnored private var partialInFlight = false
    @ObservationIgnored private var lastPartialAt = Date.distantPast
    @ObservationIgnored private var pendingPartial: String?
    @ObservationIgnored private var runningAgents = 0
    @ObservationIgnored private var agentQueue: [IcebreakerJob] = []
    @ObservationIgnored let panels = PanelManager()
    @ObservationIgnored private let hotKeys = HotKeys()
    /// macOS hid our menu-bar icon (typically behind the notch on a crowded menu bar).
    var menuBarIconHidden = false

    var isLive: Bool { room != nil }
    var roomLangs: [String] { room?.languages ?? ([config.presenterLang] + config.targetLangs) }
    var llmEnabled: Bool { config.llmProvider != .none }
    var sortedQuestions: [QuestionFull] {
        questions.filter { !$0.hidden }.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            if $0.answered != $1.answered { return !$0.answered }
            return $0.likes == $1.likes ? $0.createdAt > $1.createdAt : $0.likes > $1.likes
        }
    }
    var pinnedQuestion: QuestionFull? { questions.first { $0.pinned && !$0.hidden } }
    var matchCount: Int { jobs.count }

    /// Caption text for a line in the caption window's chosen language (falls back to the original).
    func captionText(_ l: TranscriptLine) -> String {
        let lang = config.captionLang
        return lang.isEmpty || lang == config.presenterLang ? l.text : (l.translations[lang] ?? l.text)
    }

    init() {
        if config.slug.isEmpty { config.slug = Self.localSlug() }
        if config.relayURL == "http://localhost:8787", let ip = Lang.lanIP() { config.relayURL = "http://\(ip):8787" }
        config.applyEnvironment()
        panels.model = self
        // Resolve the login-shell PATH off the main thread before anything needs it (agent CLIs, uv).
        DispatchQueue.global(qos: .userInitiated).async { _ = AgentRunner.loginPath }
        startMCP()
        if !CommandLine.arguments.contains("--autolive") { hotKeys.register([
            (kVK_ANSI_M, { [weak self] in Task { await self?.toggleTranscription() } }),
            (kVK_ANSI_Q, { [weak self] in self?.panels.toggle("qr") }),
            (kVK_ANSI_A, { [weak self] in self?.panels.toggle("qa") }),
            (kVK_ANSI_C, { [weak self] in self?.panels.toggle("captions") }),
        ]) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.checkMenuBarIcon() }
        // Capability probes talk to system daemons and can be slow; never let them block going live.
        Task { await loadCapabilities() }
        if CommandLine.arguments.contains("--autolive") { Task { await goLive() } }
    }

    // MARK: capabilities

    func loadCapabilities() async {
        trace("capabilities: start")
        defer { trace("capabilities: done (\(translationLangs.count) translation langs, \(speechLocales.count) speech locales)") }
        let apple = await Lang.translationLanguages()
        appleLangs = Set(apple)
        let appleBases = Set(apple.map(Lang.base))
        extendedLangs = Set(Lang.nllbLanguages.filter { !appleLangs.contains($0) && !appleBases.contains(Lang.base($0)) })
        translator.appleLangs = appleLangs
        translator.fallback = { [weak extended] text, from, to in await extended?.translate(text, from: from, to: to) }
        translationLangs = (apple + extendedLangs).sorted { Lang.displayName($0) < Lang.displayName($1) }
        ensureExtended()
        speechLocales = await AppleSpeechEngine.supportedLocales().sorted { $0.identifier < $1.identifier }
        await refreshMissingPairs()
    }

    /// The status item exists but macOS may park it under the notch when the menu bar is full.
    func checkMenuBarIcon() {
        guard let item = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("StatusBar") }),
              let screen = item.screen ?? NSScreen.main else { menuBarIconHidden = true; return }
        let f = item.frame
        var hidden = !item.isVisible || !item.occlusionState.contains(.visible)
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           f.midX > left.maxX, f.midX < right.minX { hidden = true } // inside the notch gap
        menuBarIconHidden = hidden
        trace("menu bar icon at x=\(Int(f.midX)) hidden=\(hidden)")
    }

    /// Start the NLLB helper only when a chosen language needs it.
    func ensureExtended() {
        let needed = (config.targetLangs + [config.presenterLang]).contains { extendedLangs.contains($0) }
        if needed { extended.startIfNeeded() }
    }

    func refreshMissingPairs() async {
        var missing: [(String, String)] = []
        let src = config.presenterLang
        for t in config.targetLangs where t != src {
            if await translator.status(from: src, to: t) == .needsDownload { missing.append((src, t)) }
            if await translator.status(from: t, to: src) == .needsDownload { missing.append((t, src)) }
        }
        missingPairs = missing
    }

    func pairsDownloaded() {
        downloadingPairs = false
        translator.reset()
        Task { await refreshMissingPairs() }
    }

    func trace(_ s: String) { FileHandle.standardError.write("lalaai: \(s)\n".data(using: .utf8)!) }

    // MARK: MCP

    func startMCP() {
        mcp?.stop()
        let s = MCPServer(port: config.mcpPort)
        s.context = self
        do { try s.start(); mcp = s } catch { lastError = "MCP server: \(error.localizedDescription)" }
    }
    var mcpURL: String { "http://127.0.0.1:\(config.mcpPort)/mcp" }

    /// Real test: the agent must call a La Laai MCP tool (we count the call on our side) and answer.
    func checkLLM() async {
        llmTesting = true
        llmCheckOK = nil
        llmCheck = "Asking \(config.llmProvider.label) to call La Laai's tools… (10–40 s)"
        defer { llmTesting = false }
        let before = toolCalls
        let r = await AgentRunner(provider: config.llmProvider, mcpURL: mcpURL, model: config.llmModel,
                                  customCommand: config.customCommand).probe()
        switch r {
        case .success(let secs) where toolCalls > before:
            llmCheckOK = true
            llmCheck = "Works: \(config.llmProvider.label) read your talk through MCP in \(Int(secs.rounded())) s."
        case .success:
            llmCheckOK = false
            llmCheck = "The agent replied but never called La Laai's tools."
        case .failure(let e):
            llmCheckOK = false
            llmCheck = e.localizedDescription
        }
    }

    // MARK: session lifecycle

    static func localSlug() -> String {
        let a = ["cosmic", "sunny", "brave", "curious", "lucky", "nimble", "witty", "zesty", "breezy", "golden"]
        let n = ["otter", "falcon", "panda", "lynx", "heron", "gecko", "comet", "pixel", "maple", "puffin"]
        return "\(a.randomElement()!)-\(n.randomElement()!)-\(Int.random(in: 10...99))"
    }

    func randomizeSlug() async {
        config.slug = await RelayClient.randomName(baseURL: config.relayURL) ?? Self.localSlug()
    }

    func goLive() async {
        guard !isStarting else { return }
        isStarting = true
        lastError = nil
        trace("goLive: \(config.slug) via \(config.relayURL)")
        defer { isStarting = false }
        do {
            let client = try RelayClient(baseURL: config.relayURL)
            let slug = config.slug.lowercased().trimmingCharacters(in: .whitespaces)
            let resp = try await client.createRoom(.init(
                slug: slug, title: config.title, presenterName: config.presenterName,
                presenterLang: config.presenterLang, languages: config.targetLangs,
                llmEnabled: llmEnabled, presenterToken: config.tokens[slug]))
            config.tokens[slug] = resp.presenterToken
            room = resp.room
            // QR must use the address phones can reach (what the presenter configured), not our loopback.
            let publicBase = config.relayURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            joinURL = "\(publicBase)/m/\(slug)"
            client.onState = { [weak self] s in self?.relayState = s }
            client.onMessage = { [weak self] m in self?.handle(m) }
            client.connect(slug: slug, token: resp.presenterToken)
            relay = client
            trace("goLive: room created, join \(joinURL ?? "")")
            panels.showQR()
            if ProcessInfo.processInfo.environment["LALAAI_NO_MIC"] == nil { await startTranscription() }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func endSession() async {
        await stopTranscription()
        relay?.disconnect()
        relay = nil
        room = nil
        joinURL = nil
        questions = []
        jobs = [:]
        panels.closeAll()
        status = "Idle"
    }

    /// Push language/LLM changes to a live room.
    func pushRoomConfig() {
        relay?.send(.roomConfig(title: config.title, presenterName: config.presenterName, presenterLang: config.presenterLang,
                                languages: config.targetLangs, llmEnabled: llmEnabled))
    }

    // MARK: transcription

    func toggleTranscription() async {
        if isTranscribing { await stopTranscription() } else { await startTranscription() }
    }

    func startTranscription() async {
        guard !isTranscribing else { return }
        let e = AppleSpeechEngine()
        e.onStatus = { [weak self] s in self?.status = s }
        e.onLevel = { [weak self] l in self?.level = l }
        e.onEvent = { [weak self] ev in self?.onTranscript(ev) }
        engine = e
        status = "Starting mic…"
        do {
            try await e.start(locale: Locale(identifier: config.presenterLocale), contextualStrings: presentation?.keywords ?? [])
            isTranscribing = true
            status = "Listening"
        } catch {
            engine = nil
            lastError = error.localizedDescription
            status = "Mic stopped"
        }
    }

    func stopTranscription() async {
        await engine?.stop()
        engine = nil
        isTranscribing = false
        level = 0
        status = isLive ? "Paused" : "Idle"
    }

    private func onTranscript(_ ev: TranscriptEvent) {
        switch ev {
        case .volatile(let text):
            upsertLine(id: segId, text: text, final: false)
            pendingPartial = text
            pumpPartial()
        case .final(let text):
            let id = segId
            segId += 1
            finalized.insert(id)
            pendingPartial = nil
            upsertLine(id: id, text: text, final: true)
            let src = config.presenterLang
            let targets = roomLangs
            Task {
                let texts = await translator.translateAll(text, from: src, to: targets)
                if let i = lines.firstIndex(where: { $0.id == id }) { lines[i].translations = texts }
                relay?.send(.segment(id: id, final: true, source: text, texts: texts))
            }
        }
    }

    /// Partials are translated at most every ~450ms (latest wins) so the audience sees live text in their language.
    private func pumpPartial() {
        guard !partialInFlight, let text = pendingPartial, !text.isEmpty else { return }
        let wait = 0.45 - Date().timeIntervalSince(lastPartialAt)
        if wait > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.pumpPartial() }
            return
        }
        partialInFlight = true
        pendingPartial = nil
        lastPartialAt = Date()
        let id = segId
        let src = config.presenterLang
        let targets = roomLangs
        relay?.send(.segment(id: id, final: false, source: text, texts: [:])) // presenter-lang viewers get it instantly
        Task {
            let texts = await translator.translateAll(text, from: src, to: targets)
            partialInFlight = false
            if !finalized.contains(id) {
                relay?.send(.segment(id: id, final: false, source: text, texts: texts))
                if let i = lines.lastIndex(where: { $0.id == id }), !lines[i].final { lines[i].translations = texts }
            }
            pumpPartial()
        }
    }

    private func upsertLine(id: Int, text: String, final: Bool) {
        if let i = lines.lastIndex(where: { $0.id == id }) {
            lines[i].text = text
            lines[i].final = final
        } else if !text.isEmpty {
            lines.append(TranscriptLine(id: id, text: text, final: final))
            if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        }
    }

    // MARK: relay messages

    private func handle(_ m: RelayMessage) {
        switch m {
        case let .welcome(room, qs, pending):
            self.room = room
            questions = qs
            for q in qs { translateIfNeeded(q) }
            for j in pending { enqueueJob(j) }
        case .roomUpdate(let r):
            room = r
        case .questionNew(let q):
            upsertQuestion(q)
            translateIfNeeded(q)
            NSSound(named: "Pop")?.play()
        case .questionState(let q):
            upsertQuestion(q)
        case .questionRemove(let id):
            questions.removeAll { $0.id == id }
        case .icebreakersNeeded(let job):
            enqueueJob(job)
        case let .stats(n, by):
            attendees = n
            byLang = by
        case .error(let msg):
            lastError = msg
        case .other:
            break
        }
    }

    private func upsertQuestion(_ q: QuestionFull) {
        if let i = questions.firstIndex(where: { $0.id == q.id }) { questions[i] = q } else { questions.append(q) }
    }

    private func translateIfNeeded(_ q: QuestionFull) {
        let missing = roomLangs.filter { $0 != q.originalLang && q.texts[$0] == nil }
        guard !missing.isEmpty else { return }
        Task {
            var texts = await translator.translateAll(q.original, from: q.originalLang, to: missing)
            // pivot through the presenter language for pairs the system can't do directly
            let still = missing.filter { texts[$0] == nil }
            if !still.isEmpty, let pivot = texts[config.presenterLang] {
                for l in still { if let t = await translator.translate(pivot, from: config.presenterLang, to: l) { texts[l] = t } }
            }
            if !texts.isEmpty { relay?.send(.questionTranslations(id: q.id, texts: texts)) }
        }
    }

    func moderate(_ q: QuestionFull, answered: Bool? = nil, pinned: Bool? = nil, hidden: Bool? = nil) {
        relay?.send(.questionModerate(id: q.id, answered: answered, pinned: pinned, hidden: hidden))
    }

    // MARK: icebreakers

    private func enqueueJob(_ job: IcebreakerJob) {
        guard jobs[job.matchId] == nil else { return }
        jobs[job.matchId] = job
        guard llmEnabled else {
            relay?.send(.icebreakersResult(matchId: job.matchId, icebreakers: [:], error: "llm disabled"))
            return
        }
        agentQueue.append(job)
        drainAgents()
    }

    private func drainAgents() {
        while runningAgents < 2, !agentQueue.isEmpty {
            let job = agentQueue.removeFirst()
            runningAgents += 1
            jobStates[job.matchId] = .running
            let runner = AgentRunner(provider: config.llmProvider, mcpURL: mcpURL, model: config.llmModel, customCommand: config.customCommand)
            Task {
                do {
                    let parsed = try await runner.run(job: job)
                    if case .running = jobStates[job.matchId] {
                        if parsed.isEmpty {
                            jobStates[job.matchId] = .failed("agent returned nothing")
                            lastAgentResult = (false, "The agent finished without submitting icebreakers.")
                            relay?.send(.icebreakersResult(matchId: job.matchId, icebreakers: [:], error: "empty"))
                        } else {
                            _ = await deliver(job: job, byLang: parsed, via: "stdout")
                        }
                    }
                } catch {
                    jobStates[job.matchId] = .failed(error.localizedDescription)
                    lastAgentResult = (false, error.localizedDescription)
                    trace("agent failed: \(error.localizedDescription)")
                    relay?.send(.icebreakersResult(matchId: job.matchId, icebreakers: [:], error: error.localizedDescription))
                }
                runningAgents -= 1
                drainAgents()
            }
        }
    }

    /// Fills languages the agent skipped with on-device translation, then sends to the relay.
    private func deliver(job: IcebreakerJob, byLang: [String: [Icebreaker]], via: String) async -> String {
        var out: [String: [Icebreaker]] = [:]
        for (k, v) in byLang where !v.isEmpty { out[Lang.norm(k)] = v }
        let srcLang: String? = out[config.presenterLang] != nil ? config.presenterLang : (out["en"] != nil ? "en" : out.keys.sorted().first)
        guard let srcLang, let source = out[srcLang] else { return "No icebreakers found; send icebreakers_by_lang as {lang: [{topic, prompt}]}." }
        for l in job.langs where out[l] == nil {
            var list: [Icebreaker] = []
            for ib in source {
                let topic = await translator.translate(ib.topic, from: srcLang, to: l) ?? ib.topic
                let prompt = await translator.translate(ib.prompt, from: srcLang, to: l) ?? ib.prompt
                list.append(Icebreaker(topic: topic, prompt: prompt))
            }
            out[l] = list
        }
        relay?.send(.icebreakersResult(matchId: job.matchId, icebreakers: out, error: nil))
        jobStates[job.matchId] = .done(via)
        lastAgentResult = (true, "Icebreakers delivered to \(job.people.map(\.name).joined(separator: " & ")).")
        return "Delivered icebreakers in \(out.keys.sorted().joined(separator: ", ")) to \(job.people.map(\.name).joined(separator: " & "))."
    }

    // MARK: MCPContext

    func mcpPresentation() -> [String: Any] {
        toolCalls += 1
        return [
            "talk_title": config.title,
            "presenter": config.presenterName,
            "file": presentation?.fileName ?? NSNull(),
            "slides": (presentation?.slides ?? []).enumerated().map { ["slide": $0.offset + 1, "text": String($0.element.prefix(1500))] },
            "note": presentation == nil ? "No deck loaded; rely on the transcript." : "",
        ]
    }

    func mcpTranscript(lastN: Int) -> [String: Any] {
        let finals = lines.filter(\.final).suffix(max(1, min(lastN, 400)))
        return ["language": config.presenterLang, "lines": finals.map(\.text)]
    }

    func mcpQuestions() -> [String: Any] {
        ["questions": sortedQuestions.map {
            ["id": $0.id, "text": $0.text(in: config.presenterLang), "original": $0.original, "original_lang": $0.originalLang,
             "likes": $0.likes, "answered": $0.answered, "author": $0.authorLabel] as [String: Any]
        }]
    }

    private func jobDict(_ j: IcebreakerJob) -> [String: Any] {
        let q = questions.first { $0.id == j.question.id }
        return [
            "match_id": j.matchId,
            "shared_question": ["text": j.question.text, "language": j.question.lang,
                                "in_presenter_language": q?.text(in: config.presenterLang) ?? j.question.presenterText ?? j.question.text,
                                "likes": q?.likes ?? 0] as [String: Any],
            "people": j.people.map { ["name": $0.name, "language": $0.lang, "tagline": $0.tagline ?? ""] },
            "write_icebreakers_in": j.langs,
        ]
    }

    func mcpPendingJobs() -> [[String: Any]] {
        jobs.values.filter { if case .done = jobStates[$0.matchId] { return false } else { return true } }.map(jobDict)
    }

    func mcpJob(matchId: String) -> [String: Any]? { jobs[matchId].map(jobDict) }

    func mcpSubmitIcebreakers(matchId: String, byLang: [String: [Icebreaker]]) async -> String {
        guard let job = jobs[matchId] else { return "unknown match_id" }
        if case .done = jobStates[matchId] { return "already delivered" }
        return await deliver(job: job, byLang: byLang, via: "mcp")
    }
}
