import Foundation

/// What the UI observes: a single ordered stream folding the runtime, the approval gate, and the
/// derived agent tree together.
public enum SessionUpdate: Sendable {
    case graphChanged([GraphChange])
    /// An approval needs an operator. Resolve it, or the broker's deadline denies on their behalf.
    case approvalPending(PendingApproval)
    /// Every approval outcome, including auto-resolved ones — the audit trail.
    case approvalResolved(ApprovalRequest, ApprovalDecision)
    /// A line on the frame stream that was not valid JSON. Non-fatal by design (docs/RUNTIME.md).
    case malformedLine(line: String, reason: String)
    case standardError(String)
    case turnCompleted(TurnResult)
    case exited(status: Int32)
    /// The approval channel failed. Because a dead broker plus an expired hook means silent
    /// execution, this is a degraded-mode signal the UI must show prominently (docs/RUNTIME.md).
    case approvalChannelFailure(String)
}

/// One gated agent session: the CLI child process, its approval broker, and the agent tree derived
/// from its frames.
///
/// Composition order matters. The broker is started and the hook installed **before** the child
/// process launches, so there is no window in which the agent can run a command while the gate is
/// still coming up.
public actor AgentSession {

    public private(set) var graph = AgentGraph()
    public private(set) var isRunning = false

    private let configuration: SessionConfiguration
    private let installer: ApprovalHookInstaller
    private let broker: ApprovalBroker
    private let supervisor: SessionSupervisor
    private var continuation: AsyncStream<SessionUpdate>.Continuation?
    private var pumps: [Task<Void, Never>] = []

    /// - Parameters:
    ///   - configuration: launch settings. Its `settingsPath` and approval environment are filled
    ///     in here; anything already set is overwritten.
    ///   - helperPath: the `harness-approve` binary. Must exist and be executable — a helper that
    ///     cannot launch is the fail-open case, so this is validated up front.
    public init(
        configuration: SessionConfiguration,
        helperPath: String,
        socketPath: String,
        settingsPath: URL,
        policy: PolicyStore = PolicyStore(),
        autoApproval: AutoApproval = .manual,
        runtimeHookTimeout: Int = 600,
        helperDeadline: Int = 540,
        operatorWait: TimeInterval = ApprovalBroker.defaultOperatorWait
    ) throws {
        installer = try ApprovalHookInstaller(
            helperPath: helperPath,
            socketPath: socketPath,
            runtimeTimeout: runtimeHookTimeout,
            helperDeadline: helperDeadline)
        try installer.writeSettings(to: settingsPath)

        var configuration = configuration
        configuration.settingsPath = settingsPath
        configuration.additionalEnvironment.merge(installer.environment) { _, new in new }
        self.configuration = configuration

        broker = ApprovalBroker(
            socketPath: socketPath, policy: policy, autoApproval: autoApproval,
            operatorWait: operatorWait)
        supervisor = SessionSupervisor(configuration: configuration)
    }

    // MARK: - Lifecycle

    public func start() async throws -> AsyncStream<SessionUpdate> {
        guard !isRunning else { throw SupervisorError.alreadyStarted }

        let (stream, continuation) = AsyncStream<SessionUpdate>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation

        // Gate first: no window where the agent can act before approvals are being served.
        let approvals = try await broker.start()
        let frames = try await supervisor.start()
        isRunning = true

        pumps.append(Task { [weak self] in
            for await event in approvals { await self?.handle(approval: event) }
        })
        pumps.append(Task { [weak self] in
            for await event in frames { await self?.handle(supervisor: event) }
            await self?.finish()
        })

        return stream
    }

    /// Injects a steer. Queued, not immediate — delivered at the next turn boundary (docs/RUNTIME.md).
    public func send(steer text: String) async throws {
        try await supervisor.send(userMessage: text)
        emit(.graphChanged(graph.noteSteerQueued(text: text)))
    }

    /// Sends `/clear` and empties the transcripts it resets.
    ///
    /// Both halves, in that order. The CLI owns the context the agent is carrying and this app
    /// owns what is on screen; clearing only one leaves the other lying about the conversation —
    /// a cleared screen over an agent that still remembers everything is the worse of the two.
    public func clear() async throws {
        try await supervisor.send(userMessage: "/clear")
        emit(.graphChanged(graph.clearTranscripts()))
    }

    /// Stops the agent's current work immediately. Distinct from steering.
    ///
    /// Whatever was queued behind the running turn dies with it — the CLI discards stdin it has not
    /// consumed and never echoes it — so the tree is told before the process is.
    public func interrupt() async {
        emit(.graphChanged(graph.noteInterrupted()))
        await supervisor.interrupt()
    }

    public func endInput() async {
        await supervisor.endInput()
    }

    public func stop() async {
        await supervisor.terminate()
        await broker.stop()
        emit(.graphChanged(graph.noteCancelled()))
    }

    // MARK: - Policy

    public func add(rule: ApprovalRule) async {
        await broker.add(rule: rule)
    }

    public func policy() async -> PolicyStore {
        await broker.policy
    }

    public func remove(ruleID: UUID) async {
        await broker.remove(ruleID: ruleID)
    }

    /// Changes what the broker answers without asking. Applies to the next request; anything
    /// already waiting on the operator keeps waiting.
    public func setAutoApproval(_ autoApproval: AutoApproval) async {
        await broker.setAutoApproval(autoApproval)
    }

    // MARK: - Event handling

    private func handle(supervisor event: SupervisorEvent) {
        switch event {
        case .frame(let frame):
            let changes = graph.apply(frame: frame)
            if !changes.isEmpty { emit(.graphChanged(changes)) }
        case .malformedLine(let line, let reason):
            emit(.malformedLine(line: line, reason: reason))
        case .standardError(let text):
            emit(.standardError(text))
        case .turnCompleted(let result):
            emit(.turnCompleted(result))
        case .exited(let status, _):
            emit(.graphChanged(graph.noteSessionExit(status: status)))
            emit(.exited(status: status))
        }
    }

    private func handle(approval event: ApprovalEvent) {
        switch event {
        case .pending(let pending):
            emit(.approvalPending(pending))
        case .resolved(let request, let decision):
            let changes = graph.noteApproval(
                toolUseID: request.payload.toolUseID, decision: decision)
            if !changes.isEmpty { emit(.graphChanged(changes)) }
            emit(.approvalResolved(request, decision))
        case .failure(let message):
            emit(.approvalChannelFailure(message))
        }
    }

    private func finish() async {
        isRunning = false
        await broker.stop()
        // The frame stream has ended, so the child is gone and its pipes are only descriptors this
        // process is sitting on. A tab keeps its session object for as long as it is open.
        await supervisor.releaseDescriptors()
        for pump in pumps { pump.cancel() }
        pumps.removeAll()
        continuation?.finish()
        continuation = nil
    }

    private func emit(_ update: SessionUpdate) {
        continuation?.yield(update)
    }
}

// MARK: - Convenience construction

extension AgentSession {
    /// Builds a session with app-managed socket and settings paths under a working directory.
    public static func make(
        workspace: URL,
        helperPath: String,
        runDirectory: URL,
        model: String? = nil,
        tools: [String]? = nil,
        policy: PolicyStore = PolicyStore(),
        sessionID: UUID = UUID()
    ) throws -> AgentSession {
        let configuration = SessionConfiguration(
            workingDirectory: workspace,
            sessionID: sessionID,
            model: model,
            tools: tools)
        return try AgentSession(
            configuration: configuration,
            helperPath: helperPath,
            socketPath: try ApprovalBroker.socketPath(forSession: sessionID, in: runDirectory),
            settingsPath: workspace.appendingPathComponent(".agentharness-settings.json"),
            policy: policy)
    }
}
