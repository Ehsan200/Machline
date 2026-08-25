import Foundation

/// Advisory risk assessment for the approval sheet.
///
/// **This is not a security boundary.** It colours the sheet and picks a default button; it is
/// trivially evaded by obfuscation, indirection, or anything it has no pattern for. Real
/// containment is the operator's decision and the optional sandbox profile (docs/RUNTIME.md) —
/// `defaultDenylist` is empty, so nothing above it refuses on its own. Never gate execution on
/// this alone.
public struct RiskClassifier: Sendable {

    public enum Level: Int, Sendable, Comparable, Codable {
        case benign = 0
        case network = 1
        case privileged = 2
        case destructive = 3

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct Assessment: Sendable, Hashable {
        public let level: Level
        /// Human-readable reasons, shown as chips on the sheet.
        public let signals: [String]
        /// Substrings the sheet should highlight in the command.
        public let highlights: [String]
        /// The command pushes something out of this machine and cannot be taken back — a push, a
        /// publish, a release, a remote copy.
        ///
        /// Tracked apart from `level` because reversibility is a different axis from risk: `curl`
        /// and `git push` are both "network", but only one of them is visible to other people a
        /// second later. Auto mode holds these back whatever its ceiling.
        public let isOutward: Bool

        public var recommendsDenyByDefault: Bool { level >= .privileged }

        public init(level: Level, signals: [String], highlights: [String], isOutward: Bool = false) {
            self.level = level
            self.signals = signals
            self.highlights = highlights
            self.isOutward = isOutward
        }
    }

    /// Tools that write, by name. Write-capable MCP tools are flagged separately by the hub.
    public static let writeCapableTools: Set<String> = [
        "Write", "Edit", "NotebookEdit", "Bash"
    ]

    private static let destructiveSignals: [(pattern: String, signal: String)] = [
        ("rm -rf", "recursive force delete"),
        ("rm -fr", "recursive force delete"),
        (">/dev/", "device write"),
        ("mkfs", "filesystem format"),
        ("dd if=", "raw disk write"),
        ("git push --force", "force push"),
        ("git push -f", "force push"),
        ("git reset --hard", "discards working tree"),
        ("git clean -", "deletes untracked files"),
        ("truncate -", "truncates files"),
        ("shred ", "unrecoverable delete"),
        ("DROP TABLE", "destructive SQL"),
        ("DROP DATABASE", "destructive SQL")
    ]

    private static let privilegedSignals: [(pattern: String, signal: String)] = [
        ("sudo ", "elevated privileges"),
        ("doas ", "elevated privileges"),
        ("chown ", "ownership change"),
        ("chmod 777", "permissive mode change"),
        ("launchctl ", "system service control"),
        ("systemsetup ", "system configuration"),
        ("defaults write", "system defaults write"),
        ("security ", "keychain access"),
        ("/etc/", "system configuration path"),
        ("~/.ssh", "ssh credentials"),
        (".aws/credentials", "cloud credentials"),
        ("kill -9", "forced process termination")
    ]

    private static let networkSignals: [(pattern: String, signal: String)] = [
        ("curl ", "outbound network"),
        ("wget ", "outbound network"),
        ("nc ", "raw socket"),
        ("ssh ", "remote shell")
    ]

    /// Commands that put something somewhere other people can see, or that no later command here
    /// can undo. These are the holdouts auto mode always asks about.
    ///
    /// `git commit` is on the list because a commit is what the pushes are made of, and because an
    /// operator who wants their own hand on the history wants it here rather than one step later.
    private static let outwardSignals: [(pattern: String, signal: String)] = [
        ("git push", "publishes commits"),
        ("git commit", "writes history"),
        ("git tag", "writes a tag"),
        ("scp ", "remote copy"),
        ("rsync ", "remote sync"),
        ("npm publish", "publishes a package"),
        ("yarn publish", "publishes a package"),
        ("pnpm publish", "publishes a package"),
        ("cargo publish", "publishes a crate"),
        ("pip upload", "publishes a package"),
        ("twine upload", "publishes a package"),
        ("docker push", "publishes an image"),
        ("gh pr create", "opens a pull request"),
        ("gh pr merge", "merges a pull request"),
        ("gh release", "publishes a release"),
        ("kubectl apply", "changes a cluster"),
        ("kubectl rollout", "changes a cluster"),
        ("helm upgrade", "changes a cluster"),
        ("helm install", "changes a cluster"),
        ("terraform apply", "changes infrastructure"),
        ("aws ", "cloud API call"),
        ("gcloud ", "cloud API call")
    ]

    public init() {}

    /// - Parameter workspace: the trees the session may write in. Empty falls back to the payload's
    ///   own `cwd`, which is only ever a guess — see `Workspace`.
    public func assess(payload: HookPayload, workspace: Workspace = Workspace(roots: [])) -> Assessment {
        guard let command = payload.bashCommand else {
            return assessNonBashTool(payload: payload, workspace: workspace)
        }
        return assess(command: command)
    }

    public func assess(command: String) -> Assessment {
        let haystack = command.lowercased()
        var signals: [String] = []
        var highlights: [String] = []
        var level = Level.benign

        func scan(_ table: [(pattern: String, signal: String)], _ candidate: Level) {
            for entry in table where haystack.contains(entry.pattern.lowercased()) {
                signals.append(entry.signal)
                highlights.append(entry.pattern)
                if candidate > level { level = candidate }
            }
        }

        scan(Self.destructiveSignals, .destructive)
        scan(Self.privilegedSignals, .privileged)
        scan(Self.networkSignals, .network)

        var isOutward = false
        for entry in Self.outwardSignals where haystack.contains(entry.pattern.lowercased()) {
            isOutward = true
            signals.append(entry.signal)
            highlights.append(entry.pattern)
            if level < .network { level = .network }
        }

        // Shell indirection defeats pattern matching outright, so flag it rather than pretending
        // the command has been understood.
        for (pattern, signal) in [
            ("|", "piped command"), ("$(", "command substitution"), ("`", "command substitution"),
            ("&&", "chained command"), (";", "chained command"), ("eval ", "dynamic evaluation")
        ] where command.contains(pattern) {
            signals.append(signal)
            if level == .benign { level = .network }
        }

        return Assessment(
            level: level,
            signals: Array(Set(signals)).sorted(),
            highlights: Array(Set(highlights)).sorted(),
            isOutward: isOutward)
    }

    private func assessNonBashTool(payload: HookPayload, workspace: Workspace) -> Assessment {
        var signals: [String] = []
        var level = Level.benign

        if Self.writeCapableTools.contains(payload.toolName) {
            signals.append("writes to disk")
            level = .privileged
        }
        if payload.toolName.hasPrefix("mcp__") {
            signals.append("MCP tool")
            if level == .benign { level = .network }
        }
        // A write escaping the workspace is worth flagging regardless of tool. Judged against the
        // session's roots, not its current directory: an agent that has walked into a subdirectory
        // has not left the project, and saying it has cries wolf on every sibling-package edit.
        let roots = workspace.resolved(for: payload)
        let paths = payload.writePaths
        if !roots.isEmpty, !paths.isEmpty,
           !paths.allSatisfy({ roots.contains(path: $0, base: payload.cwd) }) {
            signals.append("writes outside the workspace")
            level = .destructive
        }
        return Assessment(level: level, signals: signals.sorted(), highlights: [])
    }
}
