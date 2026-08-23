import Foundation

// MARK: - Content blocks

/// A block inside an `assistant` or `user` message.
///
/// Unrecognised block types fall through to `.other`, keeping their payload for raw display.
public enum ContentBlock: Sendable, Hashable {
    case text(String)
    case thinking(text: String, signature: String?)
    case toolUse(ToolUse)
    case toolResult(ToolResult)
    case other(type: String, raw: JSONValue)

    public var blockType: String {
        switch self {
        case .text: return "text"
        case .thinking: return "thinking"
        case .toolUse: return "tool_use"
        case .toolResult: return "tool_result"
        case .other(let type, _): return type
        }
    }

    init(raw: JSONValue) {
        let type = raw["type"]?.stringValue ?? "unknown"
        switch type {
        case "text":
            self = .text(raw["text"]?.stringValue ?? "")
        case "thinking":
            self = .thinking(
                text: raw["thinking"]?.stringValue ?? "",
                signature: raw["signature"]?.stringValue)
        case "tool_use":
            self = .toolUse(ToolUse(raw: raw))
        case "tool_result":
            self = .toolResult(ToolResult(raw: raw))
        default:
            self = .other(type: type, raw: raw)
        }
    }
}

/// A tool invocation requested by the model.
public struct ToolUse: Sendable, Hashable {
    public let id: String
    public let name: String
    public let input: JSONValue
    /// The `caller` discriminator on the block. Only `"direct"` has been observed (docs/RUNTIME.md).
    public let callerType: String?

    init(raw: JSONValue) {
        id = raw["id"]?.stringValue ?? ""
        name = raw["name"]?.stringValue ?? ""
        input = raw["input"] ?? .null
        callerType = raw.value(at: "caller", "type")?.stringValue
    }

    /// The `Task` tool is enabled under that name but emits blocks named `Agent` (docs/RUNTIME.md).
    /// Match on both so subagent launches are never missed.
    public var isSubagentLaunch: Bool {
        name == "Agent" || name == "Task"
    }

    /// Convenience for the approval sheet: the command string of a `Bash` invocation.
    public var bashCommand: String? {
        guard name == "Bash" else { return nil }
        return input["command"]?.stringValue
    }
}

/// The result of a tool invocation, as carried in the message content array.
public struct ToolResult: Sendable, Hashable {
    public let toolUseID: String
    public let isError: Bool
    /// Flattened text form. The structured form, when present, is on `UserMessage.toolUseResult`.
    public let text: String

    init(raw: JSONValue) {
        toolUseID = raw["tool_use_id"]?.stringValue ?? ""
        isError = raw["is_error"]?.boolValue ?? false
        switch raw["content"] {
        case .string(let value):
            text = value
        case .array(let blocks):
            text = blocks.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        default:
            text = ""
        }
    }
}

// MARK: - Messages

public struct AssistantMessage: Sendable, Hashable {
    /// Frames are emitted one per completed content block, all sharing this id. Group on it —
    /// do not render one bubble per frame (docs/RUNTIME.md).
    public let id: String
    public let model: String?
    public let content: [ContentBlock]
    public let usage: JSONValue?
    public let requestID: String?

    init(frame: JSONValue) {
        let message = frame["message"] ?? .null
        id = message["id"]?.stringValue ?? ""
        model = message["model"]?.stringValue
        content = (message["content"]?.arrayValue ?? []).map(ContentBlock.init(raw:))
        usage = message["usage"]
        requestID = frame["request_id"]?.stringValue
    }
}

/// The structured sidecar on `user` frames.
///
/// For `Bash` results this is an object with stdout and stderr already separated — no parsing of
/// concatenated output is needed. For a hook denial it is a bare string. Both shapes are observed
/// in the probes, which is why this is an enum rather than a struct (docs/RUNTIME.md).
public enum ToolUseResultSidecar: Sendable, Hashable {
    case process(ProcessOutput)
    case text(String)
    case other(JSONValue)

    init?(raw: JSONValue?) {
        guard let raw else { return nil }
        switch raw {
        case .string(let value):
            self = .text(value)
        case .object(let members) where members["stdout"] != nil || members["stderr"] != nil:
            self = .process(ProcessOutput(raw: raw))
        case .null:
            return nil
        default:
            self = .other(raw)
        }
    }
}

public struct ProcessOutput: Sendable, Hashable {
    public let stdout: String
    public let stderr: String
    /// Authoritative cancellation signal — do not infer interruption from output text.
    public let interrupted: Bool
    public let isImage: Bool
    public let noOutputExpected: Bool

    init(raw: JSONValue) {
        stdout = raw["stdout"]?.stringValue ?? ""
        stderr = raw["stderr"]?.stringValue ?? ""
        interrupted = raw["interrupted"]?.boolValue ?? false
        isImage = raw["isImage"]?.boolValue ?? false
        noOutputExpected = raw["noOutputExpected"]?.boolValue ?? false
    }
}

public struct UserMessage: Sendable, Hashable {
    public let content: [ContentBlock]
    public let toolUseResult: ToolUseResultSidecar?

    init(frame: JSONValue) {
        content = (frame.value(at: "message", "content")?.arrayValue ?? []).map(ContentBlock.init(raw:))
        toolUseResult = ToolUseResultSidecar(raw: frame["tool_use_result"])
    }

    /// A `user` frame is either a tool result being fed back, or the echo of an injected steer
    /// (requires `--replay-user-messages`). The echo is what confirms a steer was consumed.
    ///
    /// Anything that is not a tool result is the operator's own message: a prompt that mentioned an
    /// image comes back as a text block *and* an `image` block, and demanding text throughout made
    /// that whole message read as a tool result and disappear.
    public var isReplayedUserInput: Bool {
        !content.isEmpty && !content.contains {
            if case .toolResult = $0 { return true } else { return false }
        }
    }

    /// The text blocks of an echoed message, in order.
    public var replayedText: [String] {
        content.compactMap { if case .text(let text) = $0 { return text } else { return nil } }
    }
}

// MARK: - Session handshake

public struct SessionInit: Sendable, Hashable {
    public let cwd: String?
    public let model: String?
    public let permissionMode: String?
    public let claudeCodeVersion: String?
    public let apiKeySource: String?
    public let outputStyle: String?
    /// The tool set actually negotiated, which may differ from what was requested. Populate the
    /// tool drawer from this, not from our own launch arguments (docs/RUNTIME.md).
    public let tools: [String]
    public let mcpServers: [JSONValue]
    public let agents: [String]
    public let skills: [String]
    public let slashCommands: [String]

    init(frame: JSONValue) {
        cwd = frame["cwd"]?.stringValue
        model = frame["model"]?.stringValue
        permissionMode = frame["permissionMode"]?.stringValue
        claudeCodeVersion = frame["claude_code_version"]?.stringValue
        apiKeySource = frame["apiKeySource"]?.stringValue
        outputStyle = frame["output_style"]?.stringValue
        tools = (frame["tools"]?.arrayValue ?? []).compactMap(\.stringValue)
        mcpServers = frame["mcp_servers"]?.arrayValue ?? []
        agents = (frame["agents"]?.arrayValue ?? []).compactMap(\.stringValue)
        skills = (frame["skills"]?.arrayValue ?? []).compactMap(\.stringValue)
        slashCommands = (frame["slash_commands"]?.arrayValue ?? []).compactMap(\.stringValue)
    }
}

// MARK: - Hooks

public struct HookStarted: Sendable, Hashable {
    public let hookID: String
    public let hookName: String
    public let hookEvent: String

    init(frame: JSONValue) {
        hookID = frame["hook_id"]?.stringValue ?? ""
        hookName = frame["hook_name"]?.stringValue ?? ""
        hookEvent = frame["hook_event"]?.stringValue ?? ""
    }
}

public struct HookResponse: Sendable, Hashable {
    public let hookID: String
    public let hookName: String
    public let hookEvent: String
    public let stdout: String
    public let stderr: String
    public let exitCode: Int
    /// `"success"` when the helper returned a decision; `"cancelled"` when the runtime timed it out.
    public let outcome: String

    init(frame: JSONValue) {
        hookID = frame["hook_id"]?.stringValue ?? ""
        hookName = frame["hook_name"]?.stringValue ?? ""
        hookEvent = frame["hook_event"]?.stringValue ?? ""
        stdout = frame["stdout"]?.stringValue ?? ""
        stderr = frame["stderr"]?.stringValue ?? ""
        exitCode = frame["exit_code"]?.intValue ?? 0
        outcome = frame["outcome"]?.stringValue ?? ""
    }

    /// A cancelled `PreToolUse` hook means the runtime stopped waiting and **let the tool run**
    /// (Finding 1). The helper is supposed to self-deny before this can happen, so
    /// observing it means the fail-closed guarantee was breached — surface it loudly.
    public var indicatesFailOpen: Bool {
        outcome == "cancelled" && hookEvent == "PreToolUse"
    }
}

// MARK: - Subagent tasks

public struct TaskStarted: Sendable, Hashable {
    public let taskID: String
    /// Links the task to the parent's `tool_use` block — this is the tree edge.
    public let toolUseID: String
    public let description: String
    public let subagentType: String
    public let taskType: String
    public let prompt: String

    init(frame: JSONValue) {
        taskID = frame["task_id"]?.stringValue ?? ""
        toolUseID = frame["tool_use_id"]?.stringValue ?? ""
        description = frame["description"]?.stringValue ?? ""
        subagentType = frame["subagent_type"]?.stringValue ?? ""
        taskType = frame["task_type"]?.stringValue ?? ""
        prompt = frame["prompt"]?.stringValue ?? ""
    }
}

public struct TaskUpdated: Sendable, Hashable {
    public let taskID: String
    public let status: String?
    public let endTime: Int?
    public let patch: JSONValue

    init(frame: JSONValue) {
        taskID = frame["task_id"]?.stringValue ?? ""
        patch = frame["patch"] ?? .null
        status = patch["status"]?.stringValue
        endTime = patch["end_time"]?.intValue
    }
}

public struct TaskNotification: Sendable, Hashable {
    public let taskID: String
    public let toolUseID: String
    public let status: String
    public let summary: String
    public let outputFile: String?
    public let totalTokens: Int?
    public let toolUses: Int?
    public let durationMS: Int?

    init(frame: JSONValue) {
        taskID = frame["task_id"]?.stringValue ?? ""
        toolUseID = frame["tool_use_id"]?.stringValue ?? ""
        status = frame["status"]?.stringValue ?? ""
        summary = frame["summary"]?.stringValue ?? ""
        outputFile = frame["output_file"]?.stringValue
        totalTokens = frame.value(at: "usage", "total_tokens")?.intValue
        toolUses = frame.value(at: "usage", "tool_uses")?.intValue
        durationMS = frame.value(at: "usage", "duration_ms")?.intValue
    }
}

public struct BackgroundTask: Sendable, Hashable {
    public let taskID: String
    public let taskType: String
    public let description: String

    init(raw: JSONValue) {
        taskID = raw["task_id"]?.stringValue ?? ""
        taskType = raw["task_type"]?.stringValue ?? ""
        description = raw["description"]?.stringValue ?? ""
    }
}

// MARK: - Turn result

public struct PermissionDenial: Sendable, Hashable {
    public let toolName: String
    public let toolUseID: String
    public let toolInput: JSONValue

    init(raw: JSONValue) {
        toolName = raw["tool_name"]?.stringValue ?? ""
        toolUseID = raw["tool_use_id"]?.stringValue ?? ""
        toolInput = raw["tool_input"] ?? .null
    }
}

/// Marks the end of a **turn**, not the end of the session (docs/RUNTIME.md).
public struct TurnResult: Sendable, Hashable {
    public let subtype: String
    public let isError: Bool
    public let text: String?
    public let numTurns: Int?
    public let stopReason: String?
    public let terminalReason: String?
    public let totalCostUSD: Double?
    public let durationMS: Int?
    public let ttftMS: Int?
    public let permissionDenials: [PermissionDenial]
    public let usage: JSONValue?
    public let modelUsage: JSONValue?

    init(frame: JSONValue) {
        subtype = frame["subtype"]?.stringValue ?? ""
        isError = frame["is_error"]?.boolValue ?? false
        text = frame["result"]?.stringValue
        numTurns = frame["num_turns"]?.intValue
        stopReason = frame["stop_reason"]?.stringValue
        terminalReason = frame["terminal_reason"]?.stringValue
        totalCostUSD = frame["total_cost_usd"]?.doubleValue
        durationMS = frame["duration_ms"]?.intValue
        ttftMS = frame["ttft_ms"]?.intValue
        permissionDenials = (frame["permission_denials"]?.arrayValue ?? []).map(PermissionDenial.init(raw:))
        usage = frame["usage"]
        modelUsage = frame["modelUsage"]
    }
}

// MARK: - Rate limits

public struct RateLimitInfo: Sendable, Hashable {
    public let status: String?
    public let rateLimitType: String?
    public let resetsAt: Int?
    public let overageStatus: String?
    public let isUsingOverage: Bool?

    init(frame: JSONValue) {
        let info = frame["rate_limit_info"] ?? .null
        status = info["status"]?.stringValue
        rateLimitType = info["rateLimitType"]?.stringValue
        resetsAt = info["resetsAt"]?.intValue
        overageStatus = info["overageStatus"]?.stringValue
        isUsingOverage = info["isUsingOverage"]?.boolValue
    }
}
