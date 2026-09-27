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
                    // Skip the presenter's own hooks/plugins/skills/built-in tools: they add 30 s+ per run and
                    // aren't needed. Only La Laai's MCP tools are available; anything else is denied, never prompted.
                    "--setting-sources", "", "--tools", "", "--disable-slash-commands", "--no-session-persistence",
                    "--permission-mode", "dontAsk",
                    "--allowedTools", "mcp__lalaai__get_presentation,mcp__lalaai__get_transcript,mcp__lalaai__get_questions,mcp__lalaai__get_icebreaker_job,mcp__lalaai__list_icebreaker_jobs,mcp__lalaai__submit_icebreakers",
                    "--output-format", "text"]
            if let model { args += ["--model", model] }
        case .codex:
            args = ["exec", "--skip-git-repo-check", "-s", "read-only"]
            // The presenter's ~/.codex/config.toml starts every global MCP server and hook they have (measured:
            // 89 s vs 12 s for the probe) and may pin a default model this CLI can't run. Auth still comes from CODEX_HOME.
            if Self.codexIgnoresUserConfig { args += ["--ignore-user-config", "--ephemeral", "-c", "model_reasoning_effort=\"low\""] }
            args += ["-c", "mcp_servers.lalaai.url=\"\(mcpURL)\"",
                     "-c", "mcp_servers.lalaai.startup_timeout_sec=20",
                     "-c", "mcp_servers.lalaai.tool_timeout_sec=120", // submit_icebreakers translates on device
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

    /// Codex ≥ ~0.150 can skip the user's config.toml (their MCP servers, hooks, default model) for a run.
    static let codexIgnoresUserConfig: Bool = {
        guard let bin = locate("codex") else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["exec", "--help"]
        p.environment = childEnvironment()
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let help = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return help.contains("--ignore-user-config")
    }()

    /// Our environment minus anything that would hijack the agent CLI when La Laai itself was started from inside
    /// an agent session (Claude Code / Codex terminal): those vars point `claude` at the host's auth proxy
    /// ("Not logged in") or put `codex` into the host's network-less sandbox.
    static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let hostedByClaude = env["CLAUDECODE"] != nil || env["CLAUDE_CODE_ENTRYPOINT"] != nil
        for k in env.keys where k == "CLAUDECODE" || k.hasPrefix("CLAUDE_CODE_") || k.hasPrefix("CLAUDE_AGENT_SDK")
            || k == "CLAUDE_PID" || k == "CLAUDE_EFFORT" || k.hasPrefix("CLAUDE_PREVIEW_") || k.hasPrefix("CODEX_SANDBOX")
            || k == "CODEX_THREAD_ID" || (hostedByClaude && k == "ANTHROPIC_BASE_URL") {
            env[k] = nil
        }
        env["PATH"] = loginPath
        env["NO_COLOR"] = "1"
        return env
    }

    /// Runs a CLI with a hard timeout. Never throws/crashes on a misbehaving child: resumes exactly once, escalates
    /// SIGTERM → SIGKILL, and doesn't block forever on pipes a stray grandchild keeps open.
    static func run(_ bin: String, _ args: [String], cwd: URL? = nil, extraEnv: [String: String] = [:], timeout: TimeInterval) async throws -> RunResult {
        StderrGuard.install()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RunResult, Error>) in
            let once = Once()
            func finish(_ r: Result<RunResult, Error>) { if once.claim() { cont.resume(with: r) } }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = args
            if let cwd { p.currentDirectoryURL = cwd }
            p.environment = childEnvironment().merging(extraEnv) { $1 }
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice // CLIs wait for EOF otherwise
            let accOut = DataBox(), accErr = DataBox()
            let eof = DispatchGroup()
            for (pipe, box) in [(out, accOut), (err, accErr)] {
                eof.enter()
                let done = Once()
                pipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty { h.readabilityHandler = nil; if done.claim() { eof.leave() } } else { box.append(d) }
                }
            }
            let timedOut = Once()
            p.terminationHandler = { proc in
                // Collect what's left, but a grandchild holding the pipe must not hang us.
                DispatchQueue.global().async {
                    _ = eof.wait(timeout: .now() + 3)
                    let result = RunResult(out: String(decoding: accOut.data, as: UTF8.self),
                                           err: String(decoding: accErr.data, as: UTF8.self),
                                           status: proc.terminationStatus)
                    if timedOut.isClaimed { finish(.failure(Err("The agent took too long (\(Int(timeout)) s) and was stopped."))) }
                    else { finish(.success(result)) }
                }
            }
            do { try p.run() } catch {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                finish(.failure(Err("Couldn't start \(URL(fileURLWithPath: bin).lastPathComponent): \(error.localizedDescription)")))
                return
            }
            let pid = p.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard p.isRunning, timedOut.claim() else { return }
                p.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { kill(pid, SIGKILL) } }
            }
        }
    }
}

/// One-shot flag (thread-safe).
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    /// True the first time only.
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if claimed { return false }; claimed = true; return true }
    var isClaimed: Bool { lock.lock(); defer { lock.unlock() }; return claimed }
}

/// La Laai logs `lalaai:` lines to stderr with FileHandle.write. When the app was launched from a terminal or an
/// agent's shell whose stderr pipe later closed, the next log line (typically "agent failed: … took too long")
/// raised SIGPIPE and the app vanished without a crash report. We ignore SIGPIPE and, when stderr is a pipe/socket,
/// put our own pipe in front of it (FileHandle.write would otherwise throw on EPIPE); a forwarder copies lines to the
/// original stderr and silently drops them once nobody is reading.
enum StderrGuard {
    private static let installed: Void = {
        signal(SIGPIPE, SIG_IGN)
        var st = stat()
        guard fstat(STDERR_FILENO, &st) == 0 else { return }
        let kind = st.st_mode & S_IFMT
        guard kind == S_IFIFO || kind == S_IFSOCK else { return } // tty/file/null can't break
        let original = dup(STDERR_FILENO)
        var fds: [Int32] = [0, 0]
        guard original >= 0, pipe(&fds) == 0 else { return }
        _ = fcntl(original, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        guard dup2(fds[1], STDERR_FILENO) >= 0 else { return }
        close(fds[1])
        let reader = fds[0]
        let t = Thread {
            var buf = [UInt8](repeating: 0, count: 4096)
            var sink: Int32 = original
            while true {
                let n = read(reader, &buf, buf.count)
                if n <= 0 { if n < 0 && errno == EINTR { continue }; return }
                if sink >= 0, buf.withUnsafeBytes({ write(sink, $0.baseAddress, n) }) < 0, errno == EPIPE { close(sink); sink = -1 }
            }
        }
        t.name = "lalaai.stderr"
        t.start()
    }()

    static func install() { _ = installed }
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
