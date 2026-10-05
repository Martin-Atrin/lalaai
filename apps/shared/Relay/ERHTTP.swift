// Embedded relay — minimal HTTP/1.1 pieces: request model, response serialisation, WHATWG-style
// URL path/query handling (to match `new URL(req.url)` in Bun), POSIX path normalisation (node's
// path.normalize/join) and the static content types Bun.file() reports.

import Foundation

struct ERRequest {
    var method: String
    var target: String
    var version: String
    /// Lower-cased header names; repeated headers joined with ", " (like Headers.get).
    var headers: [String: String]
    var body: [UInt8]

    /// WHATWG URL pathname (percent-encoded, dot segments resolved).
    var pathname: String
    /// Raw query (without "?"), or "".
    var query: String

    init(method: String, target: String, version: String, headers: [String: String], body: [UInt8]) {
        self.method = method
        self.target = target
        self.version = version
        self.headers = headers
        self.body = body
        (pathname, query) = ERURL.split(target)
    }

    func header(_ name: String) -> String? { headers[name] }

    var wantsKeepAlive: Bool {
        let c = (headers["connection"] ?? "").lowercased()
        let tokens = c.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if version == "HTTP/1.0" { return tokens.contains("keep-alive") }
        return !tokens.contains("close")
    }
}

struct ERResponse {
    var status: Int
    /// Ordered (name, value) pairs; Content-Length / Date / Connection are added on serialisation.
    var headers: [(String, String)]
    var body: [UInt8]

    init(status: Int = 200, headers: [(String, String)] = [], body: [UInt8] = []) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static let cors: [(String, String)] = [
        ("Access-Control-Allow-Origin", "*"),
        ("Access-Control-Allow-Methods", "GET,POST,OPTIONS"),
        ("Access-Control-Allow-Headers", "content-type"),
    ]

    /// server.ts `json(data, status)`.
    static func json(_ v: ERJ, _ status: Int = 200) -> ERResponse {
        ERResponse(status: status, headers: [("Content-Type", "application/json")] + cors, body: v.encoded())
    }

    /// `new Response("text", { status })`.
    static func text(_ s: String, _ status: Int = 200) -> ERResponse {
        ERResponse(status: status, headers: [("Content-Type", "text/plain;charset=utf-8")], body: Array(s.utf8))
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 101: return "Switching Protocols"
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 426: return "Upgrade Required"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        default: return "Status"
        }
    }

    func serialized(head: Bool, close: Bool) -> Data {
        var s = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        s += "Content-Length: \(body.count)\r\n"
        s += "Date: \(ERHTTPDate.now())\r\n"
        if close { s += "Connection: close\r\n" }
        s += "\r\n"
        var d = Data(s.utf8)
        if !head { d.append(contentsOf: body) }
        return d
    }
}

enum ERHTTPDate {
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()
    nonisolated(unsafe) private static var cache: (Int, String) = (0, "") // guarded by lock
    private static let lock = NSLock()

    static func now() -> String {
        lock.lock()
        defer { lock.unlock() }
        let sec = Int(Date().timeIntervalSince1970)
        if cache.0 != sec { cache = (sec, fmt.string(from: Date(timeIntervalSince1970: TimeInterval(sec)))) }
        return cache.1
    }
}

// MARK: - URL handling

enum ERURL {
    /// Splits a request target into (pathname, query) the way the WHATWG URL parser would for an
    /// http(s) URL: backslashes are slashes, dot segments (incl. %2e) are resolved, and characters
    /// outside the path set are percent-encoded.
    static func split(_ target: String) -> (String, String) {
        var t = Substring(target)
        // absolute-form (proxy style): strip scheme://authority
        if let r = t.range(of: "://"), t[t.startIndex..<r.lowerBound].allSatisfy({ $0.isLetter || $0 == "+" || $0 == "-" || $0 == "." }) {
            let afterAuth = t[r.upperBound...]
            if let slash = afterAuth.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
                t = afterAuth[slash...]
            } else {
                t = ""
            }
        }
        if let h = t.firstIndex(of: "#") { t = t[..<h] }
        var query = ""
        if let q = t.firstIndex(of: "?") {
            query = String(t[t.index(after: q)...])
            t = t[..<q]
        }
        return (normalizePath(String(t)), query)
    }

    private static func encodePathByte(_ c: UInt8, into out: inout [UInt8]) {
        let hex: [UInt8] = Array("0123456789ABCDEF".utf8)
        switch c {
        case 0...0x20, 0x22, 0x23, 0x3C, 0x3E, 0x3F, 0x60, 0x7B, 0x7D, 0x7F...0xFF:
            out.append(contentsOf: [37, hex[Int(c >> 4)], hex[Int(c & 15)]])
        default:
            out.append(c)
        }
    }

    static func normalizePath(_ raw: String) -> String {
        var segs: [String] = []
        let path = raw.replacingOccurrences(of: "\\", with: "/")
        var parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.first == "" { parts.removeFirst() } // leading slash
        if parts.isEmpty { return "/" }
        for (idx, p) in parts.enumerated() {
            let isLast = idx == parts.count - 1
            let lp = p.lowercased()
            if lp == ".." || lp == ".%2e" || lp == "%2e." || lp == "%2e%2e" {
                if !segs.isEmpty { segs.removeLast() }
                if isLast { segs.append("") }
            } else if lp == "." || lp == "%2e" {
                if isLast { segs.append("") }
            } else {
                var out: [UInt8] = []
                for c in p.utf8 { encodePathByte(c, into: &out) }
                segs.append(String(decoding: out, as: UTF8.self))
            }
        }
        return "/" + segs.joined(separator: "/")
    }

    /// URLSearchParams(query).get(name): first match, "+" → space, lenient percent-decoding.
    static func param(_ query: String, _ name: String) -> String? {
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if formDecode(kv[0]) == name { return kv.count > 1 ? formDecode(kv[1]) : "" }
        }
        return nil
    }

    private static func hexv(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 55
        case 97...102: return c - 87
        default: return nil
        }
    }

    private static func formDecode(_ s: Substring) -> String {
        let u = Array(s.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(u.count)
        var i = 0
        while i < u.count {
            let c = u[i]
            if c == 43 { out.append(32); i += 1; continue }
            if c == 37, i + 2 < u.count, let h = hexv(u[i + 1]), let l = hexv(u[i + 2]) {
                out.append(h << 4 | l)
                i += 3
                continue
            }
            out.append(c)
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// `decodeURIComponent`: nil where JS would throw URIError.
    static func decodeURIComponent(_ s: String) -> String? {
        let u = Array(s.utf8)
        var out: [UInt8] = []
        var i = 0
        while i < u.count {
            if u[i] == 37 {
                guard i + 2 < u.count, let h = hexv(u[i + 1]), let l = hexv(u[i + 2]) else { return nil }
                // collect one UTF-8 sequence of escapes and validate it as a unit
                let lead = h << 4 | l
                var seq = [lead]
                let need: Int
                switch lead {
                case 0x00...0x7F: need = 0
                case 0xC2...0xDF: need = 1
                case 0xE0...0xEF: need = 2
                case 0xF0...0xF4: need = 3
                default: return nil
                }
                i += 3
                for _ in 0..<need {
                    guard i + 2 < u.count, u[i] == 37, let h2 = hexv(u[i + 1]), let l2 = hexv(u[i + 2]) else { return nil }
                    seq.append(h2 << 4 | l2)
                    i += 3
                }
                guard let str = String(bytes: seq, encoding: .utf8) else { return nil }
                out.append(contentsOf: str.utf8)
            } else {
                out.append(u[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

// MARK: - node:path (POSIX)

enum ERPath {
    /// node `path.normalize` (posix).
    static func normalize(_ path: String) -> String {
        if path.isEmpty { return "." }
        let isAbs = path.hasPrefix("/")
        let trailing = path.hasSuffix("/")
        var out: [Substring] = []
        for seg in path.split(separator: "/", omittingEmptySubsequences: true) {
            if seg == "." { continue }
            if seg == ".." {
                if let last = out.last, last != ".." { out.removeLast() } else if !isAbs { out.append("..") }
                continue
            }
            out.append(seg)
        }
        var r = out.joined(separator: "/")
        if r.isEmpty && !isAbs { r = "." }
        if !r.isEmpty && trailing { r += "/" }
        return isAbs ? "/" + r : r
    }

    /// node `path.join(a, b)`.
    static func join(_ a: String, _ b: String) -> String {
        let parts = [a, b].filter { !$0.isEmpty }
        return parts.isEmpty ? "." : normalize(parts.joined(separator: "/"))
    }
}

// MARK: - Content types (what Bun.file() reports)

enum ERMime {
    static func type(for path: String) -> (String, Bool) {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "html", "htm": return ("text/html;charset=utf-8", false)
        case "js", "mjs", "cjs": return ("text/javascript;charset=utf-8", false)
        case "css": return ("text/css;charset=utf-8", false)
        case "json", "map": return ("application/json;charset=utf-8", false)
        case "txt": return ("text/plain;charset=utf-8", false)
        case "svg": return ("image/svg+xml", false)
        case "webmanifest": return ("application/manifest+json", true)
        case "png": return ("image/png", false)
        case "jpg", "jpeg": return ("image/jpeg", false)
        case "gif": return ("image/gif", false)
        case "webp": return ("image/webp", false)
        case "avif": return ("image/avif", false)
        case "ico": return ("image/x-icon", false)
        case "woff2": return ("font/woff2", false)
        case "woff": return ("font/woff", false)
        case "ttf": return ("font/ttf", false)
        case "otf": return ("font/otf", false)
        case "wasm": return ("application/wasm", false)
        case "pdf": return ("application/pdf", false)
        case "xml": return ("application/xml", true)
        case "mp3": return ("audio/mpeg", false)
        case "mp4": return ("video/mp4", false)
        case "webm": return ("video/webm", false)
        default: return ("application/octet-stream", true)
        }
    }
}
