import Foundation

/// Hosts an event from this Mac: the embedded relay (apps/shared/Relay) on the local network and, for a
/// Public link, a Cloudflare quick tunnel in front of it. Phones on the same Wi-Fi can always use the LAN
/// address; the tunnel is what makes the room reachable from anywhere.
@MainActor
final class LinkHost {
    enum Tunnel: Equatable {
        case off
        /// Opening (or re-opening) the public link. Wi-Fi still works meanwhile.
        case connecting
        case up(URL)
        /// Cloudflare unreachable or the tunnel dropped: Wi-Fi only until a retry succeeds.
        case down(String)
    }

    private(set) var port: UInt16 = 0
    private(set) var tunnel: Tunnel = .off { didSet { if tunnel != oldValue { onChange?() } } }
    var onChange: (() -> Void)?
    var log: ((String) -> Void)?

    private var relay: EmbeddedRelay?
    private let quick = QuickTunnel()
    private var tunnelTask: Task<Void, Never>?

    var isRunning: Bool { relay != nil }
    /// The presenter's own connection: loopback, so it never depends on Wi-Fi or Cloudflare.
    var localBase: String { "http://127.0.0.1:\(port)" }
    /// What phones on the same network use.
    var lanBase: String? { Lang.lanIP().map { "http://\($0):\(port)" } }
    /// What the QR code should show right now.
    var joinBase: String? {
        if case let .up(u) = tunnel { return u.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        return lanBase
    }

    /// The attendee web app: Contents/Resources/pwa in the built app, web/pwa/dist when running from `swift run`.
    static var pwaDir: URL? {
        let fm = FileManager.default
        if let r = Bundle.main.resourceURL?.appending(path: "pwa"), fm.fileExists(atPath: r.appending(path: "index.html").path) { return r }
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<7 {
            guard let d = dir else { break }
            let dist = d.appending(path: "web/pwa/dist")
            if fm.fileExists(atPath: dist.appending(path: "index.html").path) { return dist }
            dir = d.deletingLastPathComponent()
        }
        return nil
    }

    /// Starts the relay on :8787, or on any free port if something else (say, a dev relay) holds it.
    func startRelay() async throws {
        guard relay == nil else { return }
        QuickTunnel.reapOrphan()
        var lastError: Error?
        for p in [LinkMode.localPort, 0] {
            let r = EmbeddedRelay(options: .init(port: p, bindAllInterfaces: true, staticDir: Self.pwaDir))
            r.onLog = { [weak self] line in Task { @MainActor in self?.log?(line) } }
            do {
                port = try await r.start()
                relay = r
                log?("relay on :\(port) (pwa: \(Self.pwaDir?.path ?? "missing"))")
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? EmbeddedRelay.StartError.invalidPort
    }

    /// Keeps a public link open until `stop()`: retries while Cloudflare is unreachable, and re-opens the tunnel
    /// when cloudflared exits or the link stops answering. A quick tunnel gets a new hostname each time, so the QR
    /// code follows `joinBase`.
    func startTunnel() {
        guard tunnelTask == nil, relay != nil else { return }
        tunnelTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled, let self {
                self.tunnel = .connecting
                do {
                    let url = try await self.quick.start(port: self.port, timeout: Self.openTimeout)
                    attempt = 0
                    self.tunnel = .up(url)
                    self.log?("public link up: \(url.absoluteString)")
                    let why = await self.watch(url)
                    if Task.isCancelled { break }
                    self.log?("public link lost: \(why)")
                    self.quick.stop()
                    self.tunnel = .down(why)
                } catch {
                    if Task.isCancelled { break }
                    self.log?("public link failed: \(error.localizedDescription)")
                    self.tunnel = .down(Self.friendly(error))
                }
                attempt += 1
                let wait = Self.retryDelay(attempt: attempt)
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    func stop() {
        tunnelTask?.cancel()
        tunnelTask = nil
        quick.stop()
        tunnel = .off
        relay?.stop()
        relay = nil
    }

    // MARK: tuning (tests shorten these through the environment)

    static var openTimeout: TimeInterval { env("LALAAI_TUNNEL_TIMEOUT") ?? 45 }
    static var healthInterval: TimeInterval { env("LALAAI_TUNNEL_HEALTH_INTERVAL") ?? 15 }
    /// Consecutive failed health checks before the tunnel is re-opened.
    static let healthFailures = 4

    /// 5 s, 10 s, 20 s, then every 30 s.
    nonisolated static func retryDelay(attempt: Int) -> TimeInterval {
        if let fixed = env("LALAAI_TUNNEL_RETRY") { return fixed }
        return min(30, 5 * pow(2, Double(max(0, attempt - 1))))
    }

    private nonisolated static func env(_ key: String) -> TimeInterval? {
        ProcessInfo.processInfo.environment[key].flatMap(TimeInterval.init)
    }

    /// Returns why the link went away: cloudflared exited, or the relay stopped answering through it.
    private func watch(_ url: URL) async -> String {
        var misses = 0
        var lastCheck = Date()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { break }
            guard case .ready = quick.state else { return "the public link stopped (cloudflared exited)" }
            guard Date().timeIntervalSince(lastCheck) >= Self.healthInterval else { continue }
            lastCheck = Date()
            if await QuickTunnel.relayAnswers(at: url) {
                misses = 0
            } else {
                misses += 1
                if misses >= Self.healthFailures { return "the public link stopped answering" }
            }
        }
        return "stopped"
    }

    private static func friendly(_ error: Error) -> String {
        if case TunnelError.missingBinary = error { return error.localizedDescription }
        return "Cloudflare is unreachable from this network"
    }
}
