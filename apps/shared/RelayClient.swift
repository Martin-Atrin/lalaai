import Foundation

enum RelayError: LocalizedError {
    case http(Int, String)
    case badURL
    var errorDescription: String? {
        switch self {
        case let .http(code, msg): return "Relay \(code): \(msg)"
        case .badURL: return "Invalid relay URL"
        }
    }
}

/// Presenter connection to the relay: REST for room creation, WebSocket for live traffic.
@MainActor
final class RelayClient {
    enum State: Equatable { case disconnected, connecting, connected }

    var onMessage: ((RelayMessage) -> Void)?
    var onState: ((State) -> Void)?

    private let base: URL
    private var task: URLSessionWebSocketTask?
    private var slug = ""
    private var token = ""
    private var wantConnected = false
    private var retry = 0
    private var pingTimer: Timer?
    private let encoder = JSONEncoder()

    init(baseURL: String) throws {
        guard let u = URL(string: baseURL.trimmingCharacters(in: .whitespaces)), u.scheme?.hasPrefix("http") == true else {
            throw RelayError.badURL
        }
        // Relay on this same Mac: talk to it over loopback (no Local Network permission needed).
        // Phones still get the LAN/public URL via the QR code.
        #if os(macOS)
        let thisMac = Host.current().localizedName
        #else
        let thisMac: String? = nil
        #endif
        if let host = u.host(), host == Lang.lanIP() || host == thisMac,
           var c = URLComponents(url: u, resolvingAgainstBaseURL: false) {
            c.host = "127.0.0.1"
            base = c.url ?? u
        } else {
            base = u
        }
    }

    static func randomName(baseURL: String) async -> String? {
        guard let u = URL(string: baseURL)?.appending(path: "api/names/random"),
              let (data, _) = try? await URLSession.shared.data(from: u),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["slug"] as? String
    }

    func createRoom(_ req: CreateRoomRequest) async throws -> CreateRoomResponse {
        var r = URLRequest(url: base.appending(path: "api/rooms"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.httpBody = try encoder.encode(req)
        r.timeoutInterval = 10
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw RelayError.http(code, msg ?? String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(CreateRoomResponse.self, from: data)
    }

    func connect(slug: String, token: String) {
        self.slug = slug
        self.token = token
        wantConnected = true
        open()
    }

    func disconnect() {
        wantConnected = false
        pingTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        onState?(.disconnected)
    }

    func send(_ msg: PresenterMessage) {
        guard let task, let data = try? encoder.encode(msg), let s = String(data: data, encoding: .utf8) else { return }
        task.send(.string(s)) { _ in }
    }

    private func open() {
        var comps = URLComponents(url: base.appending(path: "ws"), resolvingAgainstBaseURL: false)!
        comps.scheme = base.scheme == "https" ? "wss" : "ws"
        comps.queryItems = [.init(name: "room", value: slug), .init(name: "role", value: "presenter"), .init(name: "token", value: token)]
        let t = URLSession.shared.webSocketTask(with: comps.url!)
        task = t
        onState?(.connecting)
        t.resume()
        receive(t)
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.send(.ping) }
        }
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === t else { return }
                switch result {
                case .success(let msg):
                    self.retry = 0
                    self.onState?(.connected)
                    let data: Data
                    switch msg {
                    case .string(let s): data = Data(s.utf8)
                    case .data(let d): data = d
                    @unknown default: data = Data()
                    }
                    if let m = try? RelayMessage.decode(data) { self.onMessage?(m) }
                    self.receive(t)
                case .failure:
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        task = nil
        pingTimer?.invalidate()
        onState?(wantConnected ? .connecting : .disconnected)
        guard wantConnected else { return }
        retry += 1
        let delay = min(10.0, 0.5 * pow(2.0, Double(min(retry, 5))))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wantConnected, self.task == nil else { return }
            self.open()
        }
    }
}
