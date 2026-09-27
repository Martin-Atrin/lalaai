import Foundation

/// Which LLM subscription the presenter connected. The agent CLI is run headless with the lalaai MCP server attached.
enum LLMProvider: String, CaseIterable, Codable, Identifiable {
    case none, claude, codex, gemini, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "Off"
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .custom: return "Custom"
        }
    }
    var binary: String { rawValue }
}

/// Runs the presenter's agent CLI for one icebreaker job. The agent reads context through MCP tools
/// and delivers via `submit_icebreakers`; if it instead prints JSON, we parse that as a fallback.
final class AgentRunner: @unchecked Sendable {
    let provider: LLMProvider
    let mcpURL: String
    let model: String?
    /// For `.custom`: a shell command. Gets LALAAI_MCP_URL, LALAAI_MATCH_ID, LALAAI_PROMPT in its environment.
    let customCommand: String

    init(provider: LLMProvider, mcpURL: String, model: String? = nil, customCommand: String = "") {
        self.provider = provider
        self.mcpURL = mcpURL
        self.model = model?.isEmpty == false ? model : nil
        self.customCommand = customCommand
    }

    static func prompt(for job: IcebreakerJob) -> String {
        """
        You are the icebreaker assistant for a live talk using lalaai. Two attendees matched because of an audience question and want to talk after the session.

        Steps:
        1. Call get_icebreaker_job with match_id "\(job.matchId)" to see both people and their shared question.
        2. Call get_presentation and get_transcript (last_n 80) to understand what the talk actually covered.
        3. Write exactly 3 icebreakers that connect the shared question to specific content from the talk, and to their taglines if present. Be warm, concrete and short. No generic "what do you do?".
        4. Call submit_icebreakers with match_id "\(job.matchId)" and icebreakers_by_lang containing the 3 icebreakers written natively in EACH of these languages: \(job.langs.joined(separator: ", ")).

        If you cannot call tools, instead reply with ONLY this JSON and nothing else:
        {"icebreakers_by_lang": {"<lang>": [{"topic": "2-5 words", "prompt": "opener question"}]}}
        """
    }

    /// Resolves the user's login-shell PATH once; GUI apps don't inherit it.
    static let loginPath: String = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "echo __P__$PATH"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let path = s.components(separatedBy: "__P__").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let extra = ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.bun/bin"]
        return ([path] + extra + ["/usr/bin", "/bin"]).filter { !$0.isEmpty }.joined(separator: ":")
    }()

    static func locate(_ bin: String) -> String? {
        for dir in loginPath.split(separator: ":") {
            let p = "\(dir)/\(bin)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    struct RunResult { var out: String; var err: String; var status: Int32 }

    /// Real end-to-end check: the agent must call a La Laai MCP tool and answer. Returns seconds taken.
    func probe() async -> Result<TimeInterval, Error> {
        guard provider != .none else { return .failure(Err("No provider selected")) }
        let t0 = Date()
        do {
            let r = try await invoke(prompt: "Call the lalaai get_presentation tool. Then reply with exactly the word LALAAI_OK and nothing else.",
                                     workName: "probe", env: ["LALAAI_MATCH_ID": "probe"], timeout: 90)
            if r.out.contains("LALAAI_OK") { return .success(Date().timeIntervalSince(t0)) }
            return .failure(Err(Self.diagnose(r) ?? "The agent answered but didn't confirm the tool call. Output: \(r.out.suffix(160))"))
        } catch { return .failure(error) }
    }

    /// Runs the agent. Returns parsed JSON icebreakers if the agent printed them (tool-call path returns [:]).
    /// Throws a readable reason when the agent failed.
    func run(job: IcebreakerJob) async throws -> [String: [Icebreaker]] {
        let r = try await invoke(prompt: Self.prompt(for: job), workName: job.matchId,
                                 env: ["LALAAI_MATCH_ID": job.matchId], timeout: 140)
        let parsed = Self.extractJSON(r.out)
        if parsed.isEmpty, let reason = Self.diagnose(r) { throw Err(reason) }
        return parsed
    }

    /// Launches the provider's CLI headless with the La Laai MCP server attached.
    private func invoke(prompt: String, workName: String, env extra: [String: String], timeout: TimeInterval) async throws -> RunResult {
        var env = extra
        env["LALAAI_MCP_URL"] = mcpURL
        env["LALAAI_PROMPT"] = prompt
        if provider == .custom {
            guard !customCommand.isEmpty else { throw Err("Set a command first") }
            return try await Self.run("/bin/zsh", ["-lc", customCommand], extraEnv: env, timeout: timeout)
        }
        guard let bin = Self.locate(provider.binary) else { throw Err("\(provider.binary) not found on PATH") }
        let tmp = FileManager.default.temporaryDirectory.appending(path: "lalaai-agent-\(workName)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var args: [String]
        switch provider {
        case .none, .custom:
            throw Err("No provider selected")
        case .claude:
            let cfg = #"{"mcpServers":{"lalaai":{"type":"http","url":"\#(mcpURL)"}}}"#
            args = ["-p", prompt, "--mcp-config", cfg, "--strict-mcp-config",
                    "--allowedTools", "mcp__lalaai__get_presentation,mcp__lalaai__get_transcript,mcp__lalaai__get_questions,mcp__lalaai__get_icebreaker_job,mcp__lalaai__list_icebreaker_jobs,mcp__lalaai__submit_icebreakers",
                    "--output-format", "text"]
            if let model { args += ["--model", model] }
        case .codex:
            args = ["exec", "--skip-git-repo-check", "-s", "read-only",
                    "-c", "mcp_servers.lalaai.url=\"\(mcpURL)\"",
                    // Auto-approve ONLY La Laai's tools; everything else stays locked down (read-only sandbox, no approvals).
                    "-c", "mcp_servers.lalaai.default_tools_approval_mode=\"approve\"",
                    "-c", "approval_policy=\"never\"",
                    "-C", tmp.path]
            if let model { args += ["-m", model] }
            args.append(prompt)
        case .gemini:
            let dir = tmp.appending(path: ".gemini")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let settings = #"{"mcpServers":{"lalaai":{"httpUrl":"\#(mcpURL)","trust":true}}}"#
            try settings.write(to: dir.appending(path: "settings.json"), atomically: true, encoding: .utf8)
            args = ["-p", prompt, "--allowed-mcp-server-names", "lalaai", "--approval-mode", "yolo"]
            if let model { args += ["-m", model] }
        }
        return try await Self.run(bin, args, cwd: tmp, extraEnv: env, timeout: timeout)
    }

    /// Turns CLI output into one human sentence (with a fix hint for known cases). nil = looks fine.
    static func diagnose(_ r: RunResult) -> String? {
        let all = r.out + "\n" + r.err
        let lower = all.lowercased()
        if lower.contains("requires a newer version") {
            return "Your CLI is too old for its default model. Update it, or set Model (e.g. gpt-5.5 for Codex)."
        }
        if lower.contains("not logged in") || lower.contains("please run /login") || lower.contains("set an auth method") {
            return "The CLI isn't logged in. Run it once in Terminal and log in."
        }
        if lower.contains("requires approval") { return "The CLI blocked La Laai's tools (approval required)." }
        if lower.contains("not supported when using") {
            return "That model isn't available on your plan. Pick another in Model."
        }
        let errLine = all.split(separator: "\n").map(String.init).last { $0.localizedCaseInsensitiveContains("error") }
        if let errLine {
            // prefer the JSON "message" if the line carries one
            if let m = errLine.range(of: #""message":"([^"]+)""#, options: .regularExpression) {
                return String(errLine[m]).replacingOccurrences(of: #""message":""#, with: "").replacingOccurrences(of: "\"", with: "")
            }
            return String(errLine.prefix(200))
        }
        if r.status != 0 { return "The CLI exited with code \(r.status)." }
        return nil
    }

    static func extractJSON(_ text: String) -> [String: [Icebreaker]] {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") , start < end,
              let obj = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
        else { return [:] }
        return MCPServer.parseIcebreakers(obj["icebreakers_by_lang"] ?? obj)
    }

    static func run(_ bin: String, _ args: [String], cwd: URL? = nil, extraEnv: [String: String] = [:], timeout: TimeInterval) async throws -> RunResult {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = args
            if let cwd { p.currentDirectoryURL = cwd }
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = loginPath
            env["NO_COLOR"] = "1"
            env.merge(extraEnv) { $1 }
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice // CLIs wait for EOF otherwise
            let accOut = DataBox(), accErr = DataBox()
            out.fileHandleForReading.readabilityHandler = { h in accOut.append(h.availableData) }
            err.fileHandleForReading.readabilityHandler = { h in accErr.append(h.availableData) }
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                accOut.append(out.fileHandleForReading.readDataToEndOfFile())
                accErr.append(err.fileHandleForReading.readDataToEndOfFile())
                if proc.terminationReason == .uncaughtSignal { cont.resume(throwing: Err("The agent took too long and was stopped.")) }
                else {
                    cont.resume(returning: RunResult(out: String(decoding: accOut.data, as: UTF8.self),
                                                     err: String(decoding: accErr.data, as: UTF8.self),
                                                     status: proc.terminationStatus))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        }
    }
}

final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buf = Data()
    func append(_ d: Data) { lock.lock(); buf.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return buf }
}

struct Err: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
