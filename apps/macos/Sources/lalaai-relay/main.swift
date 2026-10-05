// lalaai-relay: the embedded Swift relay as a standalone process, for the conformance suite
// (web/relay/test: RELAY_CMD=… bun test) and for headless hosting.
// Env (same as web/relay/src/server.ts): PORT, HOST (127.0.0.1/localhost/::1 = loopback only),
// STATIC_DIR, PUBLIC_URL.

import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

let env = ProcessInfo.processInfo.environment
let host = env["HOST"] ?? "0.0.0.0"
var options = EmbeddedRelay.Options()
options.port = UInt16(env["PORT"] ?? "") ?? 8787
options.bindAllInterfaces = !["127.0.0.1", "localhost", "::1"].contains(host)
options.staticDir = env["STATIC_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
options.publicURL = env["PUBLIC_URL"].flatMap { $0.isEmpty ? nil : $0 }

let relay = EmbeddedRelay(options: options)
relay.onLog = { line in print(line) }

Task {
    do {
        _ = try await relay.start()
    } catch {
        FileHandle.standardError.write(Data("lalaai-relay: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
dispatchMain()
