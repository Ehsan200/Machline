import Foundation

/// The `PreToolUse` payload the CLI writes to a hook's stdin.
///
/// Field names are probe-verified (`probes/hook_payload.json`). Decoding is lenient — an unknown or
/// renamed field must never prevent us from producing a verdict, because failing to answer is the
/// fail-open case (Finding 1).
public struct HookPayload: Sendable, Hashable, Codable {
    public let sessionID: String
    public let hookEventName: String
    public let toolName: String
    public let toolInput: JSONValue
    /// Ties the approval back to the exact node in the agent tree.
    public let toolUseID: String
    public let cwd: String
    public let permissionMode: String?
    public let promptID: String?
    public let transcriptPath: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case hookEventName = "hook_event_name"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case toolUseID = "tool_use_id"
        case cwd
        case permissionMode = "permission_mode"
        case promptID = "prompt_id"
        case transcriptPath = "transcript_path"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = (try? container.decode(String.self, forKey: .sessionID)) ?? ""
        hookEventName = (try? container.decode(String.self, forKey: .hookEventName)) ?? "PreToolUse"
        toolName = (try? container.decode(String.self, forKey: .toolName)) ?? ""
        toolInput = (try? container.decode(JSONValue.self, forKey: .toolInput)) ?? .null
        toolUseID = (try? container.decode(String.self, forKey: .toolUseID)) ?? ""
        cwd = (try? container.decode(String.self, forKey: .cwd)) ?? ""
        permissionMode = try? container.decode(String.self, forKey: .permissionMode)
        promptID = try? container.decode(String.self, forKey: .promptID)
        transcriptPath = try? container.decode(String.self, forKey: .transcriptPath)
    }

    public init(
        sessionID: String, hookEventName: String = "PreToolUse", toolName: String,
        toolInput: JSONValue, toolUseID: String, cwd: String, permissionMode: String? = nil,
        promptID: String? = nil, transcriptPath: String? = nil
    ) {
        self.sessionID = sessionID
        self.hookEventName = hookEventName
        self.toolName = toolName
        self.toolInput = toolInput
        self.toolUseID = toolUseID
        self.cwd = cwd
        self.permissionMode = permissionMode
        self.promptID = promptID
        self.transcriptPath = transcriptPath
    }

    /// The command string for a `Bash` invocation — the headline of the approval sheet.
    public var bashCommand: String? {
        guard toolName == "Bash" else { return nil }
        return toolInput["command"]?.stringValue
    }

    /// A one-line summary of what is being requested, for any tool.
    public var summary: String {
        if let command = bashCommand { return command }
        if let description = toolInput["description"]?.stringValue { return description }
        if let path = toolInput["file_path"]?.stringValue { return "\(toolName) \(path)" }
        return toolName
    }
}

/// What the helper sends to the broker.
public struct ApprovalRequest: Sendable, Hashable, Codable {
    public let payload: HookPayload
    /// Helper process id, for audit and for correlating a wedged helper with its request.
    public let helperPID: Int32
    /// When the helper will give up and deny on its own.
    public let helperDeadline: Date

    public init(payload: HookPayload, helperPID: Int32, helperDeadline: Date) {
        self.payload = payload
        self.helperPID = helperPID
        self.helperDeadline = helperDeadline
    }
}

/// The verdict, as it travels back over the socket.
public struct ApprovalDecision: Sendable, Hashable, Codable {
    public enum Verdict: String, Sendable, Codable {
        /// Run it, skipping any remaining permission checks.
        case allow
        /// Block it; `reason` is fed back to the agent as its tool result.
        case deny
        /// Defer to the runtime's own permission handling.
        case ask
    }

    public let verdict: Verdict
    public let reason: String
    /// Why this verdict was reached, for the audit log — a matched rule, an operator click, or a
    /// fail-closed default.
    public let provenance: Provenance

    public enum Provenance: String, Sendable, Codable {
        case operatorDecision
        case allowlistRule
        case denylistRule
        /// Answered by `AutoApproval` without the operator seeing it. Distinct from
        /// `allowlistRule` so the audit trail shows which calls were never read by a human.
        case autoApproved
        /// Covered by `permissions.allow` in the machine's own settings — the CLI would not have
        /// prompted for it either. Distinct from `allowlistRule`, which is a rule set in this app.
        case machineAllowlist
        case brokerTimeout
        case helperTimeout
        case brokerUnreachable
        case malformedPayload
        case internalError
    }

    public init(verdict: Verdict, reason: String, provenance: Provenance) {
        self.verdict = verdict
        self.reason = reason
        self.provenance = provenance
    }

    /// The denial used whenever anything at all goes wrong.
    ///
    /// Every failure path in the helper and the broker funnels here. This is the single most
    /// important behaviour in the interception design: the runtime's own timeout lets the command
    /// through (Finding 1), so *not answering* is never an acceptable outcome.
    /// The wording separates a decision from an outage. "Blocked" reads as a rule having refused
    /// the command, and sends whoever hits it looking for the rule — but most of these paths are
    /// the gate being unreachable or out of time, where there is no rule and nothing to change.
    public static func failClosed(_ provenance: Provenance, detail: String) -> ApprovalDecision {
        let opening: String
        switch provenance {
        case .brokerUnreachable, .brokerTimeout, .helperTimeout, .internalError, .malformedPayload:
            opening = "AgentHarness could not get an answer and denied by default"
        default:
            opening = "AgentHarness blocked this command"
        }
        return ApprovalDecision(
            verdict: .deny,
            reason: "\(opening): \(detail). No approval was recorded.",
            provenance: provenance)
    }
}

/// The JSON a `PreToolUse` hook prints on stdout.
///
/// Shape is probe-verified: a `deny` here reaches the agent as a `tool_result` with
/// `is_error: true` carrying `permissionDecisionReason` verbatim, and is recorded in the turn's
/// `permission_denials`.
public struct HookDecisionOutput: Codable, Sendable {
    public struct Payload: Codable, Sendable {
        public let hookEventName: String
        public let permissionDecision: String
        public let permissionDecisionReason: String
    }

    public let hookSpecificOutput: Payload

    public init(decision: ApprovalDecision, hookEventName: String = "PreToolUse") {
        hookSpecificOutput = Payload(
            hookEventName: hookEventName,
            permissionDecision: decision.verdict.rawValue,
            permissionDecisionReason: decision.reason)
    }

    public func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
            // Even the encoder failing must not produce silence. Hand-roll the denial.
            return #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"AgentHarness could not encode a decision and denied by default."}}"#
        }
        return text
    }
}

// MARK: - Wire coding

extension ApprovalRequest {
    public func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func decode(from line: String) throws -> ApprovalRequest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(ApprovalRequest.self, from: Data(line.utf8))
    }
}

extension ApprovalDecision {
    public func encoded() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    public static func decode(from line: String) throws -> ApprovalDecision {
        try JSONDecoder().decode(ApprovalDecision.self, from: Data(line.utf8))
    }
}
