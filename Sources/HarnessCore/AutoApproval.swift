import Foundation

/// Which gated calls are answered without asking the operator.
///
/// **This is a convenience, not a containment boundary.** It is built on `RiskClassifier`, which
/// documents itself as trivially evaded — a command it has no pattern for reads as benign. What
/// still holds with auto-approval on:
///
/// - deny rules in `PolicyStore` are evaluated first and win outright;
/// - the static `--disallowedTools` denylist is enforced by the runtime, not by us, and survives
///   this process dying;
/// - every auto-approval is emitted on the audit stream with `.autoApproved` provenance.
///
/// What does not hold: an operator reading each command before it runs. Raising `bashCeiling`
/// above `.benign` accepts that a piped or chained command runs unread.
public struct AutoApproval: Sendable, Hashable, Codable {

    /// The highest risk level answered automatically for `Bash`. `nil` asks for every command.
    ///
    /// Capped at `.network` on the way in. `.privileged` and `.destructive` are the two levels an
    /// operator most needs to see, so they are not expressible here — a rule in `PolicyStore` is
    /// the deliberate, visible, per-pattern way to widen past them.
    public var bashCeiling: RiskClassifier.Level?

    /// Auto-approve file writes inside the workspace.
    ///
    /// Scoped to the working directory because a write inside it is recoverable — the Git
    /// workbench shows it as a diff and can discard it — and a write outside it is not.
    public var workspaceFileEdits: Bool

    /// Never answer for a command that puts something outside this machine, whatever the ceiling.
    ///
    /// `RiskClassifier.Assessment.isOutward` marks those — a push, a publish, a release, a remote
    /// copy, a cluster change. They are the calls an operator wants their own hand on, and they are
    /// what makes a broad ceiling tolerable at all.
    public var holdsOutwardCommands: Bool

    /// The highest ceiling that may be set. See `bashCeiling`.
    public static let maximumBashCeiling = RiskClassifier.Level.network

    /// Ask before everything. The default, and what the app starts in.
    public static let manual = AutoApproval(bashCeiling: nil, workspaceFileEdits: false)

    /// Get on with it: run local work unasked, and stop at the door.
    ///
    /// Everything the classifier reads as benign or network-level is answered automatically, and
    /// so is every file edit inside the project. What still reaches the operator: anything
    /// privileged or destructive, any write outside the project, and every outward command —
    /// `git push`, `npm publish`, `gh release`, `terraform apply`, and the rest of that list.
    public static let auto = AutoApproval(
        bashCeiling: .network, workspaceFileEdits: true, holdsOutwardCommands: true)

    public init(
        bashCeiling: RiskClassifier.Level? = nil,
        workspaceFileEdits: Bool = false,
        holdsOutwardCommands: Bool = true
    ) {
        self.bashCeiling = bashCeiling.map { min($0, Self.maximumBashCeiling) }
        self.workspaceFileEdits = workspaceFileEdits
        self.holdsOutwardCommands = holdsOutwardCommands
    }

    /// Decoded by hand so a setting stored before `holdsOutwardCommands` existed reads back as the
    /// safe value rather than failing to decode and silently resetting the whole mode.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bashCeiling: try container.decodeIfPresent(RiskClassifier.Level.self, forKey: .bashCeiling),
            workspaceFileEdits: try container.decodeIfPresent(Bool.self, forKey: .workspaceFileEdits)
                ?? false,
            holdsOutwardCommands: try container.decodeIfPresent(
                Bool.self, forKey: .holdsOutwardCommands) ?? true)
    }

    public var isEnabled: Bool { bashCeiling != nil || workspaceFileEdits }

    /// True when this is exactly the `auto` preset, so the interface can name it rather than
    /// describing its parts.
    public var isFullAuto: Bool { self == .auto }

    /// Tools whose writes `workspaceFileEdits` covers.
    public static let editTools: Set<String> = ["Write", "Edit", "MultiEdit", "NotebookEdit"]

    /// The decision, or `nil` to fall through to the operator.
    ///
    /// Only ever returns an allow: a mode that could deny on its own would be a second, invisible
    /// denylist competing with `PolicyStore`.
    public func decision(
        for payload: HookPayload, assessment: RiskClassifier.Assessment
    ) -> ApprovalDecision? {
        if Self.editTools.contains(payload.toolName) {
            guard workspaceFileEdits, Self.writesInsideWorkspace(payload) else { return nil }
            return ApprovalDecision(
                verdict: .allow,
                reason: "Auto-approved: file edit inside the workspace.",
                provenance: .autoApproved)
        }

        guard payload.bashCommand != nil else { return nil }
        guard let bashCeiling, assessment.level <= bashCeiling else { return nil }
        // The one thing a ceiling cannot express: a command at or below it that still leaves the
        // machine. Those are held back so auto mode never publishes anything on its own.
        if holdsOutwardCommands, assessment.isOutward { return nil }
        return ApprovalDecision(
            verdict: .allow,
            reason: "Auto-approved: \(assessment.level.label) command, at or below the "
                + "\(bashCeiling.label) threshold.",
            provenance: .autoApproved)
    }

    /// Whether every path the tool would write lies inside the session's working directory.
    ///
    /// Paths are resolved before comparison so `..` cannot walk out, and a payload naming no path
    /// is treated as outside — an unrecognised edit shape is a reason to ask, not to assume.
    static func writesInsideWorkspace(_ payload: HookPayload) -> Bool {
        guard !payload.cwd.isEmpty else { return false }
        let root = URL(fileURLWithPath: payload.cwd).standardizedFileURL.resolvingSymlinksInPath()

        var candidates: [String] = []
        if let path = payload.toolInput["file_path"]?.stringValue { candidates.append(path) }
        if let path = payload.toolInput["notebook_path"]?.stringValue { candidates.append(path) }
        guard !candidates.isEmpty else { return false }

        return candidates.allSatisfy { candidate in
            let resolved = URL(fileURLWithPath: candidate, relativeTo: root)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            // Compare on path components so `/work` does not appear to contain `/workspace`.
            let rootParts = root.pathComponents
            let parts = resolved.pathComponents
            return parts.count > rootParts.count && Array(parts.prefix(rootParts.count)) == rootParts
        }
    }
}

extension RiskClassifier.Level {
    /// The level a label names, for round-tripping through a control that carries strings.
    public static func named(_ label: String) -> RiskClassifier.Level? {
        [.benign, .network, .privileged, .destructive].first { $0.label == label }
    }

    public var label: String {
        switch self {
        case .benign: return "benign"
        case .network: return "network"
        case .privileged: return "privileged"
        case .destructive: return "destructive"
        }
    }
}
