import Foundation
import Observation
import UIKit

/// iPhone presenter settings (persisted).
struct PhoneConfig: Codable, Equatable {
    var relayURL = ""
    var presenterName = UIDevice.current.name
    var title = "My talk"
    var slug = ""
    var presenterLocale = Locale.current.identifier.split(separator: "@").first.map(String.init) ?? "en_US"
    var targetLangs: [String] = ["th", "en", "zh", "ja"]
    var tokens: [String: String] = [:]
    var additiveCaptions = false
    var captionLang = ""

    var presenterLang: String { Lang.fromSpeechLocale(presenterLocale) }

    private static let key = "lalaai.phone.config.v1"
    static func load() -> PhoneConfig {
        guard let d = UserDefaults.standard.data(forKey: key), var c = try? JSONDecoder().decode(PhoneConfig.self, from: d) else { return PhoneConfig() }
        c.relayURL = Relay.migrated(c.relayURL, fallback: "")
        return c
    }
    func save() { if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) } }
}

struct CaptionLine: Identifiable, Equatable {
    let id: Int
    var text: String
    var final: Bool
    var translations: [String: String] = [:]
}

/// iPhone presenter: mic → on-device speech → on-device translation → relay; Q&A moderation.
/// Same wire protocol and shared engines as the Mac app (apps/shared). No AI icebreaker agent on iOS:
/// rooms are created without an LLM, so attendees get the relay's localized icebreakers.
@MainActor
@Observable
final class PhoneModel {
    var config = PhoneConfig.load() { didSet { if config != oldValue { config.save() } } }

    var room: RoomInfo?
    var joinURL: String?
    var relayState: RelayClient.State = .disconnected
    var isStarting = false
    var isTranscribing = false
    var level: Float = 0
    var status = "Ready"
    var lastError: String?
    var attendees = 0

    var lines: [CaptionLine] = []
    var questions: [QuestionFull] = []
    var translationLangs: [String] = []
    var speechLocales: [Locale] = []
    /// Apple language packs this iPhone still needs (e.g. pl→en). Without them translation silently falls back
    /// to the original text, so the presenter would only see untranslated questions.
    var missingPairs: [(String, String)] = []
    var downloadingPairs = false

    @ObservationIgnored private var relay: RelayClient?
    @ObservationIgnored private let translator = Translator()
    @ObservationIgnored private var engine: AppleSpeechEngine?
    @ObservationIgnored private var segId = Int(Date().timeIntervalSince1970) * 100
    @ObservationIgnored private var finalized: Set<Int> = []
    @ObservationIgnored private var partialInFlight = false
    @ObservationIgnored private var lastPartialAt = Date.distantPast
    @ObservationIgnored private var pendingPartial: String?

    var isLive: Bool { room != nil }
    var roomLangs: [String] { room?.languages ?? ([config.presenterLang] + config.targetLangs) }
    var sortedQuestions: [QuestionFull] {
        questions.filter { !$0.hidden }.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            if $0.answered != $1.answered { return !$0.answered }
            return $0.likes == $1.likes ? $0.createdAt > $1.createdAt : $0.likes > $1.likes
        }
    }

    init() {
        if config.slug.isEmpty { config.slug = Self.localSlug() }
        Task {
            let apple = await Lang.translationLanguages()
            translator.appleLangs = Set(apple)
            translationLangs = apple
            speechLocales = await AppleSpeechEngine.supportedLocales().sorted { $0.identifier < $1.identifier }
            await refreshMissingPairs()
        }
    }

    func refreshMissingPairs() async {
        var missing: [(String, String)] = []
        let src = config.presenterLang
        for t in Set(config.targetLangs + (room?.languages ?? [])) where t != src {
            if await translator.status(from: src, to: t) == .needsDownload { missing.append((src, t)) }
            if await translator.status(from: t, to: src) == .needsDownload { missing.append((t, src)) }
        }
        missingPairs = missing
    }

    func pairsDownloaded() {
        downloadingPairs = false
        translator.reset()
        Task {
            await refreshMissingPairs()
            questions.forEach(translateIfNeeded) // translate anything that arrived before the packs existed
        }
    }

    static func localSlug() -> String {
        let a = ["cosmic", "sunny", "brave", "curious", "lucky", "nimble", "witty", "zesty", "breezy", "golden"]
        let n = ["otter", "falcon", "panda", "lynx", "heron", "gecko", "comet", "pixel", "maple", "puffin"]
        return "\(a.randomElement()!)-\(n.randomElement()!)-\(Int.random(in: 10...99))"
    }

    func randomizeSlug() async {
        config.slug = await RelayClient.randomName(baseURL: config.relayURL) ?? Self.localSlug()
    }

    // MARK: session

    func goLive() async {
        guard !isStarting else { return }
        isStarting = true
        lastError = nil
        defer { isStarting = false }
        guard !config.relayURL.trimmingCharacters(in: .whitespaces).isEmpty else {
            lastError = "Enter your relay's address first. La Laai doesn't run a relay for you: see “How to run your own relay”."
            return
        }
        do {
            let client = try RelayClient(baseURL: config.relayURL)
            let slug = config.slug.lowercased().trimmingCharacters(in: .whitespaces)
            let resp = try await client.createRoom(.init(
                slug: slug, title: config.title, presenterName: config.presenterName,
                presenterLang: config.presenterLang, languages: config.targetLangs,
                llmEnabled: false, presenterToken: config.tokens[slug]))
            config.tokens[slug] = resp.presenterToken
            room = resp.room
            joinURL = "\(config.relayURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")))/m/\(slug)"
            client.onState = { [weak self] s in self?.relayState = s }
            client.onMessage = { [weak self] m in self?.handle(m) }
            client.connect(slug: slug, token: resp.presenterToken)
            relay = client
            UIApplication.shared.isIdleTimerDisabled = true // keep capturing while you talk
            await startMic()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func end() async {
        await stopMic()
        relay?.disconnect()
        relay = nil
        room = nil
        joinURL = nil
        questions = []
        UIApplication.shared.isIdleTimerDisabled = false
        status = "Ready"
    }

    func toggleMic() async { if isTranscribing { await stopMic() } else { await startMic() } }

    private func startMic() async {
        guard !isTranscribing else { return }
        let e = AppleSpeechEngine()
        e.onStatus = { [weak self] s in self?.status = s }
        e.onLevel = { [weak self] l in self?.level = l }
        e.onEvent = { [weak self] ev in self?.onTranscript(ev) }
        engine = e
        status = "Starting mic…"
        do {
            try await e.start(locale: Locale(identifier: config.presenterLocale), contextualStrings: [])
            isTranscribing = true
            status = "Listening"
        } catch {
            engine = nil
            lastError = error.localizedDescription
            status = "Mic stopped"
        }
    }

    private func stopMic() async {
        await engine?.stop()
        engine = nil
        isTranscribing = false
        level = 0
        status = isLive ? "Paused" : "Ready"
    }

    // MARK: transcript → translations → relay

    private func onTranscript(_ ev: TranscriptEvent) {
        switch ev {
        case .volatile(let text):
            upsert(id: segId, text: text, final: false)
            pendingPartial = text
            pumpPartial()
        case .final(let text):
            let id = segId
            segId += 1
            finalized.insert(id)
            pendingPartial = nil
            upsert(id: id, text: text, final: true)
            let src = config.presenterLang, targets = roomLangs
            Task {
                let texts = await translator.translateAll(text, from: src, to: targets)
                if let i = lines.firstIndex(where: { $0.id == id }) { lines[i].translations = texts }
                relay?.send(.segment(id: id, final: true, source: text, texts: texts))
            }
        }
    }

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
        let id = segId, src = config.presenterLang, targets = roomLangs
        relay?.send(.segment(id: id, final: false, source: text, texts: [:]))
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

    private func upsert(id: Int, text: String, final: Bool) {
        if let i = lines.lastIndex(where: { $0.id == id }) {
            lines[i].text = text
            lines[i].final = final
        } else if !text.isEmpty {
            lines.append(CaptionLine(id: id, text: text, final: final))
            if lines.count > 300 { lines.removeFirst(lines.count - 300) }
        }
    }

    func captionText(_ l: CaptionLine) -> String {
        let lang = config.captionLang
        return lang.isEmpty || lang == config.presenterLang ? l.text : (l.translations[lang] ?? l.text)
    }

    // MARK: relay messages & Q&A

    private func handle(_ m: RelayMessage) {
        switch m {
        case let .welcome(room, qs, pending):
            self.room = room
            questions = qs
            qs.forEach(translateIfNeeded)
            for j in pending { relay?.send(.icebreakersResult(matchId: j.matchId, icebreakers: [:], error: "no agent on iOS")) }
        case .roomUpdate(let r): room = r
        case .questionNew(let q):
            upsertQuestion(q)
            translateIfNeeded(q)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .questionState(let q): upsertQuestion(q)
        case .questionRemove(let id): questions.removeAll { $0.id == id }
        case .icebreakersNeeded(let job):
            relay?.send(.icebreakersResult(matchId: job.matchId, icebreakers: [:], error: "no agent on iOS"))
        case let .stats(n, _): attendees = n
        case .error(let msg): lastError = msg
        case .other: break
        }
    }

    private func upsertQuestion(_ q: QuestionFull) {
        if let i = questions.firstIndex(where: { $0.id == q.id }) { questions[i] = q } else { questions.append(q) }
    }

    private func translateIfNeeded(_ q: QuestionFull) {
        let missing = roomLangs.filter { $0 != q.originalLang && q.texts[$0] == nil }
        guard !missing.isEmpty else { return }
        Task {
            let texts = await translator.translateAll(q.original, from: q.originalLang, to: missing)
            if !texts.isEmpty { relay?.send(.questionTranslations(id: q.id, texts: texts)) }
        }
    }

    func moderate(_ q: QuestionFull, answered: Bool? = nil, pinned: Bool? = nil, hidden: Bool? = nil) {
        relay?.send(.questionModerate(id: q.id, answered: answered, pinned: pinned, hidden: hidden))
    }
}
