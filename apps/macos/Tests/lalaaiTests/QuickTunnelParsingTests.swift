import Foundation
import Testing
@testable import lalaai

/// cloudflared's log, as it prints it on stderr.
@Suite struct QuickTunnelParsingTests {
    static let banner = """
    2026-10-05T04:12:01Z INF Thank you for trying Cloudflare Tunnel. Doing so, without a Cloudflare account, is a quick way to experiment and try it out.
    2026-10-05T04:12:01Z INF Requesting new quick Tunnel on trycloudflare.com...
    2026-10-05T04:12:03Z INF +--------------------------------------------------------------------------------------------+
    2026-10-05T04:12:03Z INF |  Your quick Tunnel has been created! Visit it at (it may take some time to be reachable):  |
    2026-10-05T04:12:03Z INF |  https://golden-bright-sensitivity-perry.trycloudflare.com                                 |
    2026-10-05T04:12:03Z INF +--------------------------------------------------------------------------------------------+
    2026-10-05T04:12:03Z INF Version 2026.9.3
    """

    @Test func findsTheTunnelHostname() {
        #expect(QuickTunnel.tunnelURL(in: Self.banner)?.absoluteString == "https://golden-bright-sensitivity-perry.trycloudflare.com")
    }

    @Test func nothingBeforeTheBanner() {
        #expect(QuickTunnel.tunnelURL(in: "") == nil)
        #expect(QuickTunnel.tunnelURL(in: "2026-10-05T04:12:01Z INF Requesting new quick Tunnel on trycloudflare.com...") == nil)
    }

    @Test func cloudflareUnreachableIsNotATunnel() {
        let log = """
        2026-10-05T04:12:01Z INF Requesting new quick Tunnel on trycloudflare.com...
        2026-10-05T04:12:11Z ERR Error requesting new quick Tunnel error="Post \\"https://api.trycloudflare.com/tunnel\\": dial tcp: lookup api.trycloudflare.com: no such host"
        failed to request quick Tunnel: Post "https://api.trycloudflare.com/tunnel": context deadline exceeded
        """
        #expect(QuickTunnel.tunnelURL(in: log) == nil)
    }

    @Test func tunnelAfterAnApiError() {
        let log = "ERR retrying https://api.trycloudflare.com/tunnel\n" + Self.banner
        #expect(QuickTunnel.tunnelURL(in: log)?.host() == "golden-bright-sensitivity-perry.trycloudflare.com")
    }

    @Test func ignoresLookalikeHosts() {
        #expect(QuickTunnel.tunnelURL(in: "|  https://evil.trycloudflare.com.example.net  |") == nil)
        #expect(QuickTunnel.tunnelURL(in: "|  http://plain-http.trycloudflare.com  |") == nil)
    }

    @Test func localUrlOnlyForTheFake() {
        let fake = "INF |  http://127.0.0.1:49216                                                                     |"
        #expect(QuickTunnel.tunnelURL(in: fake) == nil)
        #expect(QuickTunnel.tunnelURL(in: fake, allowLocal: true)?.absoluteString == "http://127.0.0.1:49216")
    }

    @Test func retryBackoff() {
        #expect(LinkHost.retryDelay(attempt: 1) == 5)
        #expect(LinkHost.retryDelay(attempt: 2) == 10)
        #expect(LinkHost.retryDelay(attempt: 3) == 20)
        #expect(LinkHost.retryDelay(attempt: 9) == 30)
    }
}
