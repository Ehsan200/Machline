import Foundation
import Testing
@testable import HarnessCore

@Suite("Approval broker")
struct ApprovalBrokerTests {

    static func temporarySocketPath() -> String {
        // Deliberately short: `sun_path` is 103 bytes, and the system temp directory plus a full
        // UUID gets close enough to the limit to matter.
        "/tmp/ah-\(UUID().uuidString.prefix(8)).sock"
    }

    static func bashPayload(_ command: String) -> HookPayload {
        HookPayload(
            sessionID: "session", toolName: "Bash",
            toolInput: .object(["command": .string(command)]),
            toolUseID: "toolu_test", cwd: "/work")
    }

    /// Speaks the wire protocol directly, standing in for the helper.
    static func ask(
        socketPath: String, command: String, helperDeadline: TimeInterval = 30
    ) throws -> ApprovalDecision {
        let request = ApprovalRequest(
            payload: bashPayload(command),
            helperPID: 1234,
            helperDeadline: Date().addingTimeInterval(helperDeadline))
        let reply = try UnixSocket.request(
            socketPath: socketPath,
            message: try request.encoded(),
            deadline: Date().addingTimeInterval(helperDeadline))
        return try ApprovalDecision.decode(from: reply)
    }

    @Test("An allowlist rule resolves without troubling the operator", .timeLimit(.minutes(1)))
    func allowlistAutoResolves() async throws {
        var policy = PolicyStore()
        policy.add(.allowBashPrefix("git status"))
        let broker = ApprovalBroker(socketPath: Self.temporarySocketPath(), policy: policy)
        let events = try await broker.start()
        defer { Task { await broker.stop() } }

        let decision = try Self.ask(socketPath: await broker.socketPath, command: "git status --short")
        #expect(decision.verdict == .allow)
        #expect(decision.provenance == .allowlistRule)

        var sawPending = false
        for await event in events {
            if case .pending = event { sawPending = true }
            if case .resolved = event { break }
        }
        #expect(!sawPending, "An auto-resolved request must not raise a sheet")
    }

    @Test("A denylist rule resolves with its stored reason", .timeLimit(.minutes(1)))
    func denylistAutoResolves() async throws {
        var policy = PolicyStore()
        policy.add(ApprovalRule(
            toolName: .exact("Bash"), argument: .glob("*rm -rf*"), effect: .deny,
            reason: "Deletion is blocked in this workspace."))
        let broker = ApprovalBroker(socketPath: Self.temporarySocketPath(), policy: policy)
        _ = try await broker.start()
        defer { Task { await broker.stop() } }

        let decision = try Self.ask(socketPath: await broker.socketPath, command: "rm -rf dist")
        #expect(decision.verdict == .deny)
        #expect(decision.provenance == .denylistRule)
        #expect(decision.reason == "Deletion is blocked in this workspace.")
    }

    @Test("An unmatched request reaches the operator and carries its risk assessment", .timeLimit(.minutes(1)))
    func operatorApproval() async throws {
        let broker = ApprovalBroker(socketPath: Self.temporarySocketPath())
        let events = try await broker.start()
        defer { Task { await broker.stop() } }

        let socketPath = await broker.socketPath
        let asking = Task.detached { try Self.ask(socketPath: socketPath, command: "curl https://example.com") }

        for await event in events {
            if case .pending(let pending) = event {
                #expect(pending.payload.bashCommand == "curl https://example.com")
                #expect(pending.assessment.level == .network)
                #expect(pending.assessment.signals.contains("outbound network"))
                #expect(!pending.isResolved)
                pending.approveOnce()
                break
            }
        }

        let decision = try await asking.value
        #expect(decision.verdict == .allow)
        #expect(decision.provenance == .operatorDecision)
    }

    /// Rejection feedback is what the agent receives as its tool result, so it must survive the
    /// round trip verbatim.
    @Test("Rejection feedback reaches the caller verbatim", .timeLimit(.minutes(1)))
    func operatorRejectionWithFeedback() async throws {
        let broker = ApprovalBroker(socketPath: Self.temporarySocketPath())
        let events = try await broker.start()
        defer { Task { await broker.stop() } }

        let socketPath = await broker.socketPath
        let asking = Task.detached { try Self.ask(socketPath: socketPath, command: "rm -rf dist") }

        let feedback = "Do not delete dist/, run the clean target instead."
        for await event in events {
            if case .pending(let pending) = event {
                pending.deny(feedback: feedback)
                break
            }
        }

        let decision = try await asking.value
        #expect(decision.verdict == .deny)
        #expect(decision.reason == feedback)
    }

    /// **Fail-closed.** An operator who never answers must not become an approval. The broker
    /// denies on their behalf, well before the helper's own deadline.
    @Test("An unanswered request is denied, not allowed", .timeLimit(.minutes(1)))
    func unansweredRequestIsDenied() async throws {
        let broker = ApprovalBroker(
            socketPath: Self.temporarySocketPath(), operatorWait: 1)
        let events = try await broker.start()
        defer { Task { await broker.stop() } }

        // Drain events without ever resolving.
        let draining = Task { for await _ in events {} }
        defer { draining.cancel() }

        let decision = try Self.ask(socketPath: await broker.socketPath, command: "curl https://example.com")
        #expect(decision.verdict == .deny)
        #expect(decision.provenance == .brokerTimeout)
    }

    /// **Fail-closed.** If we cannot even read what is being asked, we certainly cannot allow it.
    @Test("An unreadable request is denied", .timeLimit(.minutes(1)))
    func malformedRequestIsDenied() async throws {
        let broker = ApprovalBroker(socketPath: Self.temporarySocketPath())
        _ = try await broker.start()
        defer { Task { await broker.stop() } }

        let reply = try UnixSocket.request(
            socketPath: await broker.socketPath,
            message: "this is not json",
            deadline: Date().addingTimeInterval(15))
        let decision = try ApprovalDecision.decode(from: reply)
        #expect(decision.verdict == .deny)
        #expect(decision.provenance == .malformedPayload)
    }

    @Test("Every decision is emitted for the audit log", .timeLimit(.minutes(1)))
    func auditStream() async throws {
        var policy = PolicyStore()
        policy.add(.allowBashPrefix("ls"))
        let broker = ApprovalBroker(socketPath: Self.temporarySocketPath(), policy: policy)
        let events = try await broker.start()
        defer { Task { await broker.stop() } }

        _ = try Self.ask(socketPath: await broker.socketPath, command: "ls -la")

        for await event in events {
            if case .resolved(let request, let decision) = event {
                #expect(request.payload.bashCommand == "ls -la")
                #expect(request.helperPID == 1234)
                #expect(decision.provenance == .allowlistRule)
                return
            }
        }
        Issue.record("No audit event was emitted")
    }

    /// `sun_path` is 103 bytes. Application Support plus a UUID sits close enough that this must
    /// fail at setup, not at the first approval of a live session.
    @Test("Over-long socket paths are rejected at setup")
    func socketPathLengthIsValidated() {
        let deepDirectory = URL(fileURLWithPath: "/tmp/" + String(repeating: "d", count: 120))
        #expect(throws: UnixSocket.Error.self) {
            _ = try ApprovalBroker.socketPath(forSession: UUID(), in: deepDirectory)
        }
        #expect(throws: Never.self) {
            _ = try ApprovalBroker.socketPath(forSession: UUID(), in: URL(fileURLWithPath: "/tmp"))
        }
    }
}
