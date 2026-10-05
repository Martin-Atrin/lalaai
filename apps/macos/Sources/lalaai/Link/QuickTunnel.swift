import Foundation

/// One-click public link: runs the bundled `cloudflared` as a Cloudflare Quick Tunnel
/// (`https://<random>.trycloudflare.com` → the relay on this Mac). Free, no account, ~200 concurrent viewers.
/// Ported from JoinInter (see docs/PROVENANCE.md).
@MainActor
final class QuickTunnel {
    enum State: Equatable {
        case idle
        case starting
        /// Tunnel is up and its hostname resolves publicly.
        case ready(URL)
        case failed(String)
    }

    /// Quick tunnels are capped at ~200 concurrent requests; warn the presenter before that.
    static let capacityWarning = 150

    private(set) var state: State = .idle { didSet { onState?(state) } }
    var onState: ((State) -> Void)?

    private var process: Process?
    private var output = ""

    /// `LALAAI_CLOUDFLARED` (tests: a fake that proxies locally), else `cloudflared` inside the app
    /// (Contents/Helpers), else `apps/macos/vendor` when running from `swift run`.
    static var binary: URL? {
        let fm = FileManager.default
        if let fake = testBinary { return fake }
        let bundled = Bundle.main.bundleURL.appending(path: "Contents/Helpers/cloudflared")
        if fm.isExecutableFile(atPath: bundled.path) { return bundled }
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<6 {
            guard let d = dir else { break }
            let vendor = d.appending(path: "vendor/cloudflared")
            if fm.isExecutableFile(atPath: vendor.path) { return vendor }
            dir = d.deletingLastPathComponent()
        }
        return nil
    }

    /// Starts a quick tunnel to `http://127.0.0.1:<port>` and waits until the public hostname resolves
    /// via 1.1.1.1 and the relay answers through it.
    func start(port: UInt16, timeout: TimeInterval = 45) async throws -> URL {
        // HTTP/2 over TCP 443: QUIC (UDP 7844) is often blocked on venue and hotel Wi-Fi.
        try await launch(["tunnel", "--no-autoupdate", "--protocol", "http2", "--url", "http://127.0.0.1:\(port)"], env: [:], url: nil, timeout: timeout)
    }

    private func launch(_ args: [String], env: [String: String], url known: URL?, timeout: TimeInterval) async throws -> URL {
        stop()
        guard let bin = Self.binary else { throw TunnelError.missingBinary }
        state = .starting
        output = ""
        StderrGuard.install()

        let p = Process()
        p.executableURL = bin
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = String(decoding: h.availableData, as: UTF8.self)
            Task { @MainActor in self?.output += chunk }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self, self.process === proc else { return }
                self.process = nil
                if case .ready = self.state { self.state = .failed("The public link stopped (cloudflared exited).") }
            }
        }
        do { try p.run() } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
        process = p
        Self.rememberPID(p.processIdentifier)

        let deadline = Date().addingTimeInterval(timeout)
        var url = known
        while Date() < deadline, process === p {
            if url == nil, let u = Self.tunnelURL(in: output, allowLocal: Self.testBinary != nil) { url = u }
            let resolves: Bool
            if let host = url?.host() { resolves = Self.testBinary != nil ? true : await Self.resolvesPublicly(host) } else { resolves = false }
            if let u = url, resolves, await Self.relayAnswers(at: u) {
                state = .ready(u)
                return u
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        let reason = process == nil ? "cloudflared exited: \(output.suffix(300))" : "timed out waiting for the public link"
        stop()
        state = .failed(reason)
        throw TunnelError.failed(reason)
    }

    func stop() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        Self.rememberPID(nil)
        if state != .idle { state = .idle }
    }

    // MARK: helpers

    /// The quick-tunnel hostname cloudflared prints in its banner. `api.trycloudflare.com` is the endpoint it
    /// asks for a tunnel and shows up in its error lines when Cloudflare is unreachable: never a tunnel.
    /// `allowLocal` also accepts `http://127.0.0.1:<port>`, which the e2e's fake cloudflared prints.
    nonisolated static func tunnelURL(in log: String, allowLocal: Bool = false) -> URL? {
        var patterns = [#"https://[a-z0-9-]+\.trycloudflare\.com(?![A-Za-z0-9.-])"#]
        if allowLocal { patterns.append(#"http://127\.0\.0\.1:[0-9]+\b"#) }
        for line in log.split(whereSeparator: \.isNewline) {
            for pattern in patterns {
                var rest = line[...]
                while let r = rest.range(of: pattern, options: .regularExpression) {
                    let candidate = String(rest[r])
                    rest = rest[r.upperBound...]
                    if candidate == "https://api.trycloudflare.com" { continue }
                    if let u = URL(string: candidate) { return u }
                }
            }
        }
        return nil
    }

    /// Test hook: path to a stand-in for cloudflared (scripts/fake-cloudflared.ts). Its URL is local, so the public
    /// DNS check is skipped for it.
    nonisolated static var testBinary: URL? {
        guard let p = ProcessInfo.processInfo.environment["LALAAI_CLOUDFLARED"], !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p)
    }

    /// Phones use public resolvers; ask one directly so our own DNS cache can't hide (or fake) readiness.
    nonisolated static func resolvesPublicly(_ host: String) async -> Bool {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/dig")
            p.arguments = ["@1.1.1.1", "+short", "+time=2", "+tries=1", host, "A"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { _ in
                let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                cont.resume(returning: s.split(separator: "\n").contains { $0.first?.isNumber == true })
            }
            do { try p.run() } catch { cont.resume(returning: false) }
        }
    }

    nonisolated static func relayAnswers(at base: URL) async -> Bool {
        var req = URLRequest(url: base.appending(path: "api/health"))
        req.timeoutInterval = 4
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return obj["ok"] as? Bool == true
    }

    /// A crashed app can leave cloudflared running; remember its pid and reap it on the next launch.
    private static let pidKey = "lalaai.tunnel.pid"
    private static func rememberPID(_ pid: Int32?) {
        if let pid { UserDefaults.standard.set(Int(pid), forKey: pidKey) } else { UserDefaults.standard.removeObject(forKey: pidKey) }
    }
    static func reapOrphan() {
        let pid = Int32(UserDefaults.standard.integer(forKey: pidKey))
        guard pid > 0 else { return }
        rememberPID(nil)
        var size = Int(MAXPATHLEN)
        var buf = [CChar](repeating: 0, count: size)
        size = Int(proc_pidpath(pid, &buf, UInt32(size)))
        guard size > 0, String(cString: buf).hasSuffix("/cloudflared") else { return }
        kill(pid, SIGTERM)
    }
}

enum TunnelError: LocalizedError {
    case missingBinary
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .missingBinary: "The public-link helper (cloudflared) is missing from the app."
        case let .failed(why): "Couldn't open a public link: \(why)"
        }
    }
}
