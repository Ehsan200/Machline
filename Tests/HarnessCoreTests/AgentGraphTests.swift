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
    /// (README, Runtime). The distinction is what stops a multi-minute wait from reading as a hang.
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
