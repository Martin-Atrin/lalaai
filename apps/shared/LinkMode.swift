import Foundation

// Shared by the macOS and iOS presenter apps (symlinked into each target as Shared/).

/// How attendees' phones reach the presenter. La Laai runs no server of its own: the relay is either on the
/// presenter's device or one the organiser hosts themselves (web/ in this repo).
enum LinkMode: String, Codable, CaseIterable, Identifiable {
    /// Mac only: relay on this Mac, exposed through a Cloudflare quick tunnel (`https://….trycloudflare.com`).
    case publicLink
    /// Relay on this device; phones on the same Wi-Fi (or the iPhone's hotspot) join over the local network.
    case wifi
    /// A self-hosted relay at `relayURL`.
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .publicLink: "Public link"
        case .wifi: "Wi-Fi / hotspot"
        case .custom: "Custom relay"
        }
    }

    /// Port the on-device relay tries first (the same default as web/relay).
    static let localPort: UInt16 = 8787
}

/// Moves configs saved by older builds, which only stored a relay URL, onto `LinkMode`.
enum LinkMigration {
    /// Host of the hosted relay older builds defaulted to ("La Laai Cloud"). It's retired: nothing connects to it
    /// any more, this is only used to recognise saved configs that pointed at it.
    static let retiredHostedRelayHost = "lalaai-web-production.up.railway.app"

    struct Result: Equatable {
        var mode: LinkMode
        /// What to keep in the custom relay field.
        var relayURL: String
    }

    static func isRetiredHostedRelay(_ url: String) -> Bool {
        URL(string: url.trimmingCharacters(in: .whitespaces))?.host()?.lowercased() == retiredHostedRelayHost
    }

    /// The old Mac "This Mac (Wi-Fi)" choice: a relay on loopback or a private LAN address.
    static func isLocalRelay(_ url: String) -> Bool {
        guard let host = URL(string: url.trimmingCharacters(in: .whitespaces))?.host()?.lowercased() else { return false }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") { return true }
        let o = host.split(separator: ".").compactMap { Int($0) }
        guard o.count == 4 else { return false }
        return o[0] == 10 || (o[0] == 192 && o[1] == 168) || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 169 && o[1] == 254)
    }

    /// Mac: the hosted relay becomes a public link (it was the "reachable from anywhere" choice), a relay on this
    /// Mac becomes Wi-Fi, anything else stays a custom relay.
    static func mac(legacyRelayURL url: String?) -> Result {
        guard let url, !url.trimmingCharacters(in: .whitespaces).isEmpty else { return Result(mode: .publicLink, relayURL: "") }
        if isRetiredHostedRelay(url) { return Result(mode: .publicLink, relayURL: "") }
        if isLocalRelay(url) { return Result(mode: .wifi, relayURL: "") }
        return Result(mode: .custom, relayURL: url)
    }

    /// iPhone: the free iPhone app hosts on Wi-Fi/hotspot, so the hosted relay becomes Wi-Fi. A relay URL the
    /// presenter typed in (their own server, or a Mac on the LAN) stays a custom relay.
    static func phone(legacyRelayURL url: String?) -> Result {
        guard let url, !url.trimmingCharacters(in: .whitespaces).isEmpty, !isRetiredHostedRelay(url) else {
            return Result(mode: .wifi, relayURL: "")
        }
        return Result(mode: .custom, relayURL: url)
    }

    /// A decoded mode must still make sense on this platform, and never point at the retired relay.
    static func sanitize(_ r: Result, publicLinkAvailable: Bool) -> Result {
        var r = r
        if r.mode == .custom, isRetiredHostedRelay(r.relayURL) || r.relayURL.trimmingCharacters(in: .whitespaces).isEmpty {
            r = publicLinkAvailable ? mac(legacyRelayURL: r.relayURL) : phone(legacyRelayURL: r.relayURL)
        }
        if isRetiredHostedRelay(r.relayURL) { r.relayURL = "" }
        if r.mode == .publicLink, !publicLinkAvailable { r.mode = .wifi }
        return r
    }
}
