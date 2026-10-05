// Embedded relay — one TCP connection: HTTP/1.1 (keep-alive, pipelining, Content-Length bodies)
// that can upgrade to an RFC 6455 WebSocket. All callbacks run on the server's serial queue.

import CryptoKit
import Foundation
import Network

/// Who an upgraded socket is (server.ts `WsData`).
enum ERRole {
    case presenter(slug: String)
    case attendee(slug: String, uid: String)

    var slug: String {
        switch self {
        case let .presenter(s), let .attendee(s, _): return s
        }
    }
}

/// What the HTTP router decided for a request.
enum ERRouteResult {
    case response(ERResponse)
    case upgrade(ERRole)
}

/// Confined to the server queue (all NWConnection callbacks are delivered there).
final class ERConnection: @unchecked Sendable {
    /// draining: a response/close is being flushed and further input is ignored.
    enum Phase { case http, ws, closing, draining, closed }

    static let maxHeaderBytes = 32 * 1024
    static let maxBodyBytes = 1 << 20
    static let maxMessageBytes = 1 << 20
    static let maxBufferedOut = 64 << 20

    let nw: NWConnection
    let id: Int
    private weak var server: ERServer?
    private(set) var phase: Phase = .http
    private(set) var role: ERRole?

    private var buf: [UInt8] = []
    private var pos = 0
    /// Last time any bytes arrived (uptime nanoseconds).
    private(set) var lastRx = DispatchTime.now().uptimeNanoseconds
    var pinged = false
    private var fragOpcode: UInt8?
    private var fragBuf: [UInt8] = []
    private var outstanding = 0
    private var closeTimer: DispatchWorkItem?
    private var openFired = false

    init(nw: NWConnection, id: Int, server: ERServer) {
        self.nw = nw
        self.id = id
        self.server = server
    }

    func start(queue: DispatchQueue) {
        nw.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: self?.terminate()
            default: break
            }
        }
        nw.start(queue: queue)
        receive()
    }

    private func receive() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self, self.phase != .closed else { return }
            if let data, !data.isEmpty {
                self.lastRx = DispatchTime.now().uptimeNanoseconds
                self.pinged = false
                self.buf.append(contentsOf: data)
                self.process()
            }
            if complete || error != nil {
                self.terminate()
                return
            }
            if self.phase != .closed { self.receive() }
        }
    }

    private func process() {
        while phase != .closed {
            let progressed: Bool
            switch phase {
            case .http: progressed = parseHTTP()
            case .ws, .closing: progressed = parseFrame()
            case .draining:
                pos = buf.count
                progressed = false
            case .closed: progressed = false
            }
            if !progressed { break }
        }
        if pos > 0 {
            if pos >= buf.count { buf.removeAll(keepingCapacity: true) } else { buf.removeFirst(pos) }
            pos = 0
        }
    }

    // MARK: HTTP

    private func findHeaderEnd() -> Int? {
        let n = buf.count
        guard n - pos >= 4 else { return nil }
        var i = pos
        while i + 3 < n {
            if buf[i] == 13, buf[i + 1] == 10, buf[i + 2] == 13, buf[i + 3] == 10 { return i }
            i += 1
        }
        return nil
    }

    /// Parses and handles one request if complete. Returns true if it consumed input.
    private func parseHTTP() -> Bool {
        guard let end = findHeaderEnd() else {
            if buf.count - pos > Self.maxHeaderBytes { fail(431) }
            return false
        }
        if end - pos > Self.maxHeaderBytes { fail(431); return false }
        let head = String(decoding: buf[pos..<end], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        // tolerate stray CRLFs before a request line
        while lines.first == "" { lines.removeFirst() }
        guard let reqLine = lines.first else { pos = end + 4; return true }
        let parts = reqLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { fail(400); return false }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let c = line.firstIndex(of: ":") else { fail(400); return false }
            let name = line[..<c].lowercased()
            let value = line[line.index(after: c)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            if let prev = headers[name] { headers[name] = prev + ", " + value } else { headers[name] = value }
        }
        if headers["transfer-encoding"] != nil { fail(501); return false }
        var bodyLen = 0
        if let cl = headers["content-length"] {
            let vals = Set(cl.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            guard vals.count == 1, let v = vals.first, !v.isEmpty, v.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(v) else {
                fail(400)
                return false
            }
            guard n <= Self.maxBodyBytes else { fail(413); return false }
            bodyLen = n
        }
        let bodyStart = end + 4
        guard buf.count - bodyStart >= bodyLen else { return false }
        let body = Array(buf[bodyStart..<(bodyStart + bodyLen)])
        pos = bodyStart + bodyLen
        let req = ERRequest(method: String(parts[0]), target: String(parts[1]), version: String(parts[2]), headers: headers, body: body)
        handle(req)
        return true
    }

    private func handle(_ req: ERRequest) {
        guard let server else { return }
        let keepAlive = req.wantsKeepAlive
        switch server.route(req, self) {
        case let .response(res):
            write(res.serialized(head: req.method == "HEAD", close: !keepAlive))
            if !keepAlive { phase = .draining; closeAfterFlush() }
        case let .upgrade(role):
            if let res = upgradeRejection(req) {
                // server.ts: `srv.upgrade()` returned false → "upgrade failed" (400)
                write(res.serialized(head: false, close: !keepAlive))
                if !keepAlive { phase = .draining; closeAfterFlush() }
                return
            }
            let key = req.header("sec-websocket-key")!
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            write(Data(head.utf8))
            self.role = role
            phase = .ws
            openFired = true
            server.wsOpen(self)
        }
    }

    /// The checks Bun's `server.upgrade(req)` does; nil when the request can be upgraded.
    private func upgradeRejection(_ req: ERRequest) -> ERResponse? {
        let upgrade = (req.header("upgrade") ?? "").lowercased()
        guard req.method == "GET",
              upgrade.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "websocket" }),
              let key = req.header("sec-websocket-key"), !key.isEmpty,
              req.header("sec-websocket-version") == "13"
        else { return ERResponse.text("upgrade failed", 400) }
        return nil
    }

    /// Protocol-level HTTP error: respond and close.
    private func fail(_ status: Int) {
        let body = ERResponse.reason(status)
        write(ERResponse.text(body, status).serialized(head: false, close: true))
        phase = .draining
        closeAfterFlush()
        pos = buf.count
    }

    // MARK: WebSocket frames

    /// Parses one frame if complete. Returns true if it consumed input.
    private func parseFrame() -> Bool {
        let avail = buf.count - pos
        guard avail >= 2 else { return false }
        let b0 = buf[pos], b1 = buf[pos + 1]
        let fin = b0 & 0x80 != 0
        let rsv = b0 & 0x70
        let opcode = b0 & 0x0F
        let masked = b1 & 0x80 != 0
        var len = UInt64(b1 & 0x7F)
        var hdr = 2
        if len == 126 {
            guard avail >= 4 else { return false }
            len = UInt64(buf[pos + 2]) << 8 | UInt64(buf[pos + 3])
            hdr = 4
        } else if len == 127 {
            guard avail >= 10 else { return false }
            len = 0
            for k in 0..<8 { len = len << 8 | UInt64(buf[pos + 2 + k]) }
            hdr = 10
            if len >> 63 != 0 { protocolError(1002); return false }
        }
        if rsv != 0 || !masked { protocolError(1002); return false }
        let isControl = opcode & 0x08 != 0
        if isControl && (len > 125 || !fin) { protocolError(1002); return false }
        if !isControl && len + UInt64(fragBuf.count) > UInt64(Self.maxMessageBytes) { protocolError(1009); return false }
        let total = hdr + 4 + Int(len)
        guard avail >= total else { return false }
        let maskAt = pos + hdr
        let m0 = buf[maskAt], m1 = buf[maskAt + 1], m2 = buf[maskAt + 2], m3 = buf[maskAt + 3]
        let mask = [m0, m1, m2, m3]
        let start = maskAt + 4
        var payload = Array(buf[start..<(start + Int(len))])
        payload.withUnsafeMutableBufferPointer { p in
            for k in 0..<p.count { p[k] ^= mask[k & 3] }
        }
        pos += total

        switch opcode {
        case 0x0:
            guard let op = fragOpcode else { protocolError(1002); return false }
            fragBuf.append(contentsOf: payload)
            if fin {
                let msg = fragBuf
                fragBuf = []
                fragOpcode = nil
                deliver(op, msg)
            }
        case 0x1, 0x2:
            if fragOpcode != nil { protocolError(1002); return false }
            if fin { deliver(opcode, payload) } else { fragOpcode = opcode; fragBuf = payload }
        case 0x8:
            if phase == .closing {
                terminate()
                return false
            }
            var reply: [UInt8] = []
            if payload.count >= 2 { reply = [payload[0], payload[1]] }
            phase = .closing
            writeFrame(opcode: 0x8, payload: reply) { [weak self] in self?.terminate() }
            return false
        case 0x9:
            if phase == .ws { writeFrame(opcode: 0xA, payload: payload) }
        case 0xA:
            break
        default:
            protocolError(1002)
            return false
        }
        return true
    }

    private func deliver(_ opcode: UInt8, _ payload: [UInt8]) {
        guard phase == .ws, let server else { return }
        if opcode == 0x1 {
            // uWS closes text frames that aren't valid UTF-8 (1007)
            guard String(bytes: payload, encoding: .utf8) != nil else { protocolError(1007); return }
            server.wsMessage(self, payload)
        } else {
            // binary: server.ts decodes it with TextDecoder (lossy)
            server.wsMessage(self, Array(String(decoding: payload, as: UTF8.self).utf8))
        }
    }

    private func protocolError(_ code: UInt16) {
        guard phase == .ws else { terminate(); return }
        phase = .draining
        writeFrame(opcode: 0x8, payload: [UInt8(code >> 8), UInt8(code & 0xFF)]) { [weak self] in self?.terminate() }
        pos = buf.count
    }

    static func frame(opcode: UInt8, payload: [UInt8]) -> Data {
        var d = Data()
        d.reserveCapacity(payload.count + 10)
        d.append(0x80 | opcode)
        let n = payload.count
        if n < 126 {
            d.append(UInt8(n))
        } else if n <= 0xFFFF {
            d.append(126)
            d.append(UInt8(n >> 8))
            d.append(UInt8(n & 0xFF))
        } else {
            d.append(127)
            for k in (0..<8).reversed() { d.append(UInt8((UInt64(n) >> (UInt64(k) * 8)) & 0xFF)) }
        }
        d.append(contentsOf: payload)
        return d
    }

    private func writeFrame(opcode: UInt8, payload: [UInt8], then: (@Sendable () -> Void)? = nil) {
        write(Self.frame(opcode: opcode, payload: payload), then: then)
    }

    // MARK: Public (server-side) API

    /// Sends a pre-built text frame (only while the socket is open, like ws.send in Bun).
    func sendFrame(_ frame: Data) {
        guard phase == .ws else { return }
        write(frame)
    }

    func sendText(_ bytes: [UInt8]) {
        sendFrame(Self.frame(opcode: 0x1, payload: bytes))
    }

    func sendPing() {
        guard phase == .ws else { return }
        pinged = true
        writeFrame(opcode: 0x9, payload: [])
    }

    /// Server-initiated close handshake (e.g. 4000 "replaced"). Waits briefly for the peer's close.
    func close(code: UInt16 = 1000, reason: String = "") {
        guard phase == .ws else { return }
        phase = .closing
        var payload = [UInt8(code >> 8), UInt8(code & 0xFF)]
        payload.append(contentsOf: erSlice(reason, 120).utf8.prefix(123))
        writeFrame(opcode: 0x8, payload: payload)
        let w = DispatchWorkItem { [weak self] in self?.terminate() }
        closeTimer = w
        server?.queue.asyncAfter(deadline: .now() + 3, execute: w)
        // Bun (uWS) runs the close handler synchronously inside ws.close(): e.g. a replaced
        // presenter broadcasts live:false before the new one's live:true.
        if openFired {
            openFired = false
            server?.wsClosed(self)
        }
    }

    /// Drops the TCP connection (no close frame).
    func abort() { terminate() }

    var idleNanos: UInt64 { DispatchTime.now().uptimeNanoseconds &- lastRx }

    // MARK: Plumbing

    private func write(_ d: Data, then: (@Sendable () -> Void)? = nil) {
        guard phase != .closed else { return }
        outstanding += d.count
        if outstanding > Self.maxBufferedOut {
            server?.log("closing a socket that stopped reading (\(outstanding) bytes queued)")
            terminate()
            return
        }
        let n = d.count
        nw.send(content: d, completion: .contentProcessed { [weak self] _ in
            self?.outstanding -= n
            then?()
        })
    }

    private func closeAfterFlush() {
        nw.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.terminate()
        })
    }

    private func terminate() {
        guard phase != .closed else { return }
        phase = .closed
        closeTimer?.cancel()
        closeTimer = nil
        buf = []
        pos = 0
        nw.cancel()
        let wasOpen = openFired
        openFired = false
        server?.connectionClosed(self, wasWebSocket: wasOpen)
    }
}
