// Embedded relay — JSON values with JavaScript semantics.
//
// The relay must behave like the Bun reference (web/relay/src/server.ts) message for message, so
// instead of Codable/JSONSerialization we use a tiny JSON model that mirrors what JSON.parse /
// JSON.stringify do: object keys keep JS property order (array-index keys first, ascending, then
// insertion order), numbers are JS doubles printed the way JS prints them, `undefined` fields are
// omitted, and truthiness / Number() / trim() / slice() follow JS rules.
// Foundation only, so it compiles into the macOS app, the iOS app and the lalaai-relay CLI.

import Foundation

/// A JSON value with JS semantics. `nil` (`ERJ?`) plays the role of `undefined`.
indirect enum ERJ {
    case null
    case bool(Bool)
    case num(Double)
    case str(String)
    case arr([ERJ])
    case obj(ERObj)

    static func s(_ v: String) -> ERJ { .str(v) }
    static func n(_ v: Int) -> ERJ { .num(Double(v)) }
    static func n(_ v: Int64) -> ERJ { .num(Double(v)) }
    static func b(_ v: Bool) -> ERJ { .bool(v) }
    /// Ordered object literal; `nil` values are omitted (TS `undefined`).
    static func o(_ pairs: KeyValuePairs<String, ERJ?>) -> ERJ {
        var o = ERObj()
        for (k, v) in pairs { if let v { o.set(k, v) } }
        return .obj(o)
    }
    static func strs(_ a: [String]) -> ERJ { .arr(a.map { .str($0) }) }

    subscript(key: String) -> ERJ? {
        if case let .obj(o) = self { return o[key] }
        return nil
    }

    var string: String? { if case let .str(s) = self { return s }; return nil }
    var object: ERObj? { if case let .obj(o) = self { return o }; return nil }

    /// JS truthiness.
    var truthy: Bool {
        switch self {
        case .null: return false
        case let .bool(b): return b
        case let .num(d): return d != 0 && !d.isNaN
        case let .str(s): return !s.isEmpty
        case .arr, .obj: return true
        }
    }

    func encoded() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(256)
        ERJSONWriter.write(self, into: &out)
        return out
    }
    func encodedData() -> Data { Data(encoded()) }
}

/// JS truthiness of a possibly-undefined value.
@inline(__always) func erTruthy(_ v: ERJ?) -> Bool { v?.truthy ?? false }

/// A JS plain object: property order = array-index keys ascending, then string keys in insertion order.
struct ERObj {
    private(set) var keys: [String] = []
    private var dict: [String: ERJ] = [:]
    private var indexCount = 0

    init() {}

    var count: Int { keys.count }
    var isEmpty: Bool { keys.isEmpty }

    subscript(key: String) -> ERJ? { dict[key] }

    mutating func set(_ key: String, _ value: ERJ) {
        if dict.updateValue(value, forKey: key) != nil { return }
        if let idx = erArrayIndex(key) {
            var lo = 0, hi = indexCount
            while lo < hi {
                let mid = (lo + hi) / 2
                if erArrayIndex(keys[mid])! < idx { lo = mid + 1 } else { hi = mid }
            }
            keys.insert(key, at: lo)
            indexCount += 1
        } else {
            keys.append(key)
        }
    }

    mutating func remove(_ key: String) {
        guard dict.removeValue(forKey: key) != nil, let i = keys.firstIndex(of: key) else { return }
        if i < indexCount { indexCount -= 1 }
        keys.remove(at: i)
    }

    /// `Object.entries` order.
    var entries: [(String, ERJ)] { keys.map { ($0, dict[$0]!) } }
    var values: [ERJ] { keys.map { dict[$0]! } }
}

/// Canonical array index ("0", "17"; not "01", "-1", "4294967295").
func erArrayIndex(_ s: String) -> UInt32? {
    let u = s.utf8
    guard let first = u.first, u.count <= 10 else { return nil }
    if first == UInt8(ascii: "0") { return u.count == 1 ? 0 : nil }
    var v: UInt64 = 0
    for c in u {
        guard c >= 48, c <= 57 else { return nil }
        v = v * 10 + UInt64(c - 48)
    }
    return v < 4_294_967_295 ? UInt32(v) : nil
}

// MARK: - Serialisation (JSON.stringify)

enum ERJSONWriter {
    static func write(_ v: ERJ, into out: inout [UInt8]) {
        switch v {
        case .null: out.append(contentsOf: [110, 117, 108, 108])
        case let .bool(b): out.append(contentsOf: b ? Array("true".utf8) : Array("false".utf8))
        case let .num(d): out.append(contentsOf: d.isFinite ? Array(erJSNumberString(d).utf8) : Array("null".utf8))
        case let .str(s): writeString(s, into: &out)
        case let .arr(a):
            out.append(91)
            for (i, e) in a.enumerated() {
                if i > 0 { out.append(44) }
                write(e, into: &out)
            }
            out.append(93)
        case let .obj(o):
            out.append(123)
            var first = true
            for (k, e) in o.entries {
                if !first { out.append(44) }
                first = false
                writeString(k, into: &out)
                out.append(58)
                write(e, into: &out)
            }
            out.append(125)
        }
    }

    private static let hex: [UInt8] = Array("0123456789abcdef".utf8)

    static func writeString(_ s: String, into out: inout [UInt8]) {
        out.append(34)
        for c in s.utf8 {
            switch c {
            case 34: out.append(92); out.append(34)
            case 92: out.append(92); out.append(92)
            case 8: out.append(92); out.append(98)
            case 9: out.append(92); out.append(116)
            case 10: out.append(92); out.append(110)
            case 12: out.append(92); out.append(102)
            case 13: out.append(92); out.append(114)
            case 0..<32:
                out.append(contentsOf: [92, 117, 48, 48, hex[Int(c >> 4)], hex[Int(c & 15)]])
            default: out.append(c)
            }
        }
        out.append(34)
    }
}

/// `String(number)` in JavaScript (Number::toString, radix 10).
func erJSNumberString(_ d: Double) -> String {
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
    if d == 0 { return "0" }
    if d == d.rounded(.towardZero), abs(d) < 9.0e15 { return String(Int64(d)) }
    let neg = d < 0
    let s = "\(abs(d))" // Swift prints the shortest round-tripping digits, like JS
    let parts = s.split(separator: "e", maxSplits: 1)
    let exp = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    let mant = parts[0].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    let ip = String(mant[0])
    let fp = mant.count > 1 ? String(mant[1]) : ""
    var digits = Array(ip + fp)
    var n = ip.count + exp
    while digits.first == "0" { digits.removeFirst(); n -= 1 }
    while digits.last == "0" { digits.removeLast() }
    let k = digits.count
    var r: String
    if k <= n && n <= 21 {
        r = String(digits) + String(repeating: "0", count: n - k)
    } else if 0 < n && n <= 21 {
        r = String(digits[0..<n]) + "." + String(digits[n...])
    } else if -6 < n && n <= 0 {
        r = "0." + String(repeating: "0", count: -n) + String(digits)
    } else {
        let e = n - 1
        let es = (e < 0 ? "-" : "+") + String(abs(e))
        r = k == 1 ? String(digits) + "e" + es : String(digits[0]) + "." + String(digits[1...]) + "e" + es
    }
    return neg ? "-" + r : r
}

// MARK: - Parsing (JSON.parse)

struct ERJSONParser {
    private let b: [UInt8]
    private var i = 0
    private var depth = 0

    /// Parses a complete JSON text; nil on any syntax error (JSON.parse would throw).
    static func parse(_ bytes: [UInt8]) -> ERJ? {
        var p = ERJSONParser(b: bytes)
        p.ws()
        guard let v = p.value() else { return nil }
        p.ws()
        return p.i == p.b.count ? v : nil
    }

    private init(b: [UInt8]) { self.b = b }

    private mutating func ws() {
        while i < b.count, b[i] == 32 || b[i] == 9 || b[i] == 10 || b[i] == 13 { i += 1 }
    }

    private mutating func lit(_ s: StaticString) -> Bool {
        let n = s.utf8CodeUnitCount
        guard i + n <= b.count else { return false }
        let p = s.utf8Start
        for k in 0..<n where b[i + k] != p[k] { return false }
        i += n
        return true
    }

    private mutating func value() -> ERJ? {
        guard i < b.count else { return nil }
        switch b[i] {
        case UInt8(ascii: "{"):
            depth += 1
            guard depth < 512 else { return nil }
            defer { depth -= 1 }
            i += 1
            var o = ERObj()
            ws()
            if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .obj(o) }
            while true {
                ws()
                guard i < b.count, b[i] == 34, let k = string() else { return nil }
                ws()
                guard i < b.count, b[i] == UInt8(ascii: ":") else { return nil }
                i += 1
                ws()
                guard let v = value() else { return nil }
                o.set(k, v)
                ws()
                guard i < b.count else { return nil }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "}") { i += 1; return .obj(o) }
                return nil
            }
        case UInt8(ascii: "["):
            depth += 1
            guard depth < 512 else { return nil }
            defer { depth -= 1 }
            i += 1
            var a: [ERJ] = []
            ws()
            if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .arr(a) }
            while true {
                ws()
                guard let v = value() else { return nil }
                a.append(v)
                ws()
                guard i < b.count else { return nil }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "]") { i += 1; return .arr(a) }
                return nil
            }
        case 34:
            return string().map { .str($0) }
        case UInt8(ascii: "t"): return lit("true") ? .bool(true) : nil
        case UInt8(ascii: "f"): return lit("false") ? .bool(false) : nil
        case UInt8(ascii: "n"): return lit("null") ? .null : nil
        default:
            return number()
        }
    }

    private mutating func number() -> ERJ? {
        let start = i
        func digit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
        if i < b.count, b[i] == UInt8(ascii: "-") { i += 1 }
        guard i < b.count, digit(b[i]) else { return nil }
        if b[i] == 48 { i += 1 } else { while i < b.count, digit(b[i]) { i += 1 } }
        if i < b.count, b[i] == UInt8(ascii: ".") {
            i += 1
            guard i < b.count, digit(b[i]) else { return nil }
            while i < b.count, digit(b[i]) { i += 1 }
        }
        if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
            i += 1
            if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
            guard i < b.count, digit(b[i]) else { return nil }
            while i < b.count, digit(b[i]) { i += 1 }
        }
        let s = String(decoding: b[start..<i], as: UTF8.self)
        return Double(s).map { .num($0) }
    }

    private static func hexVal(_ c: UInt8) -> UInt16? {
        switch c {
        case 48...57: return UInt16(c - 48)
        case 65...70: return UInt16(c - 55)
        case 97...102: return UInt16(c - 87)
        default: return nil
        }
    }

    /// Parses a string literal starting at the opening quote.
    private mutating func string() -> String? {
        i += 1
        let start = i
        // fast path: no escapes
        while i < b.count {
            let c = b[i]
            if c == 34 {
                let s = String(decoding: b[start..<i], as: UTF8.self)
                i += 1
                return s
            }
            if c == 92 { break }
            if c < 32 { return nil }
            i += 1
        }
        guard i < b.count else { return nil }
        // slow path: decode into UTF-16 units (JSON escapes are UTF-16)
        var units: [UInt16] = Array(String(decoding: b[start..<i], as: UTF8.self).utf16)
        var raw: [UInt8] = []
        func flushRaw() {
            if !raw.isEmpty { units.append(contentsOf: String(decoding: raw, as: UTF8.self).utf16); raw.removeAll() }
        }
        while i < b.count {
            let c = b[i]
            if c == 34 {
                flushRaw()
                i += 1
                return String(decoding: units, as: UTF16.self)
            }
            if c < 32 { return nil }
            if c == 92 {
                flushRaw()
                i += 1
                guard i < b.count else { return nil }
                let e = b[i]
                i += 1
                switch e {
                case 34: units.append(34)
                case 92: units.append(92)
                case 47: units.append(47)
                case 98: units.append(8)
                case 102: units.append(12)
                case 110: units.append(10)
                case 114: units.append(13)
                case 116: units.append(9)
                case 117:
                    guard i + 4 <= b.count else { return nil }
                    var u: UInt16 = 0
                    for k in 0..<4 {
                        guard let h = Self.hexVal(b[i + k]) else { return nil }
                        u = u << 4 | h
                    }
                    i += 4
                    units.append(u)
                default: return nil
                }
                continue
            }
            raw.append(c)
            i += 1
        }
        return nil
    }
}

// MARK: - JS string / number helpers

private func erIsJSWhitespace(_ v: UInt32) -> Bool {
    switch v {
    case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
        return true
    default:
        return false
    }
}

/// `String.prototype.trim`.
func erTrim(_ s: String) -> String {
    let sc = s.unicodeScalars
    guard let a = sc.firstIndex(where: { !erIsJSWhitespace($0.value) }) else { return "" }
    let z = sc.lastIndex(where: { !erIsJSWhitespace($0.value) })!
    if a == sc.startIndex && z == sc.index(before: sc.endIndex) { return s }
    return String(sc[a...z])
}

/// `String.prototype.length` (UTF-16 code units).
@inline(__always) func erLen(_ s: String) -> Int { s.utf16.count }

/// `s.slice(0, max)` in UTF-16 units. A surrogate pair cut in half loses its lone high half
/// (Swift strings can't hold lone surrogates; JS would emit "\ud83d").
func erSlice(_ s: String, _ max: Int) -> String {
    let u = s.utf16
    guard u.count > max else { return s }
    var units = Array(u.prefix(max))
    if let last = units.last, UTF16.isLeadSurrogate(last) { units.removeLast() }
    return String(decoding: units, as: UTF16.self)
}

/// server.ts `clean(s, max)`: strings are trimmed and capped, anything else is "".
func erClean(_ v: ERJ?, _ max: Int) -> String {
    guard case let .str(s)? = v else { return "" }
    return erSlice(erTrim(s), max)
}

/// `Number(string)`.
func erJSNumber(_ str: String) -> Double {
    let s = erTrim(str)
    if s.isEmpty { return 0 }
    switch s {
    case "Infinity", "+Infinity": return .infinity
    case "-Infinity": return -.infinity
    default: break
    }
    let u = Array(s.utf8)
    if u.count > 2, u[0] == 48 {
        let radix: Int?
        switch u[1] {
        case UInt8(ascii: "x"), UInt8(ascii: "X"): radix = 16
        case UInt8(ascii: "o"), UInt8(ascii: "O"): radix = 8
        case UInt8(ascii: "b"), UInt8(ascii: "B"): radix = 2
        default: radix = nil
        }
        if let radix {
            var v = 0.0
            for c in u[2...] {
                let d: Int
                switch c {
                case 48...57: d = Int(c - 48)
                case 65...90: d = Int(c - 55)
                case 97...122: d = Int(c - 87)
                default: return .nan
                }
                guard d < radix else { return .nan }
                v = v * Double(radix) + Double(d)
            }
            return v
        }
    }
    // StrDecimalLiteral: [+-]? (digits [. digits?] | . digits) ([eE][+-]? digits)?
    var i = 0
    func digit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
    if i < u.count, u[i] == 43 || u[i] == 45 { i += 1 }
    var mant = 0
    while i < u.count, digit(u[i]) { i += 1; mant += 1 }
    if i < u.count, u[i] == 46 {
        i += 1
        while i < u.count, digit(u[i]) { i += 1; mant += 1 }
    }
    guard mant > 0 else { return .nan }
    if i < u.count, u[i] == 101 || u[i] == 69 {
        i += 1
        if i < u.count, u[i] == 43 || u[i] == 45 { i += 1 }
        var e = 0
        while i < u.count, digit(u[i]) { i += 1; e += 1 }
        guard e > 0 else { return .nan }
    }
    guard i == u.count else { return .nan }
    return Double(s) ?? .nan
}

/// `Number(value)` for a JSON value (`undefined` → NaN).
func erJSNumber(_ v: ERJ?) -> Double {
    guard let v else { return .nan }
    switch v {
    case .null: return 0
    case let .bool(b): return b ? 1 : 0
    case let .num(d): return d
    case let .str(s): return erJSNumber(s)
    case .obj: return .nan
    case let .arr(a):
        if a.isEmpty { return 0 }
        if a.count > 1 { return .nan }
        switch a[0] {
        case .null: return 0
        case .bool, .obj: return .nan
        case let .num(d): return d
        case let .str(s): return erJSNumber(s)
        case .arr: return erJSNumber(a[0])
        }
    }
}

/// `Object.entries(v ?? {})` for a JSON value.
func erEntries(_ v: ERJ?) -> [(String, ERJ)] {
    guard let v else { return [] }
    switch v {
    case let .obj(o): return o.entries
    case let .arr(a): return a.enumerated().map { (String($0.offset), $0.element) }
    case let .str(s): return s.utf16.enumerated().map { (String($0.offset), .str(String(decoding: [$0.element], as: UTF16.self))) }
    default: return []
    }
}

/// Thrown where the reference implementation would throw a TypeError (and the caller would turn
/// it into a 500 / a logged "handler error").
struct ERJSTypeError: Error { var what: String }
