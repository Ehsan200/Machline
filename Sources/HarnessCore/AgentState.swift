import Foundation

/// Where an agent is in its lifecycle.
///
/// Every transition is driven by a control-plane frame or an `ApprovalBroker` event — never
/// inferred from message text (README, Runtime).
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
    /// A steer written to stdin but not yet consumed by the agent (README, Runtime).
    case steerQueued(id: UUID, text: String)
    /// The same steer, once the `--replay-user-messages` echo confirmed consumption.
    case steerDelivered(id: UUID, text: String)
    case turnEnded(id: UUID, result: TurnResult)
    /// Operator-facing annotation raised by the harness itself, not the agent.
    case incident(id: UUID, text: String)

    public var id: UUID {
        switch self {
        case .thinking(let id, _, _), .text(let id, _, _), .toolCall(let id, _),
             .toolResult(let id, _, _), .steerQueued(let id, _), .steerDelivered(let id, _),
             .turnEnded(let id, _), .incident(let id, _):
            return id
        }
    }

    /// Assistant frames arrive one per content block, all sharing a message id (README, Runtime). The UI
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
    /// set changes, so this is replaced rather than merged (README, Runtime).
    public var capabilities: SessionInit?
    /// Set when a `PreToolUse` hook was cancelled by the runtime, meaning a command ran unapproved
    /// (Finding 1). This is an incident, not a warning.
    public var hasFailOpenIncident = false
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
