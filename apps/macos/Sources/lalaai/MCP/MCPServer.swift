import Foundation
import Network

/// What the MCP tools can see/do. Implemented by AppModel (on the main actor).
@MainActor
protocol MCPContext: AnyObject {
    func mcpPresentation() -> [String: Any]
    func mcpTranscript(lastN: Int) -> [String: Any]
    func mcpQuestions() -> [String: Any]
    func mcpPendingJobs() -> [[String: Any]]
    func mcpJob(matchId: String) -> [String: Any]?
    func mcpSubmitIcebreakers(matchId: String, byLang: [String: [Icebreaker]]) async -> String
}

/// Minimal MCP server over Streamable HTTP (stateless JSON responses), bound to localhost.
/// Any MCP client (Claude Code, Codex, Gemini CLI, Claude Desktop) can connect to http://127.0.0.1:<port>/mcp.
final class MCPServer: @unchecked Sendable {
    let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "lalaai.mcp")
    @MainActor weak var context: MCPContext?

    init(port: UInt16) { self.port = port }

    var url: String { "http://127.0.0.1:\(port)/mcp" }

    func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.start(queue: queue)
        listener = l
    }

    func stop() { listener?.cancel(); listener = nil }

    // MARK: HTTP plumbing

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        read(conn, buffer: Data())
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = HTTPRequest.parse(buf) {
                Task { await self.respond(conn, req) }
            } else if done || err != nil || buf.count > 4 << 20 {
                conn.cancel()
            } else {
                self.read(conn, buffer: buf)
            }
        }
    }

    private func send(_ conn: NWConnection, status: String, body: Data, contentType: String = "application/json") {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        head += "Access-Control-Allow-Origin: *\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func respond(_ conn: NWConnection, _ req: HTTPRequest) async {
        guard req.path.hasPrefix("/mcp") else { return send(conn, status: "404 Not Found", body: Data()) }
        guard req.method == "POST" else { return send(conn, status: "405 Method Not Allowed", body: Data()) }
        guard let json = try? JSONSerialization.jsonObject(with: req.body) else {
            return send(conn, status: "400 Bad Request", body: Self.rpcError(nil, -32700, "parse error"))
        }
        if let batch = json as? [[String: Any]] {
            var results: [Any] = []
            for m in batch { if let r = await handleRPC(m) { results.append(r) } }
            if results.isEmpty { return send(conn, status: "202 Accepted", body: Data()) }
            return send(conn, status: "200 OK", body: try! JSONSerialization.data(withJSONObject: results))
        }
        guard let msg = json as? [String: Any] else { return send(conn, status: "400 Bad Request", body: Data()) }
        if let r = await handleRPC(msg) {
            send(conn, status: "200 OK", body: try! JSONSerialization.data(withJSONObject: r))
        } else {
            send(conn, status: "202 Accepted", body: Data())
        }
    }

    private static func rpcError(_ id: Any?, _ code: Int, _ msg: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": msg]])
    }

    // MARK: JSON-RPC

    private func handleRPC(_ m: [String: Any]) async -> [String: Any]? {
        let id = m["id"]
        let method = m["method"] as? String ?? ""
        guard id != nil else { return nil } // notification
        func ok(_ result: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id!, "result": result] }
        switch method {
        case "initialize":
            let params = m["params"] as? [String: Any]
            let version = params?["protocolVersion"] as? String ?? "2025-06-18"
            return ok([
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "lalaai", "version": "0.1.0"],
                "instructions": "lalaai live-talk context: the presenter's slides, live transcript, audience questions, and icebreaker jobs for attendees who matched. Use submit_icebreakers to deliver icebreakers.",
            ])
        case "ping":
            return ok([:])
        case "tools/list":
            return ok(["tools": Self.tools])
        case "tools/call":
            let p = m["params"] as? [String: Any] ?? [:]
            let name = p["name"] as? String ?? ""
            let args = p["arguments"] as? [String: Any] ?? [:]
            let (value, isError) = await callTool(name, args)
            let text: String
            if let s = value as? String { text = s }
            else { text = String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data(), as: UTF8.self) }
            return ok(["content": [["type": "text", "text": text]], "isError": isError])
        default:
            return ["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "method not found: \(method)"]]
        }
    }

    private func callTool(_ name: String, _ args: [String: Any]) async -> (Any, Bool) {
        guard let ctx = await MainActor.run(body: { self.context }) else { return ("lalaai is not ready", true) }
        switch name {
        case "get_presentation":
            return (await MainActor.run { ctx.mcpPresentation() }, false)
        case "get_transcript":
            let n = (args["last_n"] as? Int) ?? 60
            return (await MainActor.run { ctx.mcpTranscript(lastN: n) }, false)
        case "get_questions":
            return (await MainActor.run { ctx.mcpQuestions() }, false)
        case "list_icebreaker_jobs":
            return (await MainActor.run { ctx.mcpPendingJobs() }, false)
        case "get_icebreaker_job":
            guard let mid = args["match_id"] as? String, let job = await MainActor.run(body: { ctx.mcpJob(matchId: mid) }) else {
                return ("unknown match_id", true)
            }
            return (job, false)
        case "submit_icebreakers":
            guard let mid = args["match_id"] as? String else { return ("match_id required", true) }
            let parsed = Self.parseIcebreakers(args["icebreakers_by_lang"] ?? args["icebreakers"])
            if parsed.isEmpty { return ("icebreakers_by_lang must map language code -> [{topic, prompt}]", true) }
            let msg = await ctx.mcpSubmitIcebreakers(matchId: mid, byLang: parsed)
            return (msg, false)
        default:
            return ("unknown tool \(name)", true)
        }
    }

    static func parseIcebreakers(_ raw: Any?) -> [String: [Icebreaker]] {
        func list(_ v: Any?) -> [Icebreaker] {
            (v as? [[String: Any]] ?? []).compactMap { d in
                guard let p = d["prompt"] as? String, !p.isEmpty else { return nil }
                return Icebreaker(topic: (d["topic"] as? String) ?? "", prompt: p)
            }
        }
        if let dict = raw as? [String: Any] {
            var out: [String: [Icebreaker]] = [:]
            for (k, v) in dict { let l = list(v); if !l.isEmpty { out[k.lowercased()] = l } }
            return out
        }
        let l = list(raw)
        return l.isEmpty ? [:] : ["en": l]
    }

    static let tools: [[String: Any]] = [
        [
            "name": "get_presentation",
            "description": "The presenter's slide deck as plain text, one entry per slide, plus the talk title.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "get_transcript",
            "description": "Recent live transcript of what the presenter said (presenter language), oldest first.",
            "inputSchema": ["type": "object", "properties": ["last_n": ["type": "integer", "description": "number of recent lines (default 60)"]]],
        ],
        [
            "name": "get_questions",
            "description": "Audience questions with like counts, translated to the presenter language.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "list_icebreaker_jobs",
            "description": "Pending icebreaker jobs: pairs of attendees who matched through a question and are waiting for conversation starters.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "get_icebreaker_job",
            "description": "Details of one icebreaker job: both people (name, language, tagline) and the question that connected them.",
            "inputSchema": ["type": "object", "properties": ["match_id": ["type": "string"]], "required": ["match_id"]],
        ],
        [
            "name": "submit_icebreakers",
            "description": "Deliver 3 icebreakers to the matched pair. Provide them in each person's language: {\"de\": [{\"topic\": \"...\", \"prompt\": \"...\"}], \"cs\": [...]}. topic = 2-5 words, prompt = one friendly, specific opener question grounded in the talk and their shared question.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "match_id": ["type": "string"],
                    "icebreakers_by_lang": [
                        "type": "object",
                        "description": "language code -> list of {topic, prompt}",
                        "additionalProperties": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": ["topic": ["type": "string"], "prompt": ["type": "string"]],
                                "required": ["topic", "prompt"],
                            ],
                        ],
                    ],
                ],
                "required": ["match_id", "icebreakers_by_lang"],
            ],
        ],
    ]
}

struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    /// Returns nil until the full request (headers + Content-Length body) is buffered.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<range.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let len = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = range.upperBound
        guard data.count - bodyStart >= len else { return nil }
        return HTTPRequest(method: String(first[0]), path: String(first[1]), headers: headers,
                           body: data.subdata(in: bodyStart..<(bodyStart + len)))
    }
}
