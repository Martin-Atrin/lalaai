import Foundation
import Testing
@testable import lalaai

/// Saved configs from builds that only had a relay URL ("La Laai Cloud", "This Mac", or a custom relay).
@Suite struct LinkMigrationTests {
    static let retired = "https://lalaai-web-production.up.railway.app"

    private func macConfig(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    @Test func hostedRelayBecomesPublicLinkOnMac() throws {
        let c = try macConfig(#"{"relayURL":"\#(Self.retired)","title":"Kept"}"#)
        #expect(c.linkMode == .publicLink)
        #expect(c.relayURL == "")
        #expect(c.title == "Kept")
    }

    @Test(arguments: [
        "https://lalaai-web-production.up.railway.app/",
        " HTTPS://LALAAI-WEB-PRODUCTION.UP.RAILWAY.APP ",
        "https://lalaai-web-production.up.railway.app/m/some-room",
    ])
    func hostedRelayVariantsAreRecognised(url: String) {
        #expect(LinkMigration.isRetiredHostedRelay(url))
        #expect(LinkMigration.mac(legacyRelayURL: url).mode == .publicLink)
        #expect(LinkMigration.phone(legacyRelayURL: url).mode == .wifi)
    }

    @Test(arguments: ["http://localhost:8787", "http://127.0.0.1:8787", "http://192.168.1.20:8787",
                      "http://10.0.0.5:8787", "http://172.20.10.2:8787", "http://my-mac.local:8787"])
    func thisMacBecomesWifiOnMac(url: String) throws {
        let c = try macConfig(#"{"relayURL":"\#(url)"}"#)
        #expect(c.linkMode == .wifi)
        #expect(c.relayURL == "")
    }

    @Test func selfHostedRelayStaysCustom() throws {
        let c = try macConfig(#"{"relayURL":"https://relay.example.org"}"#)
        #expect(c.linkMode == .custom)
        #expect(c.relayURL == "https://relay.example.org")
        #expect(LinkMigration.phone(legacyRelayURL: "https://relay.example.org") == .init(mode: .custom, relayURL: "https://relay.example.org"))
    }

    @Test func notPrivateAddressesStayCustom() {
        #expect(!LinkMigration.isLocalRelay("http://172.32.0.1:8787"))
        #expect(!LinkMigration.isLocalRelay("http://8.8.8.8:8787"))
        #expect(LinkMigration.mac(legacyRelayURL: "http://203.0.113.9:8787").mode == .custom)
    }

    @Test func freshInstallDefaults() throws {
        #expect(try macConfig("{}").linkMode == .publicLink)
        #expect(Config().linkMode == .publicLink)
        #expect(LinkMigration.phone(legacyRelayURL: nil).mode == .wifi)
    }

    @Test func savedModeWins() throws {
        let c = try macConfig(#"{"linkMode":"wifi","relayURL":"https://relay.example.org"}"#)
        #expect(c.linkMode == .wifi)
        #expect(c.relayURL == "https://relay.example.org") // kept for when they switch back to Custom
    }

    @Test func customPointingAtRetiredRelayIsRepaired() throws {
        let c = try macConfig(#"{"linkMode":"custom","relayURL":"\#(Self.retired)"}"#)
        #expect(c.linkMode == .publicLink)
        #expect(c.relayURL == "")
        let p = LinkMigration.sanitize(.init(mode: .custom, relayURL: Self.retired), publicLinkAvailable: false)
        #expect(p == .init(mode: .wifi, relayURL: ""))
    }

    @Test func iPhoneNeverGetsPublicLink() {
        #expect(LinkMigration.sanitize(.init(mode: .publicLink, relayURL: ""), publicLinkAvailable: false).mode == .wifi)
    }

    @Test func roundTripKeepsMode() throws {
        var c = Config()
        c.linkMode = .custom
        c.relayURL = "https://relay.example.org"
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        #expect(back.linkMode == .custom)
        #expect(back.relayURL == "https://relay.example.org")
    }
}
