import Foundation
import Testing
@testable import HarnessCore

/// The full stack: CLI child process, approval gate, and derived agent tree, exercised together.
/// Opt-in via `HARNESS_LIVE_TESTS=1`.
@Suite("Live agent session",
       .enabled(if: ProcessInfo.processInfo.environment["HARNESS_LIVE_TESTS"] == "1"),
       .serialized)
struct LiveSessionTests {

    static func makeSession(
        policy: PolicyStore = PolicyStore(),
        tools: [String] = ["Bash"],
        agentsJSON: String? = nil,
        extraArguments: [String] = []
    ) throws -> (session: AgentSession, workspace: URL) {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("harness-session-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        var configuration = SessionConfiguration(
            workingDirectory: workspace, model: "haiku", tools: tools)
        configuration.disallowedTools = []
        configuration.agentsJSON = agentsJSON
        configuration.additionalArguments = extraArguments

        let session = try AgentSession(
            configuration: configuration,
            helperPath: ApprovalHelperTests.helperURL.path,
            socketPath: ApprovalBrokerTests.temporarySocketPath(),
            settingsPath: workspace.appendingPathComponent("settings.json"),
            policy: policy,
            runtimeHookTimeout: 60,
            helperDeadline: 30,
            operatorWait: 20)
        return (session, workspace)
    }

    /// The gate, the transitions, and the audit trail, observed through one stream.
    @Test("A gated session records approval, execution, and audit in the tree", .timeLimit(.minutes(3)))
    func gatedSessionProducesCoherentTree() async throws {
        let (session, _) = try Self.makeSession(extraArguments: ["--allowedTools", "Bash(echo *)"])
        let updates = try await session.start()
        try await session.send(steer: "Run the bash command: echo session-marker")

        var sawApprovalWait = false
        var sawExecuting = false
        var audited: [ApprovalDecision] = []

        for await update in updates {
            switch update {
            case .approvalPending(let pending):
                #expect(pending.payload.bashCommand?.contains("session-marker") == true)
                pending.approveOnce()
            case .approvalResolved(_, let decision):
                audited.append(decision)
            case .graphChanged(let changes):
                for case .stateChanged(_, _, let to) in changes {
                    if case .waitingForApproval = to { sawApprovalWait = true }
                    if case .executingTool(let name, _) = to, name == "Bash" { sawExecuting = true }
                }
            case .turnCompleted:
                await session.endInput()
            case .exited:
                break
            default:
                break
            }
        }

        #expect(sawApprovalWait, "The tree must show the agent blocked on the operator")
        #expect(sawExecuting, "…then running the tool once approved")
        #expect(audited.count == 1)
        #expect(audited.first?.verdict == .allow)
        #expect(audited.first?.provenance == .operatorDecision)

        let graph = await session.graph
        let root = try #require(graph.root)
        #expect(root.state.isTerminal, "The session exited, so the root is finalised")
        #expect(root.telemetry.approvalsRequested == 1)
        #expect(root.telemetry.turnCount >= 1)
        #expect(!root.hasFailOpenIncident)

        let output = root.transcript.compactMap { entry -> ProcessOutput? in
            if case .toolResult(_, _, let output) = entry { return output }
            return nil
        }
        #expect(output.contains { $0.stdout.contains("session-marker") })
    }

    /// The tree assembled from a real subagent launch, end to end.
    @Test("A live subagent appears as a child node with its own transcript", .timeLimit(.minutes(3)))
    func liveSubagentBuildsTree() async throws {
        let agents = #"{"echoer":{"description":"Echoes","prompt":"You are an echo bot. Reply with the word HI and nothing else.","tools":[]}}"#
        let (session, _) = try Self.makeSession(tools: ["Task"], agentsJSON: agents)
        let updates = try await session.start()
        try await session.send(
            steer: "Use the Task tool to launch the echoer agent with the prompt: say hi")

        var turns = 0
        for await update in updates {
            switch update {
            case .approvalPending(let pending):
                pending.approveOnce()
            case .turnCompleted:
                turns += 1
                // A background subagent can report after the parent's turn, so allow a second turn.
                if turns >= 2 { await session.endInput() }
            case .exited:
                break
            default:
                break
            }
            if turns >= 2, case .exited = update { break }
        }

        let graph = await session.graph
        let root = try #require(graph.root)
        let child = try #require(graph.children(of: root.id).first, "No subagent node was created")

        guard case .subagent(_, _, let type) = child.kind else {
            Issue.record("Expected a subagent node")
            return
        }
        #expect(type == "echoer")
        #expect(child.state.isTerminal)

        let childText = child.transcript.compactMap { entry -> String? in
            if case .text(_, _, let text) = entry { return text }
            return nil
        }.joined()
        #expect(childText.contains("HI"), "The subagent's own reply belongs to its node")
        #expect(child.telemetry.totalTokens ?? 0 > 0, "Per-subagent telemetry should arrive")
    }

    /// A steer written while a tool is running stays queued in the tree until the agent consumes it,
    /// so a multi-minute wait is visibly pending rather than looking like a hang.
    @Test("A queued steer becomes delivered in the tree", .timeLimit(.minutes(3)))
    func steerLifecycleIsVisible() async throws {
        var policy = PolicyStore()
        policy.add(.allowBashPrefix("sleep"))
        let (session, _) = try Self.makeSession(
            policy: policy, extraArguments: ["--allowedTools", "Bash(sleep *)"])

        let updates = try await session.start()
        try await session.send(
            steer: "Run bash `sleep 8`, then afterwards tell me the secret word you were given.")

        let steer = "MID-TURN STEER: the secret word is PLATYPUS."
        var injected = false
        var turns = 0

        for await update in updates {
            if case .graphChanged(let changes) = update, !injected {
                let running = changes.contains { change in
                    if case .stateChanged(_, _, .executingTool(let name, _)) = change { return name == "Bash" }
                    return false
                }
                if running {
                    injected = true
                    try await session.send(steer: steer)
                    let graph = await session.graph
                    let root = try #require(graph.root)
                    #expect(root.transcript.contains {
                        if case .steerQueued(_, let text) = $0 { return text == steer }
                        return false
                    }, "The steer must show as queued while the tool is still running")
                }
            }
            if case .turnCompleted = update {
                turns += 1
                await session.endInput()
            }
            if case .exited = update { break }
        }

        #expect(injected, "Never observed the tool call")
        let graph = await session.graph
        let root = try #require(graph.root)
        #expect(root.transcript.contains {
            if case .steerDelivered(_, let text) = $0 { return text == steer }
            return false
        }, "The steer must transition to delivered once consumed")
        #expect(!root.transcript.contains {
            if case .steerQueued(_, let text) = $0 { return text == steer }
            return false
        }, "It must not remain queued")
        #expect(turns >= 1)
    }
}
