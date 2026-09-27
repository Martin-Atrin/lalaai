import Foundation
import Observation

/// On-device NLLB-200 helper (translator/server.py) for languages Apple's Translation framework lacks
/// (Czech, Slovak, Burmese, Lao, Khmer, …). Started on demand; exits with the app.
@MainActor
@Observable
final class ExtendedTranslator {
    enum Status: Equatable { case off, starting(String), ready, failed(String) }

    var status: Status = .off
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored let port = 8798

    var isReady: Bool { status == .ready }

    /// Where server.py lives: LALAAI_TRANSLATOR_DIR, the copy bundled in the app (Contents/Resources/translator),
    /// or apps/translator when running from a repo checkout.
    static var directory: URL? {
        if let d = ProcessInfo.processInfo.environment["LALAAI_TRANSLATOR_DIR"] { return URL(fileURLWithPath: d) }
        if let bundled = Bundle.main.resourceURL?.appending(path: "translator"),
           FileManager.default.fileExists(atPath: bundled.appending(path: "server.py").path) { return bundled }
        var url = Bundle.main.bundleURL
        for _ in 0..<5 {
            url = url.deletingLastPathComponent()
            let candidate = url.appending(path: "translator")
            if FileManager.default.fileExists(atPath: candidate.appending(path: "server.py").path) { return candidate }
        }
        return nil
    }

    func startIfNeeded() {
        guard process == nil, status != .ready else { return }
        guard let dir = Self.directory else { status = .failed("translator/ folder not found next to the app"); return }
        guard let uv = AgentRunner.locate("uv") else { status = .failed("uv not found (needed to run the NLLB helper)"); return }
        status = .starting("starting")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: uv)
        p.arguments = ["run", "--project", dir.path, "python", "server.py"]
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = AgentRunner.loginPath
        env["LALAAI_TRANSLATOR_PORT"] = String(port)
        env["LALAAI_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        // Keep the Python env outside the (signed, read-only) app bundle.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "La Laai")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        env["UV_PROJECT_ENVIRONMENT"] = support.appending(path: "translator-venv").path
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                self.process = nil
                if self.status != .off { self.status = .failed("helper exited (\(proc.terminationStatus))") }
            }
        }
        do { try p.run(); process = p } catch { status = .failed(error.localizedDescription); return }
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if let h = await self.health() {
                    if h.ready { self.status = .ready; return }
                    if let err = h.error { self.status = .failed(err); return }
                    self.status = .starting(h.stage)
                }
            }
        }
    }

    func stop() {
        poll?.cancel()
        status = .off
        process?.terminate()
        process = nil
    }

    private struct Health: Decodable { var ready: Bool; var stage: String; var error: String? }

    private func health() async -> Health? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health"),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return try? JSONDecoder().decode(Health.self, from: data)
    }

    func translate(_ text: String, from: String, to: String) async -> String? {
        guard isReady, let url = URL(string: "http://127.0.0.1:\(port)/translate") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["texts": [text], "source": from, "target": to])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let texts = obj["texts"] as? [String], let first = texts.first, !first.isEmpty else { return nil }
        return first
    }
}
