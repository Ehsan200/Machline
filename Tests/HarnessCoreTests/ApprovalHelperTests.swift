import Foundation
import Testing
@testable import HarnessCore

/// Spawns the real `harness-approve` binary. This is the component whose *only* obligation is to
/// print exactly one decision before the runtime's hook timeout fires, so it is tested as a process
/// rather than as a function.
@Suite("Approval hook helper")
struct ApprovalHelperTests {

    struct HelperRun: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        let duration: TimeInterval

        /// Parses the decision the runtime would have acted on.
        var decision: HookDecisionOutput.Payload? {
            guard let data = stdout.data(using: .utf8),
                  let output = try? JSONDecoder().decode(HookDecisionOutput.self, from: data)
            else { return nil }
            return output.hookSpecificOutput
        }
    }

    static var helperURL: URL {
        // The built products directory is the test bundle's parent.
        Bundle.module.bundleURL.deletingLastPathComponent().appendingPathComponent("harness-approve")
    }

    /// Spawns the helper and waits for it to finish.
    ///
    /// The wait blocks, and the broker on the other end answers from the cooperative pool, so the
    /// blocking part runs on a thread of its own — see `offCooperativePool`. Without that, several
    /// of these tests in parallel on a small CI runner hold every pool thread, the broker never
    /// gets scheduled, and the helper denies on its own deadline.
    static func runHelper(
        payload: String,
        socketPath: String?,
        deadlineSeconds: Double = 30
    ) async throws -> HelperRun {
        try await offCooperativePool {
            try runHelperBlocking(
                payload: payload, socketPath: socketPath, deadlineSeconds: deadlineSeconds)
        }
    }

    private static func runHelperBlocking(
        payload: String,
        socketPath: String?,
        deadlineSeconds: Double
    ) throws -> HelperRun {
        let process = Process()
        process.executableURL = helperURL
        var environment = ProcessInfo.processInfo.environment
        environment["HARNESS_APPROVAL_DEADLINE_SECONDS"] = String(deadlineSeconds)
        if let socketPath {
            environment["HARNESS_APPROVAL_SOCKET"] = socketPath
        } else {
            environment.removeValue(forKey: "HARNESS_APPROVAL_SOCKET")
        }
        process.environment = environment

        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let started = Date()
        try process.run()
        stdinPipe.fileHandleForWriting.write(Data(payload.utf8))
        try stdinPipe.fileHandleForWriting.close()

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return HelperRun(
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            exitCode: process.terminationStatus,
            duration: Date().timeIntervalSince(started))
    }

    static let samplePayload = #"""
    {"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"},"tool_use_id":"toolu_1","cwd":"/work","permission_mode":"default"}
    """#

    /// Every assertion below reduces to this: the helper printed a usable `deny`. A non-zero exit
    /// or an empty stdout would be read by the runtime as a hook that failed to decide, which is
    /// the fail-open path (Finding 1).
    private func expectDenial(_ run: HelperRun, sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(run.exitCode == 0, "Helper must exit 0 even when denying", sourceLocation: sourceLocation)
        let decision = try #require(run.decision, "Helper printed no parseable decision: \(run.stdout)")
        #expect(decision.permissionDecision == "deny", sourceLocation: sourceLocation)
        #expect(decision.hookEventName == "PreToolUse", sourceLocation: sourceLocation)
        #expect(!decision.permissionDecisionReason.isEmpty,
                "A denial must explain itself — the reason becomes the agent's tool result",
                sourceLocation: sourceLocation)
    }

    @Test("Denies when no approval socket is configured", .timeLimit(.minutes(1)))
    func deniesWithoutSocket() async throws {
        let run = try await Self.runHelper(payload: Self.samplePayload, socketPath: nil)
        try expectDenial(run)
        #expect(run.decision?.permissionDecisionReason.contains("no approval socket") == true)
    }

    /// The app crashing, or never having started, must not open the gate.
    @Test("Denies when the broker is not running", .timeLimit(.minutes(1)))
    func deniesWhenBrokerUnreachable() async throws {
        let run = try await Self.runHelper(
            payload: Self.samplePayload, socketPath: "/tmp/ah-nonexistent-\(UUID().uuidString.prefix(8)).sock")
        try expectDenial(run)
        #expect(run.decision?.permissionDecisionReason.contains("not running") == true)
    }

    @Test("Denies on an empty payload", .timeLimit(.minutes(1)))
    func deniesOnEmptyPayload() async throws {
        try expectDenial(try await Self.runHelper(payload: "", socketPath: "/tmp/whatever.sock"))
    }

    @Test("Denies on an unparseable payload", .timeLimit(.minutes(1)))
    func deniesOnGarbagePayload() async throws {
        try expectDenial(try await Self.runHelper(payload: "not json at all", socketPath: "/tmp/whatever.sock"))
    }

    @Test("Approves when the broker allows", .timeLimit(.minutes(1)))
    func allowsWhenBrokerAllows() async throws {
        var policy = PolicyStore()
        policy.add(.allowBashPrefix("echo"))
        let broker = ApprovalBroker(
            socketPath: ApprovalBrokerTests.temporarySocketPath(), policy: policy)
        _ = try await broker.start()
        defer { Task { await broker.stop() } }

        let run = try await Self.runHelper(payload: Self.samplePayload, socketPath: await broker.socketPath)
        #expect(run.exitCode == 0)
        #expect(run.decision?.permissionDecision == "allow")
    }

    @Test("Relays an operator rejection with its feedback intact", .timeLimit(.minutes(1)))
    func relaysOperatorRejection() async throws {
        let broker = ApprovalBroker(socketPath: ApprovalBrokerTests.temporarySocketPath())
        let events = try await broker.start()
        defer { Task { await broker.stop() } }

        let feedback = "Use the clean target instead."
        let resolving = Task {
            for await event in events {
                if case .pending(let pending) = event {
                    pending.deny(feedback: feedback)
                    return
                }
            }
        }
        defer { resolving.cancel() }

        let run = try await Self.runHelper(payload: Self.samplePayload, socketPath: await broker.socketPath)
        try expectDenial(run)
        #expect(run.decision?.permissionDecisionReason == feedback)
    }

    /// **The core mitigation for Finding 1.**
    ///
    /// The helper owns a deadline strictly inside the runtime's hook timeout. When nothing answers,
    /// *the helper* ends the wait with an explicit denial, rather than being cancelled by the
    /// runtime — whose cancellation path lets the command run.
    ///
    /// The peer here is a bare listener that accepts and then says nothing, so only the helper's
    /// own deadline can end it. (Against the real broker this path is unreachable, because the
    /// broker refuses to outlive the helper — see `brokerWillNotOutliveTheHelper`.)
    @Test("The helper denies on its own deadline against a silent peer", .timeLimit(.minutes(1)))
    func helperSelfDeniesOnDeadline() async throws {
        let listener = try UnixSocket.Listener(path: ApprovalBrokerTests.temporarySocketPath())
        defer { listener.close() }

        let accepting = Thread {
            // Accept, then deliberately never reply.
            while let descriptor = listener.accept() {
                Thread.sleep(forTimeInterval: 60)
                Darwin.close(descriptor)
            }
        }
        accepting.start()

        let run = try await Self.runHelper(
            payload: Self.samplePayload, socketPath: listener.path, deadlineSeconds: 3)

        try expectDenial(run)
        #expect(run.duration < 10, "The helper must end the wait at its own deadline, not later")
        #expect(run.duration >= 0.5, "It should actually have waited")
        #expect(run.decision?.permissionDecisionReason.contains("did not respond in time") == true,
                "Got: \(run.decision?.permissionDecisionReason ?? "-")")
    }

    /// The three deadlines nest: runtime hook timeout > helper deadline > broker deadline. If a
    /// helper arrives whose deadline is already too near for a round trip, the broker denies at
    /// once rather than starting a wait it cannot finish in time.
    @Test("The broker never outlives the helper's deadline", .timeLimit(.minutes(1)))
    func brokerWillNotOutliveTheHelper() async throws {
        let broker = ApprovalBroker(
            socketPath: ApprovalBrokerTests.temporarySocketPath(), operatorWait: 600)
        let events = try await broker.start()
        defer { Task { await broker.stop() } }

        let draining = Task { for await _ in events {} }
        defer { draining.cancel() }

        let started = Date()
        let decision = try await ApprovalBrokerTests.ask(
            socketPath: await broker.socketPath, command: "echo hi", helperDeadline: 3)

        #expect(decision.verdict == .deny)
        #expect(decision.provenance == .brokerTimeout)
        #expect(Date().timeIntervalSince(started) < 3,
                "The broker must give up before the helper's deadline, not at its own leisure")
    }

    /// A broker that accepts the connection and then dies mid-decision is the crash case.
    @Test("Denies when the broker vanishes mid-decision", .timeLimit(.minutes(1)))
    func deniesWhenBrokerDiesMidDecision() async throws {
        let broker = ApprovalBroker(
            socketPath: ApprovalBrokerTests.temporarySocketPath(), operatorWait: 600)
        let events = try await broker.start()

        let stopping = Task {
            for await event in events {
                if case .pending = event {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    await broker.stop()
                    return
                }
            }
        }
        defer { stopping.cancel() }

        let run = try await Self.runHelper(
            payload: Self.samplePayload, socketPath: await broker.socketPath, deadlineSeconds: 5)
        try expectDenial(run)
    }
}
