import Foundation

struct ModelOption: Identifiable, Hashable {
    /// Value passed to the CLI's model flag ("" = the CLI's own default).
    let id: String
    let label: String
    var detail: String? = nil
}

/// Models each agent CLI accepts, so the presenter picks from a list instead of guessing model ids.
enum ModelCatalog {
    static func options(for provider: LLMProvider) -> [ModelOption] {
        switch provider {
        case .none, .custom:
            return []
        case .claude:
            // Stable aliases the Claude Code CLI resolves to the current model of each tier.
            return [
                ModelOption(id: "", label: "CLI default"),
                ModelOption(id: "opus", label: "Opus", detail: "most capable"),
                ModelOption(id: "claude-sonnet-5", label: "Sonnet 5", detail: "balanced, recommended"),
                ModelOption(id: "sonnet", label: "Sonnet (latest)", detail: "balanced"),
                ModelOption(id: "haiku", label: "Haiku", detail: "fastest"),
            ]
        case .gemini:
            return [
                ModelOption(id: "", label: "CLI default"),
                ModelOption(id: "pro", label: "Pro", detail: "most capable"),
                ModelOption(id: "flash", label: "Flash", detail: "balanced"),
                ModelOption(id: "flash-lite", label: "Flash-Lite", detail: "fastest"),
            ]
        case .codex:
            // Runs skip ~/.codex/config.toml when the CLI supports it, so its `model = …` doesn't apply.
            if AgentRunner.codexIgnoresUserConfig { return [ModelOption(id: "", label: "CLI default")] + codexModels() }
            let def = codexDefaultModel()
            let supported = codexModels()
            let defaultOK = def == nil || supported.isEmpty || supported.contains { $0.id == def }
            let defaultLabel = def.map { defaultOK ? "CLI default (\($0))" : "CLI default (\($0)) — not supported by this Codex" } ?? "CLI default"
            return [ModelOption(id: "", label: defaultLabel)] + supported
        }
    }

    /// True when the CLI's configured default can't be used (Codex set to a model newer than the installed CLI).
    static func defaultIsBroken(for provider: LLMProvider) -> Bool {
        guard provider == .codex, !AgentRunner.codexIgnoresUserConfig, let def = codexDefaultModel() else { return false }
        let supported = codexModels()
        return !supported.isEmpty && !supported.contains { $0.id == def }
    }

    /// The best model to pick automatically when the default is broken.
    static func recommended(for provider: LLMProvider) -> String? {
        provider == .codex ? codexModels().first?.id : nil
    }

    // MARK: Codex

    private static var codexHome: URL {
        if let h = ProcessInfo.processInfo.environment["CODEX_HOME"] { return URL(fileURLWithPath: h) }
        return URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".codex")
    }

    /// Models the installed Codex CLI knows (its own cache, refreshed by Codex itself), best first.
    static func codexModels() -> [ModelOption] {
        guard let data = try? Data(contentsOf: codexHome.appending(path: "models_cache.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else { return [] }
        return models
            .filter { ($0["visibility"] as? String) == "list" }
            .sorted { ($0["priority"] as? Int ?? 99) < ($1["priority"] as? Int ?? 99) }
            .compactMap { m in
                guard let slug = m["slug"] as? String else { return nil }
                return ModelOption(id: slug, label: m["display_name"] as? String ?? slug, detail: m["description"] as? String)
            }
    }

    /// `model = "…"` from ~/.codex/config.toml (only that line is read).
    static func codexDefaultModel() -> String? {
        guard let text = try? String(contentsOf: codexHome.appending(path: "config.toml"), encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { break } // only top-level keys
            guard t.hasPrefix("model"), let eq = t.firstIndex(of: "=") else { continue }
            let key = t[..<eq].trimmingCharacters(in: .whitespaces)
            guard key == "model" else { continue }
            return t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }
}
