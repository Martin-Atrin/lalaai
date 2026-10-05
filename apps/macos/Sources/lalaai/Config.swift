import Foundation
import Translation

struct Config: Codable, Equatable {
    var relayURL = "http://localhost:8787"
    var presenterName = NSFullUserName()
    var title = "My talk"
    var slug = ""
    /// Speech locale identifier, e.g. "en_US". The relay uses its base language ("en").
    var presenterLocale = Config.cleanLocale(Locale.current.identifier)
    var targetLangs: [String] = ["th", "zh", "ja"]
    var llmProvider: LLMProvider = .none
    var llmModel = ""
    var customCommand = ""
    var mcpPort: UInt16 = 8799
    // Floating windows
    var captionMode: CaptionMode = .live
    var panelStyle: PanelStyle = .glass
    /// "" = presenter language; otherwise a target language code
    var captionLang = ""
    var captionFontSize: Double = 34
    var qaFontSize: Double = 16
    /// Keep QR / Q&A / captions above fullscreen slideshows (Keynote, PowerPoint, Google Slides in fullscreen).
    var panelsAboveFullscreen = true
    /// presenter tokens per slug so a restarted app can re-claim its room
    var tokens: [String: String] = [:]

    var presenterLang: String { Lang.fromSpeechLocale(presenterLocale) }

    init() {}

    /// "en_US@rg=skzzzz" (region override) → "en_US", so it matches the speech locale list.
    static func cleanLocale(_ id: String) -> String { String(id.split(separator: "@").first ?? Substring(id)) }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        relayURL = Relay.migrated((try? c.decode(String.self, forKey: .relayURL)) ?? d.relayURL, fallback: d.relayURL)
        presenterName = (try? c.decode(String.self, forKey: .presenterName)) ?? d.presenterName
        title = (try? c.decode(String.self, forKey: .title)) ?? d.title
        slug = (try? c.decode(String.self, forKey: .slug)) ?? d.slug
        presenterLocale = Config.cleanLocale((try? c.decode(String.self, forKey: .presenterLocale)) ?? d.presenterLocale)
        targetLangs = (try? c.decode([String].self, forKey: .targetLangs)) ?? d.targetLangs
        llmProvider = (try? c.decode(LLMProvider.self, forKey: .llmProvider)) ?? d.llmProvider
        llmModel = (try? c.decode(String.self, forKey: .llmModel)) ?? d.llmModel
        customCommand = (try? c.decode(String.self, forKey: .customCommand)) ?? d.customCommand
        mcpPort = (try? c.decode(UInt16.self, forKey: .mcpPort)) ?? d.mcpPort
        tokens = (try? c.decode([String: String].self, forKey: .tokens)) ?? d.tokens
        captionMode = (try? c.decode(CaptionMode.self, forKey: .captionMode)) ?? d.captionMode
        panelStyle = (try? c.decode(PanelStyle.self, forKey: .panelStyle)) ?? d.panelStyle
        captionLang = (try? c.decode(String.self, forKey: .captionLang)) ?? d.captionLang
        captionFontSize = (try? c.decode(Double.self, forKey: .captionFontSize)) ?? d.captionFontSize
        qaFontSize = (try? c.decode(Double.self, forKey: .qaFontSize)) ?? d.qaFontSize
        panelsAboveFullscreen = (try? c.decode(Bool.self, forKey: .panelsAboveFullscreen)) ?? d.panelsAboveFullscreen
    }

    /// Env overrides for scripted demos/tests (used with `--autolive`).
    mutating func applyEnvironment() {
        let e = ProcessInfo.processInfo.environment
        if let v = e["LALAAI_RELAY"] { relayURL = v }
        if let v = e["LALAAI_SLUG"] { slug = v }
        if let v = e["LALAAI_TITLE"] { title = v }
        if let v = e["LALAAI_LOCALE"] { presenterLocale = v }
        if let v = e["LALAAI_TARGETS"] { targetLangs = v.split(separator: ",").map(String.init) }
        if let v = e["LALAAI_PROVIDER"], let p = LLMProvider(rawValue: v) { llmProvider = p }
        if let v = e["LALAAI_CUSTOM_CMD"] { customCommand = v }
        if let v = e["LALAAI_MODEL"] { llmModel = v }
        if let v = e["LALAAI_MCP_PORT"], let p = UInt16(v) { mcpPort = p }
    }

    private static let key = "lalaai.config.v1"
    static func load() -> Config {
        guard let d = UserDefaults.standard.data(forKey: key), let c = try? JSONDecoder().decode(Config.self, from: d) else { return Config() }
        return c
    }
    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}

/// Prezefren-style caption modes.
enum CaptionMode: String, Codable, CaseIterable, Identifiable {
    case live, additive
    var id: String { rawValue }
    var label: String { self == .live ? "Live" : "Additive" }
    var help: String { self == .live ? "Only what's being said right now" : "A continuous, scrolling transcript" }
}

/// Look of every floating window (QR, Q&A, captions).
enum PanelStyle: String, Codable, CaseIterable, Identifiable {
    case glass, solid, clear
    var id: String { rawValue }
    var label: String { switch self { case .glass: "Glass"; case .solid: "Solid"; case .clear: "Clear" } }
    var icon: String { switch self { case .glass: "square.on.square.dashed"; case .solid: "square.fill"; case .clear: "textformat" } }
    var next: PanelStyle { switch self { case .glass: .solid; case .solid: .clear; case .clear: .glass } }
}


