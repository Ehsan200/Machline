import Foundation
import Testing
@testable import HarnessCore

@Suite("Agent graph construction")
struct AgentGraphTests {

    static func graph(replaying fixture: Fixture) throws -> AgentGraph {
        var graph = AgentGraph()
        for frame in try fixture.frames() { graph.apply(frame: frame) }
        return graph
    }

    static func changes(replaying fixture: Fixture) throws -> [GraphChange] {
        var graph = AgentGraph()
        return try fixture.frames().flatMap { graph.apply(frame: $0) }
    }

    static func frame(_ json: String) throws -> Frame {
        guard case .frame(let frame) = FrameDecoder().decode(line: json) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: json))
        }
        return frame
    }

    // MARK: - Tree shape

    @Test("A plain session yields a single root that ends idle, not completed")
    func plainSessionRoot() throws {
        let graph = try Self.graph(replaying: .plainTurn)
        let root = try #require(graph.root)
        #expect(graph.nodes.count == 1)
        #expect(root.isRoot)
        #expect(root.children.isEmpty)
        // `result` is a turn boundary; the session is still alive and can take another message.
        #expect(root.state == .idle)
        #expect(root.telemetry.turnCount == 1)
        #expect((root.telemetry.costUSD ?? 0) > 0)
    }

    @Test("A subagent launch produces a child node linked to its parent")
    func subagentTree() throws {
        let graph = try Self.graph(replaying: .subagent)
        let root = try #require(graph.root)
        #expect(graph.nodes.count == 2)

        let child = try #require(graph.children(of: root.id).first)
        #expect(child.parentID == root.id)
        #expect(child.state == .completed)
        guard case .subagent(_, let toolUseID, let type) = child.kind else {
            Issue.record("Expected a subagent node")
            return
        }
        #expect(type == "echoer")
        #expect(toolUseID.hasPrefix("toolu_"))

        let ordered = graph.orderedNodes()
        #expect(ordered.map(\.id) == [root.id, child.id], "Parents precede their children")
    }

    /// Subagent output must be attributed to the subagent, not merged into the parent's transcript.
    @Test("Subagent output lands in the subagent's transcript")
    func subagentTranscriptAttribution() throws {
        let graph = try Self.graph(replaying: .subagent)
        let root = try #require(graph.root)
        let child = try #require(graph.children(of: root.id).first)

        let childText = child.transcript.compactMap { entry -> String? in
            if case .text(_, _, let text) = entry { return text }
            return nil
        }
        #expect(childText.contains("HI"))

        let rootText = root.transcript.compactMap { entry -> String? in
            if case .text(_, _, let text) = entry { return text }
            return nil
        }
        #expect(!rootText.contains("HI"), "The child's reply must not appear in the parent")
    }

    @Test("Per-subagent telemetry is captured from task_notification")
    func subagentTelemetry() throws {
        let graph = try Self.graph(replaying: .subagent)
        let root = try #require(graph.root)
        let child = try #require(graph.children(of: root.id).first)
        #expect(child.telemetry.totalTokens == 666)
        #expect(child.telemetry.durationMS != nil)
    }

    /// Two `result` frames arrive in this transcript because a background subagent finished after
    /// the parent's turn ended. Neither may be read as the session ending.
    @Test("Multiple turn boundaries leave the root alive")
    func multipleTurnsDoNotEndTheSession() throws {
        let root = try #require(try Self.graph(replaying: .subagent).root)
        #expect(root.telemetry.turnCount == 2)
        #expect(root.state == .idle)
        #expect(!root.state.isTerminal)
    }

    // MARK: - Subagents that stop

    /// The frames below are the shapes an interrupted session produced against the real CLI: the
    /// only announcement a killed agent gets is a `killed` status on `task_updated` and a `stopped`
    /// one on `task_notification`. Matching `completed`/`failed`/`cancelled` alone left it
    /// "Thinking" forever, with nothing on screen to say the work had stopped.
    static func graphWithSubagent() throws -> AgentGraph {
        var graph = AgentGraph()
        graph.apply(frame: try frame(
            #"{"type":"system","subtype":"task_started","task_id":"t1","tool_use_id":"toolu_1","description":"Wait for docker build","subagent_type":"general-purpose","task_type":"local_agent","session_id":"s","uuid":"u1"}"#))
        return graph
    }

    @Test("A killed subagent ends as cancelled, not left thinking")
    func killedSubagentIsSurfaced() throws {
        var graph = try Self.graphWithSubagent()
        #expect(graph.node(id: "t1")?.state == .thinking)

        graph.apply(frame: try Self.frame(
            #"{"type":"system","subtype":"task_updated","task_id":"t1","patch":{"status":"killed","end_time":1787478239507},"session_id":"s","uuid":"u2"}"#))

        let child = try #require(graph.node(id: "t1"))
        #expect(child.state == .cancelled)
        #expect(child.transcript.contains {
            if case .incident(_, let text) = $0 { return text.contains("killed") }
            return false
        })
    }

    @Test("A stopped task notification ends the subagent")
    func stoppedNotificationIsSurfaced() throws {
        var graph = try Self.graphWithSubagent()
        graph.apply(frame: try Self.frame(
            #"{"type":"system","subtype":"task_notification","task_id":"t1","tool_use_id":"toolu_1","status":"stopped","summary":"Wait for docker build","session_id":"s","uuid":"u2"}"#))
        #expect(graph.node(id: "t1")?.state == .cancelled)
    }

    @Test("An unrecognised task status ends the agent and names itself")
    func unknownStatusEndsTheAgent() throws {
        var graph = try Self.graphWithSubagent()
        graph.apply(frame: try Self.frame(
            #"{"type":"system","subtype":"task_updated","task_id":"t1","patch":{"status":"evicted"},"session_id":"s","uuid":"u2"}"#))
        #expect(graph.node(id: "t1")?.state == .errored("Task evicted"))
    }

    /// The backstop for a kill that announces nothing at all: the CLI stops listing the task, and
    /// the next turn boundary finds it still running with no status behind it.
    @Test("A subagent the CLI stopped listing is ended at the next turn boundary")
    func vanishedSubagentIsReconciled() throws {
        var graph = try Self.graphWithSubagent()
        let live =
            #"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"t1","task_type":"local_agent","description":"Wait for docker build"}],"session_id":"s","uuid":"u2"}"#
        let empty =
            #"{"type":"system","subtype":"background_tasks_changed","tasks":[],"session_id":"s","uuid":"u3"}"#
        let turnEnd =
            #"{"type":"result","subtype":"success","is_error":false,"num_turns":1,"session_id":"s","uuid":"u4"}"#

        graph.apply(frame: try Self.frame(live))
        graph.apply(frame: try Self.frame(turnEnd))
        #expect(graph.node(id: "t1")?.state == .thinking, "A listed agent survives a turn boundary")

        // One absence is the snapshot running a moment ahead of the status frames, not a death.
        graph.apply(frame: try Self.frame(empty))
        graph.apply(frame: try Self.frame(turnEnd))
        #expect(graph.node(id: "t1")?.state == .thinking, "One missed snapshot is not a verdict")

        graph.apply(frame: try Self.frame(empty))
        graph.apply(frame: try Self.frame(turnEnd))
        #expect(graph.node(id: "t1")?.state == .errored("Stopped without reporting a result"))
    }

    @Test("A subagent that reported completion is never second-guessed by the snapshot")
    func completedSubagentSurvivesReconciliation() throws {
        var graph = try Self.graphWithSubagent()
        graph.apply(frame: try Self.frame(
            #"{"type":"system","subtype":"task_updated","task_id":"t1","patch":{"status":"completed"},"session_id":"s","uuid":"u2"}"#))
        for uuid in ["u3", "u4", "u5"] {
            graph.apply(frame: try Self.frame(
                #"{"type":"system","subtype":"background_tasks_changed","tasks":[],"session_id":"s","uuid":"\#(uuid)"}"#))
            graph.apply(frame: try Self.frame(
                #"{"type":"result","subtype":"success","is_error":false,"num_turns":1,"session_id":"s","uuid":"\#(uuid)r"}"#))
        }
        #expect(graph.node(id: "t1")?.state == .completed)
    }

    // MARK: - Tool execution

    @Test("A tool call moves the agent through executing and back")
    func toolCallStates() throws {
        let changes = try Self.changes(replaying: .bashToolCall)
        let states = changes.compactMap { change -> AgentState? in
            if case .stateChanged(_, _, let to) = change { return to }
            return nil
        }
        #expect(states.contains { if case .executingTool(let name, _) = $0 { return name == "Bash" } else { return false } })
        #expect(states.last == .idle)
    }

    /// The structured sidecar means stdout and stderr reach the terminal buffer already separated.
    @Test("Tool results carry their separated process output")
    func toolResultCarriesOutput() throws {
        let root = try #require(try Self.graph(replaying: .bashToolCall).root)
        let outputs = root.transcript.compactMap { entry -> ProcessOutput? in
            if case .toolResult(_, _, let output) = entry { return output }
            return nil
        }
        let output = try #require(outputs.first)
        #expect(output.stdout == "hello-from-tool")
        #expect(output.stderr.isEmpty)
        #expect(!output.interrupted)
    }

    @Test("Assistant blocks keep their message id so the UI can group them")
    func transcriptGroupsByMessageID() throws {
        let root = try #require(try Self.graph(replaying: .plainTurn).root)
        let messageIDs = Set(root.transcript.compactMap(\.messageID))
        #expect(messageIDs.count == 1, "One reply, one message id, two content blocks")
        #expect(root.transcript.contains { if case .thinking = $0 { return true } else { return false } })
        #expect(root.transcript.contains { if case .text = $0 { return true } else { return false } })
    }

    // MARK: - Approvals

    @Test("A pending approval is a distinct state, and a denial is counted")
    func approvalStates() throws {
        let changes = try Self.changes(replaying: .hookDeny)
        let waiting = changes.contains { change in
            if case .stateChanged(_, _, .waitingForApproval(let tool, _)) = change { return tool == "Bash" }
            return false
        }
        #expect(waiting, "The hook must surface as an explicit approval wait")

        let root = try #require(try Self.graph(replaying: .hookDeny).root)
        #expect(root.telemetry.approvalsRequested == 1)
        #expect(root.telemetry.approvalsDenied == 1)
        #expect(!root.hasFailOpenIncident)
    }

    /// **Finding 1 surfacing.** A hook the runtime cancelled means a command ran unapproved. The
    /// graph must raise it as an incident rather than letting it pass as an ordinary tool call.
    @Test("A runtime-cancelled hook is raised as a fail-open incident")
    func failOpenIsSurfaced() throws {
        let changes = try Self.changes(replaying: .hookTimeoutFailOpen)
        #expect(changes.contains { if case .failOpenIncident = $0 { return true } else { return false } })

        let root = try #require(try Self.graph(replaying: .hookTimeoutFailOpen).root)
        #expect(root.hasFailOpenIncident)
        let incidents = root.transcript.compactMap { entry -> String? in
            if case .incident(_, let text) = entry { return text }
            return nil
        }
        #expect(incidents.contains { $0.contains("without approval") })
        #expect(root.failOpenIncidentCount == 1)
    }

    /// The incident banner can be dismissed, and the UI decides whether a dismissal still stands by
    /// comparing counts. A flag could not tell a second fail-open from the one already acknowledged,
    /// which is the one case the banner exists for.
    @Test("Fail-open incidents accumulate rather than latching")
    func failOpensAreCounted() throws {
        var graph = AgentGraph()
        let response =
            #"{"type":"system","subtype":"hook_response","hook_name":"PreToolUse:Bash","hook_event":"PreToolUse","outcome":"cancelled","session_id":"s","uuid":"u1"}"#
        graph.apply(frame: try Self.frame(response))
        graph.apply(frame: try Self.frame(response))

        let root = try #require(graph.root)
        #expect(root.failOpenIncidentCount == 2)
        #expect(root.hasFailOpenIncident)
    }

    @Test("Approval outcomes from the broker are recorded against the calling agent")
    func brokerDecisionsAreRecorded() throws {
        var graph = AgentGraph()
        for frame in try Fixture.bashToolCall.frames() { graph.apply(frame: frame) }
        let root = try #require(graph.root)
        let before = root.telemetry.approvalsDenied

        graph.noteApproval(
            toolUseID: "toolu_01BJc9bS54rB2RFWk46Z7aTe",
            decision: .failClosed(.brokerTimeout, detail: "no operator responded"))

        let after = try #require(graph.node(id: root.id))
        #expect(after.telemetry.approvalsDenied == before + 1)
        #expect(after.transcript.contains { if case .incident = $0 { return true } else { return false } })
    }

    // MARK: - Steering

    /// A steer is queued when written and only becomes delivered when the agent echoes it back
    /// (docs/RUNTIME.md). The distinction is what stops a multi-minute wait from reading as a hang.
    @Test("A steer stays queued until the replay echo confirms consumption")
    func steerQueuedThenDelivered() throws {
        var graph = AgentGraph()
        graph.apply(frame: try Self.frame(
            #"{"type":"system","subtype":"status","status":"requesting","session_id":"s","uuid":"u1"}"#))

        graph.noteSteerQueued(text: "Use the clean target instead.")
        var root = try #require(graph.root)
        #expect(root.transcript.contains { if case .steerQueued = $0 { return true } else { return false } })
        #expect(!root.transcript.contains { if case .steerDelivered = $0 { return true } else { return false } })

        graph.apply(frame: try Self.frame(
            #"{"type":"user","session_id":"s","uuid":"u2","message":{"role":"user","content":[{"type":"text","text":"Use the clean target instead."}]}}"#))

        root = try #require(graph.root)
        #expect(!root.transcript.contains { if case .steerQueued = $0 { return true } else { return false } })
        #expect(root.transcript.contains {
            if case .steerDelivered(_, let text) = $0 { return text == "Use the clean target instead." }
            return false
        })
        #expect(root.transcript.count == 1, "The queued entry is replaced, not duplicated")
    }

    /// Probe-verified against the real CLI: a message written to stdin mid-turn and followed by
    /// `SIGINT` is discarded, and no echo for it ever arrives. Left queued, it was counted as
    /// pending work by the composer for the rest of the session — "3 queued" over an empty box.
    @Test("An interrupt retires the steers it threw away")
    func interruptDropsQueuedSteers() throws {
        var graph = AgentGraph()
        graph.apply(frame: try Self.frame(
            #"{"type":"system","subtype":"status","status":"requesting","session_id":"s","uuid":"u1"}"#))
        graph.noteSteerQueued(text: "Try the other target.")

        let changes = graph.noteInterrupted()
        #expect(!changes.isEmpty)

        let root = try #require(graph.root)
        #expect(!root.transcript.contains { if case .steerQueued = $0 { return true } else { return false } })
        #expect(root.transcript.contains {
            if case .steerDropped(_, let text) = $0 { return text == "Try the other target." }
            return false
        })
        #expect(root.transcript.count == 1, "The queued entry is replaced, not duplicated")
    }

    @Test("A stopped session retires what it never read")
    func stopDropsQueuedSteers() throws {
        var graph = AgentGraph()
        graph.apply(frame: try Self.frame(
            #"{"type":"system","subtype":"status","status":"requesting","session_id":"s","uuid":"u1"}"#))
        graph.noteSteerQueued(text: "Never read.")
        graph.noteCancelled()

        let root = try #require(graph.root)
        #expect(root.transcript.contains { if case .steerDropped = $0 { return true } else { return false } })
    }

    /// A delivered steer is history, not pending work: an interrupt must not rewrite it.
    @Test("An interrupt leaves delivered steers alone")
    func interruptSparesDeliveredSteers() throws {
        var graph = AgentGraph()
        graph.apply(frame: try Self.frame(
            #"{"type":"system","subtype":"status","status":"requesting","session_id":"s","uuid":"u1"}"#))
        graph.noteSteerQueued(text: "Landed.")
        graph.apply(frame: try Self.frame(
            #"{"type":"user","session_id":"s","uuid":"u2","message":{"role":"user","content":[{"type":"text","text":"Landed."}]}}"#))
        graph.noteInterrupted()

        let root = try #require(graph.root)
        #expect(root.transcript.contains { if case .steerDelivered = $0 { return true } else { return false } })
        #expect(!root.transcript.contains { if case .steerDropped = $0 { return true } else { return false } })
    }

    /// The prompt that starts a session is written before the CLI has emitted anything, so there is
    /// no root to hang it on yet. Dropped, the opening message of every session existed only in the
    /// echo — and an echo carrying an image never arrives as one.
    @Test("A steer written before the first frame still lands on the root")
    func steerBeforeRootIsKept() throws {
        var graph = AgentGraph()
        graph.noteSteerQueued(text: "@/tmp/shot.png what is wrong here?")
        #expect(graph.root == nil)

        graph.apply(frame: try Self.frame(
            #"{"type":"system","subtype":"status","status":"requesting","session_id":"s","uuid":"u1"}"#))

        let root = try #require(graph.root)
        #expect(root.transcript.contains {
            if case .steerQueued(_, let text) = $0 { return text == "@/tmp/shot.png what is wrong here?" }
            return false
        })
    }

    /// A prompt that mentioned an image echoes back as text *plus* an `image` block, and with the
    /// mention rewritten to `[Image #1]`. Neither the block nor the rewrite may cost the operator
    /// their message: the row stays, and it keeps the text that still names a file to draw.
    @Test("An echo carrying an image delivers the steer it came from")
    func imageEchoDeliversTheSteer() throws {
        var graph = AgentGraph()
        graph.noteSteerQueued(text: "@/tmp/shot.png what is wrong here?")
        graph.apply(frame: try Self.frame(
            #"{"type":"system","subtype":"status","status":"requesting","session_id":"s","uuid":"u1"}"#))

        graph.apply(frame: try Self.frame(
            #"{"type":"user","session_id":"s","uuid":"u2","message":{"role":"user","content":[{"type":"text","text":"[Image #1] what is wrong here?"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw0KGgo="}}]}}"#))

        let root = try #require(graph.root)
        #expect(root.transcript.count == 1, "One message, not one row per content block")
        #expect(root.transcript.contains {
            if case .steerDelivered(_, let text) = $0 {
                return text == "@/tmp/shot.png what is wrong here?"
            }
            return false
        })
    }

    // MARK: - Lifecycle

    @Test("Session exit finalises every live node")
    func sessionExitFinalises() throws {
        var graph = try Self.graph(replaying: .subagent)
        graph.noteSessionExit(status: 0)
        #expect(graph.nodes.values.allSatisfy { $0.state.isTerminal })
        #expect(graph.root?.state == .completed)
    }

    /// A late frame must not resurrect a finished agent — otherwise a completed subagent can flip
    /// back to Thinking and never settle.
    @Test("Terminal states are final")
    func terminalStatesAreFinal() throws {
        var graph = try Self.graph(replaying: .subagent)
        graph.noteSessionExit(status: 0)
        let changes = graph.apply(frame: try Self.frame(
            #"{"type":"system","subtype":"status","status":"requesting","session_id":"s","uuid":"u9"}"#))
        #expect(changes.allSatisfy { if case .stateChanged = $0 { return false } else { return true } })
        #expect(graph.root?.state == .completed)
    }

    /// A `result` frame is a turn boundary. A turn that fails leaves the CLI running and ready for
    /// the next message, so the root must be able to go back to work — it sat on "Failed" for the
    /// rest of the session while the operator steered it and watched it answer.
    @Test("A failed turn does not end the root agent")
    func failedTurnIsRecoverable() throws {
        var graph = try Self.graph(replaying: .plainTurn)
        let rootID = try #require(graph.rootID)

        graph.apply(frame: try Self.frame(
            #"{"type":"result","is_error":true,"result":"Turn failed","session_id":"s","uuid":"u1"}"#))
        #expect(graph.root?.state == .errored("Turn failed"))

        // The next thing the agent does puts it back to work.
        graph.apply(frame: try Self.frame(
            #"{"type":"assistant","session_id":"s","uuid":"u2","message":{"id":"m1","role":"assistant","content":[{"type":"thinking","thinking":"Carrying on."}]}}"#))
        #expect(graph.node(id: rootID)?.state == .thinking)

        graph.apply(frame: try Self.frame(
            #"{"type":"result","is_error":false,"session_id":"s","uuid":"u3"}"#))
        #expect(graph.node(id: rootID)?.state == .idle)
    }

    /// The same forgiveness must not reach a subagent: its node ends when its task ends.
    @Test("A finished subagent stays finished")
    func subagentStaysFinished() throws {
        var graph = try Self.graph(replaying: .subagent)
        let root = try #require(graph.root)
        let child = try #require(graph.children(of: root.id).first)
        #expect(child.state == .completed)
        guard case .subagent(_, let toolUseID, _) = child.kind else {
            Issue.record("Expected a subagent node")
            return
        }

        graph.apply(frame: try Self.frame(
            """
            {"type":"assistant","session_id":"s","uuid":"u2","parent_tool_use_id":"\(toolUseID)",\
            "message":{"id":"m2","role":"assistant","content":[{"type":"thinking","thinking":"Late."}]}}
            """))
        #expect(graph.node(id: child.id)?.state == .completed)
    }

    /// Once the session is over the root is finished like anything else.
    @Test("A stopped session does not reopen its root")
    func stoppedSessionStaysStopped() throws {
        var graph = try Self.graph(replaying: .plainTurn)
        graph.noteCancelled()
        #expect(graph.root?.state == .cancelled)

        graph.apply(frame: try Self.frame(
            #"{"type":"assistant","session_id":"s","uuid":"u2","message":{"id":"m1","role":"assistant","content":[{"type":"thinking","thinking":"Too late."}]}}"#))
        #expect(graph.root?.state == .cancelled)
    }

    @Test("A non-zero exit marks the session errored")
    func nonZeroExitErrors() throws {
        var graph = try Self.graph(replaying: .plainTurn)
        graph.noteSessionExit(status: 2)
        let root = try #require(graph.root)
        guard case .errored(let message) = root.state else {
            Issue.record("Expected an errored root")
            return
        }
        #expect(message.contains("2"))
    }

    @Test("Replaying every archived transcript produces a consistent tree", arguments: Fixture.allCases)
    func replayIsConsistent(fixture: Fixture) throws {
        let graph = try Self.graph(replaying: fixture)
        #expect(graph.root != nil, "\(fixture.rawValue) produced no root")
        for node in graph.nodes.values {
            if let parentID = node.parentID {
                #expect(graph.node(id: parentID)?.children.contains(node.id) == true,
                        "Dangling parent link on \(node.id)")
            }
        }
        #expect(graph.orderedNodes().count == graph.nodes.count, "Every node must be reachable")
    }
}
