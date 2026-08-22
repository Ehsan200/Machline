import Darwin
import Foundation

/// A request awaiting an operator decision.
///
/// Resolution is one-shot and idempotent: whichever arrives first — the operator, the broker's
/// deadline, or a session shutdown — wins, and later attempts are ignored. That property is what
/// makes the timeout race safe.
public final class PendingApproval: @unchecked Sendable {
    public let request: ApprovalRequest
    public let assessment: RiskClassifier.Assessment
    /// When the broker will give up and deny on its own.
    public let deadline: Date

    private let lock = NSLock()
    private var continuation: CheckedContinuation<ApprovalDecision, Never>?
    private var decision: ApprovalDecision?

    init(request: ApprovalRequest, assessment: RiskClassifier.Assessment, deadline: Date) {
        self.request = request
        self.assessment = assessment
        self.deadline = deadline
    }

    public var payload: HookPayload { request.payload }
    public var isResolved: Bool {
        lock.lock(); defer { lock.unlock() }
        return decision != nil
    }

    public func resolve(_ decision: ApprovalDecision) {
        lock.lock()
        guard self.decision == nil else { lock.unlock(); return }
        self.decision = decision
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: decision)
    }

    public func approveOnce() {
        resolve(ApprovalDecision(
            verdict: .allow, reason: "Approved by operator.", provenance: .operatorDecision))
    }

    /// Rejects with feedback the agent will receive as its tool result, so it can re-plan.
    public func deny(feedback: String) {
        resolve(ApprovalDecision(
            verdict: .deny, reason: feedback, provenance: .operatorDecision))
    }

    func attach(_ continuation: CheckedContinuation<ApprovalDecision, Never>) {
        lock.lock()
        if let decision {
            lock.unlock()
            continuation.resume(returning: decision)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }
}

/// Everything the broker surfaces, for UI and for the audit log.
public enum ApprovalEvent: Sendable {
    /// Needs an operator. The app must eventually call `resolve` — but if it never does, the
    /// broker's deadline denies on its behalf.
    case pending(PendingApproval)
    /// Every decision, including auto-resolved ones. This is the audit stream.
    case resolved(ApprovalRequest, ApprovalDecision)
    /// A connection-level problem. The corresponding request, if any, was already denied.
    case failure(String)
}

/// Serves approval requests from hook helpers over a Unix domain socket.
///
/// The design exists because of Finding 1: the runtime's own hook timeout **fails open**,
/// executing the command. So this broker, and the helper in front of it, are built on one rule —
/// *every* path terminates in an explicit decision, and every unusual path terminates in `deny`.
public actor ApprovalBroker {

    /// How long an operator gets before the broker denies on their behalf.
    ///
    /// This must stay comfortably below the helper's own deadline, which in turn stays below the
    /// runtime's hook timeout. Three nested deadlines, innermost first, so the runtime's fail-open
    /// cancellation is never the thing that ends the wait.
    public static let defaultOperatorWait: TimeInterval = 480
    /// Slack left between the broker's deadline and the helper's, to cover the reply's round trip.
    public static let helperDeadlineMargin: TimeInterval = 15
    /// A helper that connects but never sends a payload.
    public static let requestReadTimeout: TimeInterval = 10

    public private(set) var policy: PolicyStore
    /// Which calls are answered without the operator. Convenience only — see `AutoApproval`.
    public private(set) var autoApproval: AutoApproval
    public let socketPath: String

    private let classifier: RiskClassifier
    private let operatorWait: TimeInterval
    private var listener: UnixSocket.Listener?
    private var continuation: AsyncStream<ApprovalEvent>.Continuation?
    private var isRunning = false

    public init(
        socketPath: String,
        policy: PolicyStore = PolicyStore(),
        autoApproval: AutoApproval = .manual,
        classifier: RiskClassifier = RiskClassifier(),
        operatorWait: TimeInterval = ApprovalBroker.defaultOperatorWait
    ) {
        self.socketPath = socketPath
        self.policy = policy
        self.autoApproval = autoApproval
        self.classifier = classifier
        self.operatorWait = operatorWait
    }

    // MARK: - Policy

    public func add(rule: ApprovalRule) { policy.add(rule) }
    public func remove(ruleID: UUID) { policy.remove(id: ruleID) }
    public func replacePolicy(_ policy: PolicyStore) { self.policy = policy }

    /// Changes what is answered automatically. Takes effect on the next request; requests already
    /// waiting on an operator keep waiting.
    public func setAutoApproval(_ autoApproval: AutoApproval) { self.autoApproval = autoApproval }

    // MARK: - Lifecycle

    public func start() throws -> AsyncStream<ApprovalEvent> {
        guard !isRunning else { throw UnixSocket.Error.bindFailed(errno: EADDRINUSE) }

        let listener = try UnixSocket.Listener(path: socketPath)
        self.listener = listener
        isRunning = true

        let (stream, continuation) = AsyncStream<ApprovalEvent>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation

        // `accept` blocks, so it gets its own thread rather than a cooperative-pool slot.
        let thread = Thread { [weak self] in
            while let descriptor = listener.accept() {
                guard let self else {
                    Darwin.close(descriptor)
                    continue
                }
                Task { await self.handle(descriptor: descriptor) }
            }
        }
        thread.name = "AgentHarness.ApprovalBroker"
        thread.start()

        return stream
    }

    public func stop() {
        isRunning = false
        listener?.close()
        listener = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Connection handling

    private func handle(descriptor: Int32) async {
        defer { Darwin.close(descriptor) }

        let request: ApprovalRequest
        do {
            // Off the cooperative pool: this read waits on a helper that may take its time, and
            // the pool thread it would otherwise hold is one the broker's own tasks need.
            let readDeadline = Date().addingTimeInterval(Self.requestReadTimeout)
            let line = try await UnixSocket.blocking {
                try UnixSocket.readLine(descriptor: descriptor, deadline: readDeadline)
            }
            request = try ApprovalRequest.decode(from: line)
        } catch {
            // We cannot identify what was being asked, so we certainly cannot allow it.
            let decision = ApprovalDecision.failClosed(
                .malformedPayload, detail: "the approval request could not be read")
            await respond(descriptor: descriptor, decision: decision)
            continuation?.yield(.failure("Unreadable approval request: \(error)"))
            return
        }

        let decision = await decide(request: request)
        await respond(descriptor: descriptor, decision: decision)
        continuation?.yield(.resolved(request, decision))
    }

    private func decide(request: ApprovalRequest) async -> ApprovalDecision {
        // Explicit rules are evaluated first, so a deny rule still beats auto-approval.
        if let match = policy.evaluate(payload: request.payload) {
            return match.decision
        }

        let assessment = classifier.assess(payload: request.payload)
        if let decision = autoApproval.decision(for: request.payload, assessment: assessment) {
            return decision
        }

        // Deadline: never outlive the helper's own, which never outlives the runtime's.
        let ceiling = request.helperDeadline.addingTimeInterval(-Self.helperDeadlineMargin)
        let deadline = min(Date().addingTimeInterval(operatorWait), ceiling)

        let pending = PendingApproval(
            request: request,
            assessment: assessment,
            deadline: deadline)

        guard let continuation else {
            return .failClosed(.internalError, detail: "the approval broker is not accepting requests")
        }
        continuation.yield(.pending(pending))

        let timeout = Task {
            let interval = deadline.timeIntervalSinceNow
            if interval > 0 {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            pending.resolve(.failClosed(
                .brokerTimeout, detail: "no operator responded before the approval deadline"))
        }
        defer { timeout.cancel() }

        return await withCheckedContinuation { continuation in
            pending.attach(continuation)
        }
    }

    private func respond(descriptor: Int32, decision: ApprovalDecision) async {
        // Encoding our own decision failing is not a reason to send nothing: silence is what the
        // runtime reads as a hook that never decided, and that path executes the command.
        let line = (try? decision.encoded())
            ?? #"{"verdict":"deny","reason":"AgentHarness could not encode a decision and denied by default.","provenance":"internalError"}"#
        try? await UnixSocket.blocking {
            try UnixSocket.writeLine(descriptor: descriptor, message: line)
        }
    }
}

// MARK: - Socket paths

extension ApprovalBroker {
    /// Builds a per-session socket path, validating it against the `sun_path` limit.
    ///
    /// The limit is 103 bytes, and Application Support paths plus a UUID sit close to it, so this
    /// fails loudly at setup rather than at the first approval.
    public static func socketPath(forSession session: UUID, in directory: URL) throws -> String {
        let path = directory
            .appendingPathComponent("\(session.uuidString.lowercased()).sock")
            .path
        guard path.utf8.count <= UnixSocket.maximumPathLength else {
            throw UnixSocket.Error.pathTooLong(path: path, limit: UnixSocket.maximumPathLength)
        }
        return path
    }

    /// `~/Library/Application Support/AgentHarness/run`, created if needed.
    public static func defaultRunDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("AgentHarness/run", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return directory
    }
}
