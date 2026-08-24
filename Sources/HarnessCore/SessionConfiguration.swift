import Foundation

/// Launch configuration for one root session.
///
/// The flag set is fixed by docs/RUNTIME.md and probe-verified. `--verbose` is not optional: without it
/// the CLI emits no streaming frames in `-p` mode.
///
/// What the session inherits from the machine is chosen by `isolation`; read its documentation
/// before changing the default, because the two modes make materially different promises.
public struct SessionConfiguration: Sendable {

    /// What a session inherits from the operator's own Claude configuration.
    public enum Isolation: String, Sendable, Codable, CaseIterable {
        /// Nothing. `--setting-sources ""` keeps the operator's hooks, skills, and `CLAUDE.md` out,
        /// and `--strict-mcp-config` keeps ambient MCP servers out.
        ///
        /// The second flag is not redundant: a probe run with `--setting-sources ""` and no strict
        /// flag connected nine ambient MCP servers and admitted roughly 250 tools — including
        /// outbound-messaging and CRM-write tools — into a session that was supposed to be sealed
        /// (Finding 4). Only this mode lets the harness state what tools a session had.
        case sealed

        /// Everything, as if `claude` had been run in a terminal: the operator's commands, skills,
        /// `CLAUDE.md`, hooks, and MCP servers all load.
        ///
        /// The approval gate still applies — Machline's own `PreToolUse` hook is installed through
        /// `--settings` and is unaffected. What is given up is knowing the tool surface in advance:
        /// ambient MCP servers join unannounced, and the operator's own hooks run alongside ours.
        case inherited
    }
    public var executable: String
    public var workingDirectory: URL
    public var sessionID: UUID
    public var model: String?
    /// Base tool set (`--tools`). `nil` leaves the CLI default in place.
    public var tools: [String]?
    /// Static denylist (`--disallowedTools`). The one enforcement that survives the app dying, and
    /// the one the operator cannot override at the prompt. Empty by default — see `defaultDenylist`.
    public var disallowedTools: [String]
    /// Directories the session may read outside its project (`--add-dir`).
    ///
    /// See `attachmentDirectories` for why this is not empty by default.
    public var additionalDirectories: [URL]
    public var settingsPath: URL?
    public var mcpConfigPath: URL?
    public var agentsJSON: String?
    public var maxBudgetUSD: Double?
    /// Token-level streaming. High frame volume; togglable per session (docs/RUNTIME.md).
    public var includePartialMessages: Bool
    /// Replaces the child's environment wholesale. Usually leave `nil` and use
    /// `additionalEnvironment` instead.
    public var environment: [String: String]?
    /// Merged over the inherited (or replaced) environment. This is how the approval helper learns
    /// its socket path.
    public var additionalEnvironment: [String: String]
    /// Which account the CLI should bill against.
    public var billing: Billing

    /// How the session authenticates.
    ///
    /// The CLI resolves credentials in a fixed order, and an environment variable outranks the
    /// signed-in profile. So a stray `ANTHROPIC_API_KEY` — exported in a shell profile months ago,
    /// or set by a tool — silently moves every session onto API billing without changing anything
    /// visible in the interface.
    public enum Billing: String, Sendable, Codable, CaseIterable {
        /// Bill the signed-in claude.ai account. Key variables are removed from the child's
        /// environment so they cannot take precedence.
        case subscription
        /// Leave the environment alone and let the CLI resolve credentials itself.
        case environment
    }

    /// Variables that move the CLI off the signed-in account, in its own resolution order.
    static let credentialOverrides = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX"
    ]
    public var additionalArguments: [String]
    /// What the session inherits from the machine. See `Isolation`.
    public var isolation: Isolation
    /// Resume an existing conversation instead of starting a new one.
    public var resume: Resume?

    /// Which recorded conversation to continue, and whether to branch off it.
    public struct Resume: Sendable, Hashable {
        /// The CLI's own session id, as recorded in its transcript store.
        public let sessionID: String
        /// Branch into a new session id rather than appending to the original. The original
        /// transcript is then left untouched.
        public let fork: Bool

        public init(sessionID: String, fork: Bool = false) {
            self.sessionID = sessionID
            self.fork = fork
        }
    }

    /// Where a file the operator handed the session lives, when it is not in the project.
    ///
    /// A dragged screenshot is the case that matters. It arrives in a sandbox-scoped drop directory
    /// the agent's process cannot read at all, so `AttachmentStore` copies it somewhere it can —
    /// and that somewhere has to be on `--add-dir`, or the agent has to ask permission for a file
    /// the operator just gave it, which in a session with no one watching is a refusal.
    ///
    /// The temporary directory is here as well for the images the CLI itself writes when one is
    /// pasted. Both are resolved through symlinks: `$TMPDIR` sits under `/var`, which links to
    /// `/private/var`, and an unresolved prefix would not match the path the agent is asked for.
    public static var attachmentDirectories: [URL] {
        [
            AttachmentStore.defaultDirectory,
            FileManager.default.temporaryDirectory
        ].map { $0.resolvingSymlinksInPath() }
    }

    /// Patterns unreachable regardless of broker state.
    ///
    /// Empty by choice. `--disallowedTools` refuses outright — no prompt, no broker, no way for the
    /// operator to say yes — so a pattern here is not a speed bump but a wall, and `Bash(rm *)`
    /// walled off ordinary single-file deletes the operator would have approved on sight. Risk is
    /// carried by `RiskClassifier` and the approval gate instead, which can ask.
    ///
    /// Re-add patterns here for the ones nobody should ever be asked about.
    public static let defaultDenylist: [String] = []

    public init(
        executable: String = "claude",
        workingDirectory: URL,
        sessionID: UUID = UUID(),
        model: String? = nil,
        tools: [String]? = nil,
        disallowedTools: [String] = SessionConfiguration.defaultDenylist,
        additionalDirectories: [URL] = SessionConfiguration.attachmentDirectories,
        settingsPath: URL? = nil,
        mcpConfigPath: URL? = nil,
        agentsJSON: String? = nil,
        maxBudgetUSD: Double? = nil,
        includePartialMessages: Bool = false,
        environment: [String: String]? = nil,
        additionalEnvironment: [String: String] = [:],
        additionalArguments: [String] = [],
        isolation: Isolation = .sealed,
        billing: Billing = .subscription,
        resume: Resume? = nil
    ) {
        self.isolation = isolation
        self.billing = billing
        self.resume = resume
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.sessionID = sessionID
        self.model = model
        self.tools = tools
        self.disallowedTools = disallowedTools
        self.additionalDirectories = additionalDirectories
        self.settingsPath = settingsPath
        self.mcpConfigPath = mcpConfigPath
        self.agentsJSON = agentsJSON
        self.maxBudgetUSD = maxBudgetUSD
        self.includePartialMessages = includePartialMessages
        self.environment = environment
        self.additionalEnvironment = additionalEnvironment
        self.additionalArguments = additionalArguments
    }

    public func arguments() -> [String] {
        // No `-p`. The duplex stream-json transport works without it, and the handshake is richer
        // for its absence: `terminal_slash_commands`, `plugins`, `capabilities`, and
        // `memory_paths` are reported only when the CLI is not in print mode. Probe-verified,
        // including a two-turn exchange with a clean `result` frame for each.
        var args = [
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-hook-events",
            "--forward-subagent-text",
            "--replay-user-messages"
        ]
        if isolation == .sealed {
            args += ["--setting-sources", ""]
        }

        // `--session-id` names a *new* session, so it conflicts with resuming an existing one.
        // When resuming without forking the CLI keeps the original id; when forking it mints one.
        if let resume {
            args += ["--resume", resume.sessionID]
            if resume.fork { args.append("--fork-session") }
        } else {
            args += ["--session-id", sessionID.uuidString.lowercased()]
        }
        if includePartialMessages { args.append("--include-partial-messages") }
        if let model { args += ["--model", model] }

        // Isolation and configuration flags come BEFORE any variadic flag. `--tools`,
        // `--allowedTools`, and `--disallowedTools` all consume a variable number of values, and a
        // malformed one silently eats whatever follows it — see `appendVariadic`.
        // Only meaningful when sealed: inheriting the machine's configuration is precisely the
        // request to let its MCP servers in.
        if isolation == .sealed { args.append("--strict-mcp-config") }
        if let mcpConfigPath { args += ["--mcp-config", mcpConfigPath.path] }
        if let settingsPath { args += ["--settings", settingsPath.path] }
        if let agentsJSON { args += ["--agents", agentsJSON] }
        if let maxBudgetUSD { args += ["--max-budget-usd", String(maxBudgetUSD)] }

        if let tools { Self.appendVariadic("--tools", values: tools, to: &args) }
        Self.appendVariadic("--disallowedTools", values: disallowedTools, to: &args)
        Self.appendVariadic(
            "--add-dir", values: additionalDirectories.map(\.path), to: &args)

        args += additionalArguments
        return args
    }

    /// Appends a variadic flag, never as a bare flag with no values.
    ///
    /// A bare `--tools` consumes the **next flag** as if it were a tool name. That is not cosmetic:
    /// emitting `--tools` (for an empty tool set) directly before `--strict-mcp-config` swallowed
    /// the isolation flag, and a session that should have had one MCP server connected ten,
    /// including account-level connectors with outbound-messaging and record-write tools.
    ///
    /// The empty tool set is spelled `--tools ""`, which is the documented disable-all form.
    /// An empty denylist is simply omitted.
    static func appendVariadic(_ flag: String, values: [String], to args: inout [String]) {
        if values.isEmpty {
            // Only `--tools` has a meaningful empty form; other variadics are dropped instead.
            if flag == "--tools" { args += [flag, ""] }
            return
        }
        args += [flag] + values
    }

    /// The environment handed to the child process.
    public func resolvedEnvironment() -> [String: String] {
        resolvedEnvironment(inheriting: ProcessInfo.processInfo.environment)
    }

    /// The child's environment, built over an explicit base.
    ///
    /// The base matters when the app was launched from Finder: the inherited environment is then
    /// `launchd`'s, not the operator's, and every command the agent runs would see a `PATH` of
    /// `/usr/bin:/bin:/usr/sbin:/sbin`. `SessionSupervisor` passes the login shell's environment
    /// here so the agent's shell looks like the operator's own.
    ///
    /// An explicit `environment` still wins outright — it exists to replace the inherited one.
    public func resolvedEnvironment(inheriting base: [String: String]) -> [String: String] {
        var resolved = environment ?? base
        if billing == .subscription {
            for key in Self.credentialOverrides { resolved.removeValue(forKey: key) }
        }
        resolved.merge(additionalEnvironment) { _, new in new }
        return resolved
    }
}
