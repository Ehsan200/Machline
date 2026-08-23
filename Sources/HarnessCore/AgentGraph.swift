import Foundation

/// What changed as a result of applying a frame. Lets the UI diff cheaply and lets tests assert on
/// transitions rather than on final state alone.
public enum GraphChange: Sendable, Equatable {
    case nodeAdded(id: String)
    case stateChanged(id: String, from: AgentState, to: AgentState)
    case transcriptAppended(id: String, entryID: UUID)
    /// The agent's transcript was emptied by `/clear`. Structural rather than streaming, so it is
    /// never coalesced away: the one frame that must land is the one that empties the screen.
    case transcriptCleared(id: String)
    case telemetryUpdated(id: String)
    case capabilitiesUpdated(id: String)
    case failOpenIncident(id: String, toolName: String)
    /// Partial assistant text arrived. High frequency by nature — coalesce before rendering.
    case streamingUpdated(id: String)
}

/// Builds the agent tree from the control-plane frame stream.
///
/// A pure reducer: `apply(frame:)` is the only way state changes, and it is deterministic given the
/// same frame sequence. That makes the archived probe transcripts a complete test harness for the
/// tree, and keeps the SwiftUI layer free of parsing logic.
///
/// Attribution rule: a frame belongs to the subagent whose launching `tool_use` id equals the
/// frame's `parent_tool_use_id`, and to the root when that is `nil`.
public struct AgentGraph: Sendable {

    public private(set) var nodes: [String: AgentNode] = [:]
    public private(set) var rootID: String?
    /// `tool_use` id of a subagent launch → that subagent's node id.
    private var nodeIDByToolUseID: [String: String] = [:]
    /// Tool calls currently in flight, so a result can restore the right state.
    private var toolCallOwner: [String: String] = [:]
    /// The last assistant message whose usage was counted, per agent. Frames repeat a message's
    /// usage once per content block.
    private var lastCountedMessageID: [String: String] = [:]
    /// Steers written to stdin before the first frame created the root node.
    ///
    /// The prompt typed to start a session is sent the moment the process is up, which is before
    /// the CLI has said anything — so there is no node to hang it on yet. Held here and appended
    /// when the root appears, or the opening message of a session would exist only in the CLI's
    /// echo of it.
    private var steersAwaitingRoot: [String] = []
    /// How many `background_tasks_changed` snapshots have been seen, and per subagent how many of
    /// the most recent ones left it out. See `reconcileAbandonedTasks`.
    private var backgroundSnapshots = 0
    private var absentSnapshots: [String: Int] = [:]
    /// Set once the session itself has ended — the process exited, or the operator stopped it.
    ///
    /// Until then the root agent is still there to be talked to, whatever its last turn did. See
    /// `transition`.
    private var isSessionOver = false
    private var idGenerator: @Sendable () -> UUID

    /// - Parameter idGenerator: overridable so tests can assert on stable transcript ids.
    public init(idGenerator: @escaping @Sendable () -> UUID = { UUID() }) {
        self.idGenerator = idGenerator
    }

    // MARK: - Queries

    public var root: AgentNode? { rootID.flatMap { nodes[$0] } }

    public func node(id: String) -> AgentNode? { nodes[id] }

    /// Depth-first ordering for the tree view: parents before their children, insertion order kept.
    public func orderedNodes() -> [AgentNode] {
        guard let rootID else { return [] }
        var ordered: [AgentNode] = []
        func visit(_ id: String) {
            guard let node = nodes[id] else { return }
            ordered.append(node)
            for child in node.children { visit(child) }
        }
        visit(rootID)
        return ordered
    }

    public func children(of id: String) -> [AgentNode] {
        (nodes[id]?.children ?? []).compactMap { nodes[$0] }
    }

    /// Agents currently blocked on an operator decision.
    public var awaitingApproval: [AgentNode] {
        nodes.values.filter { if case .waitingForApproval = $0.state { return true } else { return false } }
            .sorted { $0.id < $1.id }
    }

    // MARK: - Reduction

    @discardableResult
    public mutating func apply(frame: Frame) -> [GraphChange] {
        var changes: [GraphChange] = []
        let ownerID = ensureOwner(for: frame, changes: &changes)

        switch frame.kind {
        case .sessionInit(let capabilities):
            // Re-emitted when the tool set changes; replace rather than merge.
            nodes[ownerID]?.capabilities = capabilities
            changes.append(.capabilitiesUpdated(id: ownerID))

        case .status(let status):
            if status == "requesting" { transition(ownerID, to: .thinking, changes: &changes) }

        case .assistant(let message):
            apply(message: message, to: ownerID, changes: &changes)

        case .user(let message):
            apply(userMessage: message, to: ownerID, changes: &changes)

        case .hookStarted(let hook):
            guard hook.hookEvent == "PreToolUse" else { break }
            let toolName = currentToolName(for: ownerID) ?? hook.hookName
            nodes[ownerID]?.telemetry.approvalsRequested += 1
            changes.append(.telemetryUpdated(id: ownerID))
            transition(
                ownerID,
                to: .waitingForApproval(toolName: toolName, hookID: hook.hookID),
                changes: &changes)

        case .hookResponse(let response):
            if response.indicatesFailOpen {
                nodes[ownerID]?.failOpenIncidentCount += 1
                let toolName = currentToolName(for: ownerID) ?? response.hookName
                append(
                    .incident(
                        id: idGenerator(),
                        text: "The approval hook for \(toolName) was cancelled by the runtime. "
                            + "The command may have executed without approval."),
                    to: ownerID, changes: &changes)
                changes.append(.failOpenIncident(id: ownerID, toolName: toolName))
            }
            // Leaving the approval wait: the tool either runs or comes back as an error.
            if case .waitingForApproval = nodes[ownerID]?.state {
                if let toolUseID = inFlightToolUseID(for: ownerID),
                   let name = currentToolName(for: ownerID) {
                    transition(
                        ownerID, to: .executingTool(name: name, toolUseID: toolUseID),
                        changes: &changes)
                } else {
                    transition(ownerID, to: .thinking, changes: &changes)
                }
            }

        case .taskStarted(let task):
            addSubagent(task: task, parentID: ownerID, changes: &changes)

        case .taskUpdated(let update):
            guard let id = nodeID(forTaskID: update.taskID) else { break }
            finish(id, outcome: TaskOutcome(status: update.status ?? ""), changes: &changes)

        case .taskNotification(let notification):
            guard let id = nodeID(forTaskID: notification.taskID) else { break }
            nodes[id]?.telemetry.totalTokens = notification.totalTokens
            nodes[id]?.telemetry.durationMS = notification.durationMS
            if let toolUses = notification.toolUses { nodes[id]?.telemetry.toolUseCount = toolUses }
            changes.append(.telemetryUpdated(id: id))
            finish(id, outcome: TaskOutcome(status: notification.status), changes: &changes)

        case .backgroundTasksChanged(let tasks):
            noteBackgroundTasks(tasks)

        case .result(let result):
            apply(turnResult: result, to: ownerID, changes: &changes)
            reconcileAbandonedTasks(changes: &changes)

        case .streamEvent(let eventType, let event):
            apply(streamEvent: eventType, event: event, to: ownerID, changes: &changes)

        case .thinkingTokens, .rateLimit, .unknown:
            break
        }

        return changes
    }

    // MARK: - Task lifecycle

    /// Applies a task's reported status. A status that is not one of the running words ends the
    /// agent — see `TaskOutcome`.
    private mutating func finish(
        _ id: String, outcome: TaskOutcome, changes: inout [GraphChange]
    ) {
        guard nodes[id]?.state.isTerminal == false else { return }
        switch outcome {
        case .running:
            break
        case .completed:
            transition(id, to: .completed, changes: &changes)
        case .stopped(let status):
            transition(id, to: .cancelled, changes: &changes)
            append(.incident(id: idGenerator(), text: "The agent was \(status) before it reported."),
                   to: id, changes: &changes)
        case .failed(let status):
            transition(id, to: .errored("Task \(status)"), changes: &changes)
        }
    }

    /// Tracks how many consecutive live-task snapshots a subagent has been missing from.
    ///
    /// The snapshot is the CLI's own list of what is still running, and it drops a task a moment
    /// before the status frames for it arrive — so absence alone means nothing. Absence that
    /// outlives a second snapshot *and* a turn boundary is a task that ended without saying so.
    private mutating func noteBackgroundTasks(_ tasks: [BackgroundTask]) {
        backgroundSnapshots += 1
        let live = Set(tasks.map(\.taskID))
        for (id, node) in nodes where !node.isRoot && !node.state.isTerminal {
            absentSnapshots[id] = live.contains(id) ? 0 : (absentSnapshots[id] ?? 0) + 1
        }
    }

    /// Ends the agents the CLI has stopped listing and never reported on.
    ///
    /// Without this, a subagent killed with no `task_updated` behind it reads as "Thinking" for the
    /// rest of the session — the one thing an operator watching a fleet cannot afford to misread.
    private mutating func reconcileAbandonedTasks(changes: inout [GraphChange]) {
        guard backgroundSnapshots >= 2 else { return }
        for (id, absences) in absentSnapshots.sorted(by: { $0.key < $1.key }) where absences >= 2 {
            guard let node = nodes[id], !node.isRoot, !node.state.isTerminal else { continue }
            transition(id, to: .errored("Stopped without reporting a result"), changes: &changes)
        }
    }

    // MARK: - Steering

    /// Records a steer written to stdin. It is *queued*, not delivered — the agent consumes it at
    /// the next turn boundary (docs/RUNTIME.md), which arrives as a replayed user message.
    @discardableResult
    public mutating func noteSteerQueued(text: String, agentID: String? = nil) -> [GraphChange] {
        var changes: [GraphChange] = []
        guard let id = agentID ?? rootID else {
            steersAwaitingRoot.append(text)
            return changes
        }
        append(.steerQueued(id: idGenerator(), text: text), to: id, changes: &changes)
        return changes
    }

    /// Marks the earliest matching queued steer as delivered.
    ///
    /// The echo does not always repeat what was written: a prompt that mentioned an image comes
    /// back with the mention replaced by an `[Image #1]` marker over a block of base64. Steers are
    /// consumed in the order they were written, so `byOrder` lets such an echo fall back to the
    /// oldest one still queued — and the row keeps the text the operator actually typed, which is
    /// the version that still names a file on disk to draw.
    @discardableResult
    private mutating func markSteerDelivered(
        text: String?, byOrder: Bool = false, on agentID: String, changes: inout [GraphChange]
    ) -> Bool {
        guard var node = nodes[agentID] else { return false }
        let exact = text.flatMap { text in
            node.transcript.firstIndex {
                if case .steerQueued(_, let queued) = $0 { return queued == text }
                return false
            }
        }
        let oldest = byOrder
            ? node.transcript.firstIndex { if case .steerQueued = $0 { return true } else { return false } }
            : nil
        guard let index = exact ?? oldest else { return false }

        guard case .steerQueued(_, let queued) = node.transcript[index] else { return false }
        let entryID = node.transcript[index].id
        node.transcript[index] = .steerDelivered(id: entryID, text: queued)
        nodes[agentID] = node
        changes.append(.transcriptAppended(id: agentID, entryID: entryID))
        return true
    }

    /// Retires the steers an interrupt threw away.
    ///
    /// Interrupting does not just stop the turn: anything written to stdin behind it is discarded
    /// with it, and the CLI never echoes those messages. Nothing on the frame stream retires them,
    /// so without this they stayed "queued" for the rest of the session — the composer counted work
    /// as pending that no agent would ever read, and the timeline promised delivery "at the next
    /// turn boundary" that had already come and gone.
    ///
    /// The text is kept rather than the row removed: it is what the operator wrote, and the honest
    /// answer is that it was dropped, not that it never happened.
    @discardableResult
    public mutating func noteInterrupted() -> [GraphChange] {
        var changes: [GraphChange] = []
        dropQueuedSteers(changes: &changes)
        return changes
    }

    /// Turns every steer still waiting into one that was never delivered. Sorted so the changes come
    /// out in a stable order rather than the dictionary's.
    private mutating func dropQueuedSteers(changes: inout [GraphChange]) {
        for (id, node) in nodes.sorted(by: { $0.key < $1.key }) {
            for (index, entry) in node.transcript.enumerated() {
                guard case .steerQueued(let entryID, let text) = entry else { continue }
                nodes[id]?.transcript[index] = .steerDropped(id: entryID, text: text)
                changes.append(.transcriptAppended(id: id, entryID: entryID))
            }
        }
    }

    // MARK: - Session lifecycle

    @discardableResult
    public mutating func noteSessionExit(status: Int32) -> [GraphChange] {
        var changes: [GraphChange] = []
        isSessionOver = true
        // Nothing is going to read what was still waiting on stdin.
        dropQueuedSteers(changes: &changes)
        for id in nodes.keys where nodes[id]?.state.isTerminal == false {
            transition(
                id,
                to: status == 0 ? .completed : .errored("Session exited with status \(status)"),
                changes: &changes)
        }
        return changes
    }

    @discardableResult
    public mutating func noteCancelled() -> [GraphChange] {
        var changes: [GraphChange] = []
        isSessionOver = true
        dropQueuedSteers(changes: &changes)
        for id in nodes.keys where nodes[id]?.state.isTerminal == false {
            transition(id, to: .cancelled, changes: &changes)
        }
        return changes
    }

    /// Empties every agent's transcript, for `/clear`.
    ///
    /// The tree, its capabilities, and what the session has spent all survive: `/clear` resets the
    /// conversation the agent is carrying, not the session that is carrying it. Spend already
    /// billed stays billed, and the agents are still there to talk to.
    ///
    /// `contextTokens` is the exception among the telemetry. It is the occupancy of the window,
    /// and after a clear the window is empty — leaving the last turn's figure standing would show
    /// a full ring over an empty conversation until the next turn happened to correct it.
    @discardableResult
    public mutating func clearTranscripts() -> [GraphChange] {
        var changes: [GraphChange] = []
        for id in nodes.keys {
            guard var node = nodes[id] else { continue }
            guard !node.transcript.isEmpty || !node.streamingText.isEmpty
                || node.telemetry.contextTokens != nil else { continue }
            node.transcript.removeAll()
            node.streamingText = ""
            node.telemetry.contextTokens = nil
            nodes[id] = node
            changes.append(.transcriptCleared(id: id))
        }
        return changes
    }

    // MARK: - Frame application helpers

    /// Folds a partial-message delta into the node's streaming buffer.
    ///
    /// The buffer is what the timeline shows while a reply is still being written. It is discarded
    /// the moment the complete block arrives as an `assistant` frame — the buffer is a preview, and
    /// the assembled block is the record.
    private mutating func apply(
        streamEvent eventType: String, event: JSONValue, to ownerID: String,
        changes: inout [GraphChange]
    ) {
        switch eventType {
        case "content_block_delta":
            guard event.value(at: "delta", "type")?.stringValue == "text_delta",
                  let text = event.value(at: "delta", "text")?.stringValue,
                  !text.isEmpty
            else { break }
            nodes[ownerID]?.streamingText += text
            changes.append(.streamingUpdated(id: ownerID))

        case "content_block_start":
            // A new block replaces whatever preview was on screen for the previous one.
            if nodes[ownerID]?.streamingText.isEmpty == false {
                nodes[ownerID]?.streamingText = ""
                changes.append(.streamingUpdated(id: ownerID))
            }

        case "message_stop":
            if nodes[ownerID]?.streamingText.isEmpty == false {
                nodes[ownerID]?.streamingText = ""
                changes.append(.streamingUpdated(id: ownerID))
            }

        default:
            break
        }
    }

    private mutating func apply(
        message: AssistantMessage, to ownerID: String, changes: inout [GraphChange]
    ) {
        // Usage rides on the frame that carries the reply, and is that call's own accounting —
        // the `result` frame's usage is the whole turn added up, which is a different number.
        if let usage = message.usage {
            func tokens(_ key: String) -> Int { usage[key]?.intValue ?? 0 }
            let input = tokens("input_tokens")
                + tokens("cache_read_input_tokens")
                + tokens("cache_creation_input_tokens")
            let output = tokens("output_tokens")
            // Frames arrive one per content block, all sharing a message id, and every one repeats
            // that message's usage. Counting each would multiply the bill by the block count.
            if lastCountedMessageID[ownerID] != message.id {
                lastCountedMessageID[ownerID] = message.id
                nodes[ownerID]?.telemetry.contextTokens = input + output
                nodes[ownerID]?.telemetry.billedTokens += input + output
                changes.append(.telemetryUpdated(id: ownerID))
            }
        }

        // The assembled blocks supersede the preview.
        if nodes[ownerID]?.streamingText.isEmpty == false {
            nodes[ownerID]?.streamingText = ""
            changes.append(.streamingUpdated(id: ownerID))
        }
        for block in message.content {
            switch block {
            case .thinking(let text, _):
                append(.thinking(id: idGenerator(), messageID: message.id, text: text),
                       to: ownerID, changes: &changes)
                if isWorkable(ownerID) {
                    transition(ownerID, to: .thinking, changes: &changes)
                }

            case .text(let text):
                append(.text(id: idGenerator(), messageID: message.id, text: text),
                       to: ownerID, changes: &changes)

            case .toolUse(let use):
                append(.toolCall(id: idGenerator(), use: use), to: ownerID, changes: &changes)
                toolCallOwner[use.id] = ownerID
                nodes[ownerID]?.telemetry.toolUseCount += 1
                changes.append(.telemetryUpdated(id: ownerID))
                transition(
                    ownerID, to: .executingTool(name: use.name, toolUseID: use.id),
                    changes: &changes)

            case .toolResult, .other:
                break
            }
        }
    }

    private mutating func apply(
        userMessage: UserMessage, to ownerID: String, changes: inout [GraphChange]
    ) {
        // The replay of an injected steer, confirming the agent consumed it.
        if userMessage.isReplayedUserInput {
            let texts = userMessage.replayedText
            // The CLI rewrites the text of a message it attached files to, so only those echoes are
            // allowed to match a queued steer they do not read like.
            let wasRewritten = texts.count != userMessage.content.count
            // An image with nothing typed alongside it still confirms the steer it came from.
            guard !texts.isEmpty else {
                markSteerDelivered(text: nil, byOrder: true, on: ownerID, changes: &changes)
                return
            }
            for text in texts {
                if !markSteerDelivered(
                    text: text, byOrder: wasRewritten, on: ownerID, changes: &changes) {
                    append(.steerDelivered(id: idGenerator(), text: text),
                           to: ownerID, changes: &changes)
                }
            }
            return
        }

        for case .toolResult(let result) in userMessage.content {
            var output: ProcessOutput?
            if case .process(let processOutput)? = userMessage.toolUseResult { output = processOutput }
            let target = toolCallOwner[result.toolUseID] ?? ownerID
            append(.toolResult(id: idGenerator(), result: result, output: output),
                   to: target, changes: &changes)
            toolCallOwner.removeValue(forKey: result.toolUseID)

            if result.isError {
                nodes[target]?.telemetry.approvalsDenied += 1
                changes.append(.telemetryUpdated(id: target))
            }
            // A subagent launch returns immediately; its node reports its own completion.
            if isWorkable(target) {
                transition(target, to: .thinking, changes: &changes)
            }
        }
    }

    private mutating func apply(
        turnResult: TurnResult, to ownerID: String, changes: inout [GraphChange]
    ) {
        guard var node = nodes[ownerID] else { return }
        node.telemetry.turnCount += 1
        // Cost is cumulative per turn; keep the highest reported figure.
        if let cost = turnResult.totalCostUSD {
            node.telemetry.costUSD = max(node.telemetry.costUSD ?? 0, cost)
        }
        nodes[ownerID] = node
        changes.append(.telemetryUpdated(id: ownerID))

        append(.turnEnded(id: idGenerator(), result: turnResult), to: ownerID, changes: &changes)

        // A `result` frame is a turn boundary, not the end of the session (docs/RUNTIME.md): the agent
        // goes idle and stays available for the next message.
        if turnResult.isError {
            transition(ownerID, to: .errored(turnResult.text ?? "Turn failed"), changes: &changes)
        } else if isWorkable(ownerID) {
            // A good turn after a failed one clears the failure: the root is idle and waiting, which
            // is what the composer is offering to do next.
            transition(ownerID, to: .idle, changes: &changes)
        }
    }

    // MARK: - Node management

    private mutating func ensureOwner(for frame: Frame, changes: inout [GraphChange]) -> String {
        if let parentToolUseID = frame.parentToolUseID,
           let id = nodeIDByToolUseID[parentToolUseID] {
            return id
        }
        if let rootID { return rootID }

        let sessionID = frame.sessionID ?? "session"
        let node = AgentNode(
            id: sessionID,
            kind: .root(sessionID: sessionID),
            parentID: nil,
            title: "Root agent")
        nodes[sessionID] = node
        rootID = sessionID
        changes.append(.nodeAdded(id: sessionID))
        for steer in steersAwaitingRoot {
            append(.steerQueued(id: idGenerator(), text: steer), to: sessionID, changes: &changes)
        }
        steersAwaitingRoot = []
        return sessionID
    }

    private mutating func addSubagent(
        task: TaskStarted, parentID: String, changes: inout [GraphChange]
    ) {
        guard nodes[task.taskID] == nil else { return }
        let node = AgentNode(
            id: task.taskID,
            kind: .subagent(
                taskID: task.taskID, toolUseID: task.toolUseID, subagentType: task.subagentType),
            parentID: parentID,
            title: task.description.isEmpty ? task.subagentType : task.description,
            state: .thinking)
        nodes[task.taskID] = node
        nodes[parentID]?.children.append(task.taskID)
        nodeIDByToolUseID[task.toolUseID] = task.taskID
        changes.append(.nodeAdded(id: task.taskID))
    }

    private func nodeID(forTaskID taskID: String) -> String? {
        nodes[taskID] != nil ? taskID : nil
    }

    private func currentToolName(for id: String) -> String? {
        if case .executingTool(let name, _) = nodes[id]?.state { return name }
        // The hook fires before the tool is marked running, so fall back to the last call.
        for entry in (nodes[id]?.transcript ?? []).reversed() {
            if case .toolCall(_, let use) = entry { return use.name }
        }
        return nil
    }

    private func inFlightToolUseID(for id: String) -> String? {
        if case .executingTool(_, let toolUseID) = nodes[id]?.state { return toolUseID }
        for entry in (nodes[id]?.transcript ?? []).reversed() {
            if case .toolCall(_, let use) = entry { return use.id }
        }
        return nil
    }

    private mutating func transition(
        _ id: String, to state: AgentState, changes: inout [GraphChange]
    ) {
        guard let current = nodes[id]?.state, current != state else { return }
        // Terminal states are final; late frames must not resurrect a finished agent.
        guard !current.isTerminal || canReopen(id) else { return }
        nodes[id]?.state = state
        changes.append(.stateChanged(id: id, from: current, to: state))
    }

    /// Whether an agent already in a terminal state may be put back to work.
    ///
    /// Only the root, and only while the session is still up. A `result` frame is a *turn* boundary,
    /// not the end of the session (docs/RUNTIME.md): a turn that fails — a refusal, a tool the model
    /// gave up on, an interrupt — leaves the CLI running and ready for the next message. Reading
    /// that outcome as the end of the agent meant one failed turn pinned the root on "Failed" for
    /// the rest of the session, while the operator went on steering it and watching it work.
    ///
    /// A subagent is the opposite case and keeps the old rule: its node ends when its task ends, and
    /// a late frame must not resurrect it.
    private func canReopen(_ id: String) -> Bool {
        !isSessionOver && nodes[id]?.isRoot == true
    }

    /// Whether an agent can be moved on by an arriving frame: either it never finished, or it is the
    /// root of a session that is still up.
    private func isWorkable(_ id: String) -> Bool {
        nodes[id]?.state.isTerminal == false || canReopen(id)
    }

    private mutating func append(
        _ entry: TranscriptEntry, to id: String, changes: inout [GraphChange]
    ) {
        nodes[id]?.transcript.append(entry)
        changes.append(.transcriptAppended(id: id, entryID: entry.id))
    }
}

// MARK: - Approval integration

extension AgentGraph {
    /// Records the outcome of an approval so the tree reflects operator decisions, not just runtime
    /// frames. Call from the `ApprovalBroker` audit stream.
    @discardableResult
    public mutating func noteApproval(
        toolUseID: String, decision: ApprovalDecision
    ) -> [GraphChange] {
        var changes: [GraphChange] = []
        guard let id = toolCallOwner[toolUseID] ?? rootID else { return changes }
        if decision.verdict == .deny {
            nodes[id]?.telemetry.approvalsDenied += 1
            changes.append(.telemetryUpdated(id: id))
            if decision.provenance != .operatorDecision {
                append(.incident(id: idGenerator(),
                                 text: "Blocked automatically: \(decision.reason)"),
                       to: id, changes: &changes)
            }
        }
        return changes
    }
}
