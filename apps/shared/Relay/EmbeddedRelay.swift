// Embedded relay — public API. A Swift port of the Bun relay (web/relay/src/server.ts) so the app
// can host an event with no external server: the PWA, the REST API and the WebSocket all share
// one port (LAN or behind cloudflared). Raw TCP via Network.framework + our own HTTP/1.1 and
// RFC 6455 handling, so upgrade rejections carry real status codes.
//
// Threading: every listener/connection callback and all relay state live on one serial queue.

import Foundation
import Network

final class EmbeddedRelay: @unchecked Sendable {
    struct Options {
        var port: UInt16 = 8787
        /// false = loopback only (127.0.0.1).
        var bindAllInterfaces = true
        /// Built PWA (web/pwa/dist). nil = API/WebSocket only.
        var staticDir: URL?
        /// Overrides the base of `joinUrl` (otherwise derived from Host / X-Forwarded-*).
        var publicURL: String?

        init(port: UInt16 = 8787, bindAllInterfaces: Bool = true, staticDir: URL? = nil, publicURL: String? = nil) {
            self.port = port
            self.bindAllInterfaces = bindAllInterfaces
            self.staticDir = staticDir
            self.publicURL = publicURL
        }
    }

    enum StartError: LocalizedError {
        case alreadyRunning
        case invalidPort
        case listener(NWError)

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "Relay is already running"
            case .invalidPort: return "Invalid port"
            case .listener(.posix(.EADDRINUSE)): return "Relay could not listen: the port is already in use"
            case let .listener(e): return "Relay could not listen: \(e)"
            }
        }
    }

    let options: Options
    private let lock = NSLock()
    private var _onLog: (@Sendable (String) -> Void)?
    private var _roomCount = 0
    private var server: ERServer?

    init(options: Options) {
        self.options = options
    }

    var onLog: (@Sendable (String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onLog }
        set { lock.lock(); _onLog = newValue; lock.unlock() }
    }

    /// Number of rooms currently held (thread-safe).
    var roomCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _roomCount
    }

    fileprivate func emitLog(_ s: String) { onLog?(s) }

    fileprivate func setRoomCount(_ n: Int) {
        lock.lock()
        _roomCount = n
        lock.unlock()
    }

    /// Starts listening; returns the bound port (port 0 = ephemeral). Throws if the port is taken.
    func start() async throws -> UInt16 {
        let s: ERServer? = lock.withLock {
            if server != nil { return nil }
            let s = ERServer(options: options, owner: self)
            server = s
            return s
        }
        guard let s else { throw StartError.alreadyRunning }
        do {
            let port = try await s.start()
            emitLog("lalaai relay (swift) on http://\(options.bindAllInterfaces ? "0.0.0.0" : "127.0.0.1"):\(port)  static=\(options.staticDir?.path ?? "-")")
            return port
        } catch {
            lock.withLock { if server === s { server = nil } }
            throw error
        }
    }

    /// Stops listening, drops every connection and forgets all rooms.
    func stop() {
        lock.lock()
        let s = server
        server = nil
        lock.unlock()
        s?.stop()
        setRoomCount(0)
    }

    /// The listener is accepting connections. iOS can reclaim a listening socket while the app is suspended in the
    /// background; then this turns false and `relisten()` brings it back without losing rooms or attendees' state.
    var isListening: Bool { lock.withLock { server }?.isListening ?? false }

    /// Re-opens the listener on the same port (no-op while it's healthy). Rooms, questions and polls are kept;
    /// phones reconnect on their own.
    @discardableResult
    func relisten(force: Bool = false) async throws -> UInt16 {
        guard let s = lock.withLock({ server }) else { throw StartError.listener(.posix(.ENOTCONN)) }
        if !force, s.isListening, let p = s.boundPort { return p }
        let port = try await s.relisten()
        emitLog("relay listener re-opened on :\(port)")
        return port
    }

    deinit { server?.stop() }

    fileprivate final class Weak: @unchecked Sendable {
        weak var relay: EmbeddedRelay?
        init(_ r: EmbeddedRelay) { relay = r }
    }
}

/// Owns the listener, the connections and the relay core. Everything runs on `queue`.
final class ERServer: @unchecked Sendable {
    let queue = DispatchQueue(label: "lalaai.relay")
    private let options: EmbeddedRelay.Options
    private let owner: EmbeddedRelay.Weak
    private var listener: NWListener?
    private var conns: [Int: ERConnection] = [:]
    private var nextId = 0
    private var timers: [DispatchSourceTimer] = []
    private var stopped = false
    private var timersStarted = false
    private let stateLock = NSLock()
    private var _listening = false
    private var _boundPort: UInt16?
    let core: ERCore

    var isListening: Bool { stateLock.withLock { _listening } }
    var boundPort: UInt16? { stateLock.withLock { _boundPort } }
    private func setListening(_ on: Bool, port: UInt16? = nil) {
        stateLock.withLock {
            _listening = on
            if let port { _boundPort = port }
        }
    }

    static let idlePingNanos: UInt64 = 60 * 1_000_000_000
    static let idleCloseNanos: UInt64 = 120 * 1_000_000_000
    static let httpIdleNanos: UInt64 = 10 * 1_000_000_000

    init(options: EmbeddedRelay.Options, owner: EmbeddedRelay) {
        self.options = options
        self.owner = EmbeddedRelay.Weak(owner)
        var dir: String?
        if let u = options.staticDir { dir = u.standardizedFileURL.path }
        core = ERCore(queue: queue, staticDir: dir, publicURL: options.publicURL)
        let o = self.owner
        core.log = { s in o.relay?.emitLog(s) }
        core.onRoomCount = { n in o.relay?.setRoomCount(n) }
    }

    func log(_ s: String) { owner.relay?.emitLog(s) }

    func start() async throws -> UInt16 { try await listen(on: options.port) }

    /// A fresh listener on the port we had (the old one is cancelled); connections and the core stay.
    func relisten() async throws -> UInt16 {
        let port = boundPort ?? options.port
        // Cancel the old listener and wait until it has let go of the port (cancel is asynchronous).
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                setListening(false)
                guard let old = listener, old.state != .cancelled else { listener = nil; c.resume(); return }
                listener = nil
                final class Once: @unchecked Sendable { var done = false }
                let once = Once()
                let finish = { if !once.done { once.done = true; c.resume() } }
                old.stateUpdateHandler = { st in if case .cancelled = st { finish() } }
                old.cancel()
                queue.asyncAfter(deadline: .now() + 2) { finish() }
            }
        }
        // The kernel can still hold the port for a moment: retry briefly on EADDRINUSE.
        var attempt = 0
        while true {
            do { return try await listen(on: port) } catch EmbeddedRelay.StartError.listener(.posix(.EADDRINUSE)) where attempt < 20 {
                attempt += 1
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func listen(on rawPort: UInt16) async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        guard let port = NWEndpoint.Port(rawValue: rawPort) else { throw EmbeddedRelay.StartError.invalidPort }
        let l: NWListener
        do {
            if options.bindAllInterfaces {
                l = try NWListener(using: params, on: port)
            } else {
                params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
                l = try NWListener(using: params)
            }
        } catch let e as NWError {
            throw EmbeddedRelay.StartError.listener(e)
        }
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            // only touched on `queue`
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            l.stateUpdateHandler = { [weak self, weak l] st in
                switch st {
                case .ready:
                    guard !once.done else { return }
                    once.done = true
                    self?.setListening(true, port: l?.port?.rawValue)
                    self?.startTimers()
                    cont.resume(returning: l?.port?.rawValue ?? 0)
                case let .failed(e), let .waiting(e):
                    if !once.done {
                        once.done = true
                        l?.cancel()
                        cont.resume(throwing: EmbeddedRelay.StartError.listener(e))
                    } else {
                        self?.setListening(false)
                        self?.log("relay listener error: \(e)")
                    }
                case .cancelled:
                    self?.setListening(false)
                    if !once.done {
                        once.done = true
                        cont.resume(throwing: CancellationError())
                    }
                default:
                    break
                }
            }
            l.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            listener?.cancel()
            listener = nil
            setListening(false)
            for t in timers { t.cancel() }
            timers = []
            for c in Array(conns.values) { c.abort() }
            conns = [:]
            core.reset()
        }
    }

    private func startTimers() {
        guard !timersStarted else { return }
        timersStarted = true
        let idle = DispatchSource.makeTimerSource(queue: queue)
        idle.schedule(deadline: .now() + 5, repeating: 5)
        idle.setEventHandler { [weak self] in self?.checkIdle() }
        idle.resume()
        let sweep = DispatchSource.makeTimerSource(queue: queue)
        sweep.schedule(deadline: .now() + 600, repeating: 600)
        sweep.setEventHandler { [weak self] in self?.core.sweep() }
        sweep.resume()
        timers = [idle, sweep]
    }

    /// Bun closes WebSockets after 120 s without traffic, pinging first (uWS sendPings), and
    /// idle keep-alive HTTP connections after 10 s.
    private func checkIdle() {
        for c in Array(conns.values) {
            let idle = c.idleNanos
            switch c.phase {
            case .ws:
                if idle >= Self.idleCloseNanos { c.abort() } else if idle >= Self.idlePingNanos && !c.pinged { c.sendPing() }
            case .http:
                if idle >= Self.httpIdleNanos { c.abort() }
            case .closing, .draining:
                if idle >= Self.httpIdleNanos { c.abort() }
            case .closed:
                break
            }
        }
    }

    private func accept(_ nw: NWConnection) {
        guard !stopped else { nw.cancel(); return }
        nextId += 1
        let c = ERConnection(nw: nw, id: nextId, server: self)
        conns[c.id] = c
        c.start(queue: queue)
    }

    // MARK: called by ERConnection (on queue)

    func route(_ req: ERRequest, _ c: ERConnection) -> ERRouteResult { core.route(req) }
    func wsOpen(_ c: ERConnection) { core.wsOpen(c) }
    func wsMessage(_ c: ERConnection, _ raw: [UInt8]) { core.wsMessage(c, raw) }

    func wsClosed(_ c: ERConnection) { core.wsClose(c) }

    func connectionClosed(_ c: ERConnection, wasWebSocket: Bool) {
        conns[c.id] = nil
        if wasWebSocket { core.wsClose(c) }
    }
}
