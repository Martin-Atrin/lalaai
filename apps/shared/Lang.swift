import Foundation
import Translation

// Shared by the macOS and iOS presenter apps (symlinked into each target as Shared/).

enum Lang {
    static func base(_ id: String) -> String {
        String(id.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "en")
    }

    /// Canonical code that keeps meaningful variants: "zh_tw" → "zh-TW", "pt-pt" → "pt-PT", "EN" → "en".
    static func norm(_ id: String) -> String {
        let parts = id.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let first = parts.first else { return "en" }
        var out = [first.lowercased()]
        for p in parts.dropFirst() {
            if p.count == 4, p.allSatisfy(\.isLetter) { out.append(p.prefix(1).uppercased() + p.dropFirst().lowercased()) }
            else if p.count == 2, p.allSatisfy(\.isLetter) { out.append(p.uppercased()) }
        }
        return out.joined(separator: "-")
    }

    /// Translation language to use for a speech locale. Chinese keeps its script variant (Traditional vs Simplified),
    /// other languages use the base so every audience variant can be translated from it.
    static func fromSpeechLocale(_ id: String) -> String {
        let n = norm(id)
        switch n {
        case "zh-TW": return "zh-TW"
        case "zh-HK", "yue-HK": return "zh-HK"
        case "pt-PT": return "pt-PT"
        default: return base(n)
        }
    }

    /// Localized name, e.g. "Chinese (Taiwan) · 中文（台灣）".
    static func name(_ code: String) -> String {
        let local = displayName(code)
        let native = Locale(identifier: code).localizedString(forIdentifier: code)?.capitalized
        if let native, native != local { return "\(local) · \(native)" }
        return local
    }

    /// Name in the Mac's UI language, variant-aware: "Portuguese (Portugal)".
    static func displayName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code)?.capitalized
            ?? Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code
    }

    static func flag(_ code: String) -> String {
        // Regional variants show their region's flag (zh-TW → 🇹🇼, pt-PT → 🇵🇹, en-AU → 🇦🇺).
        let parts = norm(code).split(separator: "-")
        if let region = parts.dropFirst().first(where: { $0.count == 2 }) {
            let scalars = region.unicodeScalars.compactMap { UnicodeScalar(0x1F1E6 + $0.value - 65) }
            return String(String.UnicodeScalarView(scalars))
        }
        let map = ["en": "🇬🇧", "de": "🇩🇪", "fr": "🇫🇷", "es": "🇪🇸", "it": "🇮🇹", "pt": "🇧🇷", "nl": "🇳🇱", "pl": "🇵🇱",
                   "ru": "🇷🇺", "uk": "🇺🇦", "tr": "🇹🇷", "ar": "🇸🇦", "zh": "🇨🇳", "ja": "🇯🇵", "ko": "🇰🇷", "hi": "🇮🇳",
                   "id": "🇮🇩", "th": "🇹🇭", "vi": "🇻🇳", "cs": "🇨🇿", "sk": "🇸🇰", "sv": "🇸🇪", "da": "🇩🇰", "nb": "🇳🇴",
                   "fi": "🇫🇮", "el": "🇬🇷", "he": "🇮🇱", "hu": "🇭🇺", "ro": "🇷🇴", "ms": "🇲🇾", "ca": "🇪🇸", "hr": "🇭🇷",
                   "yue": "🇭🇰", "my": "🇲🇲", "lo": "🇱🇦", "km": "🇰🇭", "shn": "🇲🇲", "bn": "🇧🇩", "ur": "🇵🇰", "fa": "🇮🇷",
                   "fil": "🇵🇭", "ne": "🇳🇵", "si": "🇱🇰", "sr": "🇷🇸", "bg": "🇧🇬", "sl": "🇸🇮", "lt": "🇱🇹", "lv": "🇱🇻",
                   "et": "🇪🇪", "sw": "🇰🇪", "kk": "🇰🇿", "uz": "🇺🇿", "mn": "🇲🇳", "hy": "🇦🇲", "ka": "🇬🇪"]
        return map[base(code)] ?? "🌐"
    }

    /// Languages the on-device NLLB helper covers (keep in sync with translator/server.py).
    static let nllbLanguages = ["af", "am", "ar", "az", "be", "bg", "bn", "bs", "ca", "cs", "cy", "da", "de", "el", "en", "es",
        "et", "eu", "fa", "fi", "fil", "fr", "ga", "gl", "gu", "he", "hi", "hr", "hu", "hy", "id", "is", "it", "ja", "ka",
        "kk", "km", "kn", "ko", "lo", "lt", "lv", "mk", "ml", "mn", "mr", "ms", "my", "nb", "ne", "nl", "pa", "pl", "pt",
        "pt-PT", "ro", "ru", "shn", "si", "sk", "sl", "sq", "sr", "sv", "sw", "ta", "te", "th", "tr", "uk", "ur", "uz", "vi",
        "zh", "zh-TW", "zh-HK", "yue"]

    /// Every language Apple Translation offers on this Mac, keeping variants (zh-TW, pt-PT, en-GB, es-MX…).
    /// A variant whose base isn't offered on its own (ar-AE) is listed under its base code.
    static func translationLanguages() async -> [String] {
        let ids = await LanguageAvailability().supportedLanguages.map { norm($0.minimalIdentifier) }
        let set = Set(ids)
        let codes = Set(ids.map { id -> String in
            let b = base(id)
            return id != b && !set.contains(b) ? b : id
        })
        return codes.sorted { displayName($0) < displayName($1) }
    }

    /// This device's LAN IPv4 address, so phones on the same Wi-Fi can reach a relay running here.
    static func lanIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var candidates: [(String, String)] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            // en* = Wi-Fi/Ethernet. bridge* = the iPhone's Personal Hotspot (172.20.10.1) or a Mac's Internet
            // Sharing; only used when there's no Wi-Fi address, so a VM bridge never wins over Wi-Fi.
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254.") else { continue } // link-local: no DHCP, phones can't reach it
            candidates.append((name, ip))
        }
        return candidates.sorted { ($0.0.hasPrefix("en") ? 0 : 1, $0.0) < ($1.0.hasPrefix("en") ? 0 : 1, $1.0) }.first?.1
    }
}
