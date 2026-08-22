import Foundation

/// The typed view of a frame's payload.
///
/// Deliberately non-exhaustive in spirit: anything the current CLI emits that this enum does not
/// name arrives as `.unknown` with its payload intact on `Frame.raw`. Adding a case is a pure
/// enhancement and never a decode break.
public enum FrameKind: Sendable, Hashable {
    case sessionInit(SessionInit)
    case status(String)
    case thinkingTokens(estimated: Int, delta: Int)
    case rateLimit(RateLimitInfo)
    case streamEvent(eventType: String, event: JSONValue)
    case assistant(AssistantMessage)
    case user(UserMessage)
    case hookStarted(HookStarted)
    case hookResponse(HookResponse)
    case taskStarted(TaskStarted)
    case taskUpdated(TaskUpdated)
    case taskNotification(TaskNotification)
    case backgroundTasksChanged([BackgroundTask])
    case result(TurnResult)
    case unknown
}

/// One decoded line of the control plane.
///
/// `raw` always holds the complete original object. Typed access is a convenience layered on top,
/// never a replacement — see `JSONValue` for why.
public struct Frame: Sendable, Hashable {
    public let type: String
    public let subtype: String?
    public let sessionID: String?
    public let uuid: String?
    /// `nil` at the root; set to the parent's `tool_use` id for subagent-produced frames.
    public let parentToolUseID: String?
    public let timestamp: String?
    public let kind: FrameKind
    public let raw: JSONValue

    public init(raw: JSONValue) {
        self.raw = raw
        type = raw["type"]?.stringValue ?? "unknown"
        subtype = raw["subtype"]?.stringValue
        sessionID = raw["session_id"]?.stringValue
        uuid = raw["uuid"]?.stringValue
        parentToolUseID = raw["parent_tool_use_id"]?.stringValue
        timestamp = raw["timestamp"]?.stringValue
        kind = Frame.classify(type: type, subtype: raw["subtype"]?.stringValue, raw: raw)
    }

    private static func classify(type: String, subtype: String?, raw: JSONValue) -> FrameKind {
        switch (type, subtype) {
        case ("system", "init"):
            return .sessionInit(SessionInit(frame: raw))
        case ("system", "status"):
            return .status(raw["status"]?.stringValue ?? "")
        case ("system", "thinking_tokens"):
            return .thinkingTokens(
                estimated: raw["estimated_tokens"]?.intValue ?? 0,
                delta: raw["estimated_tokens_delta"]?.intValue ?? 0)
        case ("system", "hook_started"):
            return .hookStarted(HookStarted(frame: raw))
        case ("system", "hook_response"):
            return .hookResponse(HookResponse(frame: raw))
        case ("system", "task_started"):
            return .taskStarted(TaskStarted(frame: raw))
        case ("system", "task_updated"):
            return .taskUpdated(TaskUpdated(frame: raw))
        case ("system", "task_notification"):
            return .taskNotification(TaskNotification(frame: raw))
        case ("system", "background_tasks_changed"):
            return .backgroundTasksChanged((raw["tasks"]?.arrayValue ?? []).map(BackgroundTask.init(raw:)))
        case ("rate_limit_event", _):
            return .rateLimit(RateLimitInfo(frame: raw))
        case ("stream_event", _):
            return .streamEvent(
                eventType: raw.value(at: "event", "type")?.stringValue ?? "",
                event: raw["event"] ?? .null)
        case ("assistant", _):
            return .assistant(AssistantMessage(frame: raw))
        case ("user", _):
            return .user(UserMessage(frame: raw))
        case ("result", _):
            return .result(TurnResult(frame: raw))
        default:
            return .unknown
        }
    }
}

// MARK: - Convenience

extension Frame {
    /// True for frames that arrive at very high frequency and must be coalesced before they reach
    /// the UI (README, Runtime). A trivial two-turn probe emitted 18 thinking-token and 32 stream-event
    /// frames.
    public var isHighFrequency: Bool {
        switch kind {
        case .thinkingTokens, .streamEvent: return true
        default: return false
        }
    }

    /// Tool invocations requested in this frame, if any.
    public var toolUses: [ToolUse] {
        guard case .assistant(let message) = kind else { return [] }
        return message.content.compactMap { if case .toolUse(let use) = $0 { return use } else { return nil } }
    }

    /// Tool results carried by this frame, if any.
    public var toolResults: [ToolResult] {
        guard case .user(let message) = kind else { return [] }
        return message.content.compactMap { if case .toolResult(let result) = $0 { return result } else { return nil } }
    }
}
