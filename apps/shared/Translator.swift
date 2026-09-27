import Foundation
import SwiftUI
import Translation

/// On-device translation via Apple's Translation framework (Neural Engine).
/// Sessions are created per (source → target) pair and cached; only installed pairs are used.
@MainActor
final class Translator {
    private var sessions: [String: TranslationSession] = [:]
    /// Fallback for languages Apple lacks (macOS: on-device NLLB helper). (text, from, to) -> translation
    var fallback: ((String, String, String) async -> String?)?
    /// Codes Apple can translate; anything else goes to NLLB.
    var appleLangs: Set<String> = []
    private var unavailable: Set<String> = []
    private let availability = LanguageAvailability()

    enum PairStatus { case installed, needsDownload, unsupported }

    func status(from: String, to: String) async -> PairStatus {
        switch await availability.status(from: .init(identifier: from), to: .init(identifier: to)) {
        case .installed: return .installed
        case .supported: return .needsDownload
        default: return .unsupported
        }
    }

    /// Clears the negative cache (after the user downloads language packs).
    func reset() {
        sessions.removeAll()
        unavailable.removeAll()
    }

    private func session(from: String, to: String) async -> TranslationSession? {
        let key = "\(from)>\(to)"
        if let s = sessions[key] { return s }
        if unavailable.contains(key) { return nil }
        guard await status(from: from, to: to) == .installed else {
            unavailable.insert(key)
            return nil
        }
        let s = TranslationSession(installedSource: .init(identifier: from), target: .init(identifier: to))
        sessions[key] = s
        return s
    }

    func translate(_ text: String, from: String, to: String) async -> String? {
        if from == to { return text }
        guard !text.isEmpty else { return nil }
        let apple = appleLangs.contains(from) && appleLangs.contains(to)
        if !apple {
            // A language Apple doesn't have (Czech, Slovak, Burmese…): on-device NLLB.
            return await fallback?(text, from, to)
        }
        if let s = await session(from: from, to: to) { return try? await s.translate(text).targetText }
        // No direct pair: pivot through English when both legs exist (e.g. th → en → pt-PT).
        let pivot = "en"
        guard Lang.base(from) != pivot, Lang.base(to) != pivot,
              let a = await session(from: from, to: pivot), let b = await session(from: pivot, to: to),
              let mid = try? await a.translate(text).targetText else { return nil }
        return try? await b.translate(mid).targetText
    }

    /// Translates into every target (skipping `from`). Missing pairs are simply absent from the result.
    func translateAll(_ text: String, from: String, to targets: [String]) async -> [String: String] {
        var out: [String: String] = [:]
        for t in targets where t != from {
            if let r = await translate(text, from: from, to: t) { out[t] = r }
        }
        return out
    }
}

/// Invisible helper that walks through language pairs and asks the system to download them.
/// `.translationTask` is the only API that can show the system download prompt.
struct TranslationDownloader: View {
    let pairs: [(String, String)]
    var onProgress: (String) -> Void
    var onDone: () -> Void
    @State private var index = 0
    @State private var config: TranslationSession.Configuration?

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .translationTask(config) { session in
                let (a, b) = pairs[index]
                do { try await session.prepareTranslation() } catch { onProgress("\(a)→\(b): \(error.localizedDescription)") }
                await MainActor.run { advance() }
            }
            .onAppear { advance(initial: true) }
    }

    @MainActor private func advance(initial: Bool = false) {
        if !initial { index += 1 }
        guard index < pairs.count else { config = nil; onDone(); return }
        let (a, b) = pairs[index]
        onProgress("Preparing \(a) → \(b) (\(index + 1)/\(pairs.count))")
        config = .init(source: .init(identifier: a), target: .init(identifier: b))
    }
}
