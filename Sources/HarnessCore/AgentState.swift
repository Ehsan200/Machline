import Foundation

/// Where an agent is in its lifecycle.
///
/// Every transition is driven by a control-plane frame or an `ApprovalBroker` event — never
/// inferred from message text (docs/RUNTIME.md).
public enum AgentState: Sendable, Equatable {
    case idle
    case thinking
    case executingTool(name: String, toolUseID: String)
    case waitingForApproval(toolName: String, hookID: String)
    case blocked(reason: String)
    case completed
    case errored(String)
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .errored, .cancelled: return true
        default: return false
        }
    }

    /// True while the agent is doing something the operator may want to interrupt.
    public var isBusy: Bool {
        switch self {
        case .thinking, .executingTool, .waitingForApproval: return true
        default: return false
        }
    }

    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .thinking: return "Thinking"
        case .executingTool(let name, _): return "Running \(name)"
        case .waitingForApproval(let name, _): return "Waiting for approval: \(name)"
        case .blocked(let reason): return "Blocked: \(reason)"
        case .completed: return "Completed"
        case .errored(let message): return "Error: \(message)"
        case .cancelled: return "Cancelled"
        }
    }
}

/// One item in an agent's transcript.
public enum TranscriptEntry: Sendable, Equatable, Identifiable {
    case thinking(id: UUID, messageID: String, text: String)
    case text(id: UUID, messageID: String, text: String)
    case toolCall(id: UUID, use: ToolUse)
    case toolResult(id: UUID, result: ToolResult, output: ProcessOutput?)
    /// A steer written to stdin but not yet consumed by the agent (docs/RUNTIME.md).
    case steerQueued(id: UUID, text: String)
    /// The same steer, once the `--replay-user-messages` echo confirmed consumption.
    case steerDelivered(id: UUID, text: String)
    /// A steer the agent will never consume, because the run it was queued behind was interrupted.
    ///
    /// Probe-verified: a message written to stdin mid-turn and followed by `SIGINT` is discarded by
    /// the CLI. It never echoes, so nothing in the frame stream retires it — the row sat on "queued"
    /// for the rest of the session and the composer went on counting it as pending work.
    case steerDropped(id: UUID, text: String)
    case turnEnded(id: UUID, result: TurnResult)
    /// Operator-facing annotation raised by the harness itself, not the agent.
    case incident(id: UUID, text: String)

    public var id: UUID {
        switch self {
        case .thinking(let id, _, _), .text(let id, _, _), .toolCall(let id, _),
             .toolResult(let id, _, _), .steerQueued(let id, _), .steerDelivered(let id, _),
             .steerDropped(let id, _), .turnEnded(let id, _), .incident(let id, _):
            return id
        }
    }

    /// Assistant frames arrive one per content block, all sharing a message id (docs/RUNTIME.md). The UI
    /// groups on this so a single reply renders as one bubble.
    public var messageID: String? {
        switch self {
        case .thinking(_, let messageID, _), .text(_, let messageID, _): return messageID
        default: return nil
        }
    }
}

/// Per-agent cost and activity, assembled from `task_notification` and `result` frames.
public struct AgentTelemetry: Sendable, Equatable {
    public var totalTokens: Int?
    public var toolUseCount: Int = 0
    public var durationMS: Int?
    public var costUSD: Double?
    public var turnCount: Int = 0
    /// Approvals this agent was blocked on, and how they ended.
    public var approvalsRequested: Int = 0
    public var approvalsDenied: Int = 0
    /// What the most recent model call actually carried: fresh input, both cache halves, and the
    /// reply. This is the conversation's occupancy of the context window — one call's worth, never
    /// a running total, so it cannot exceed the window.
    public var contextTokens: Int?
    /// Every token this agent has sent or received, summed over every model call.
    ///
    /// Distinct from `contextTokens` on purpose. A long conversation re-reads its cached prefix on
    /// every call, so this passes a million while the window itself is nowhere near full —
    /// treating the two as one number is what made a session look as though it had overrun a
    /// context it was well inside.
    public var billedTokens: Int = 0

    public init() {}
}

/// A node in the agent tree.
public struct AgentNode: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case root(sessionID: String)
        case subagent(taskID: String, toolUseID: String, subagentType: String)
    }

    public let id: String
    public let kind: Kind
    public let parentID: String?
    public var title: String
    public var state: AgentState
    public var children: [String] = []
    public var transcript: [TranscriptEntry] = []
    public var telemetry = AgentTelemetry()
    /// Capability snapshot from the most recent `system/init`. Re-emitted mid-session when the tool
    /// set changes, so this is replaced rather than merged (docs/RUNTIME.md).
    public var capabilities: SessionInit?
    /// How many times a `PreToolUse` hook was cancelled by the runtime, meaning a command ran
    /// unapproved (Finding 1). These are incidents, not warnings.
    ///
    /// A count rather than a flag because the banner can be dismissed: the UI remembers the count
    /// it dismissed at, so a *second* fail-open on the same agent raises the banner again while the
    /// one already acknowledged stays down.
    public var failOpenIncidentCount = 0

    public var hasFailOpenIncident: Bool { failOpenIncidentCount > 0 }
    /// Assistant text arriving token by token, before the complete block lands.
    ///
    /// A preview, not a record: it is cleared as soon as the assembled `assistant` frame arrives,
    /// so the transcript never holds both.
    public var streamingText = ""

    public var isRoot: Bool {
        if case .root = kind { return true }
        return false
    }

    init(id: String, kind: Kind, parentID: String?, title: String, state: AgentState = .idle) {
        self.id = id
        self.kind = kind
        self.parentID = parentID
        self.title = title
        self.state = state
    }
}
