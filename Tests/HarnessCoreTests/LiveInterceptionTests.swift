import Foundation
import Testing
@testable import HarnessCore

/// End-to-end interception against the real `claude` binary, the real hook helper, and a real
/// broker. Opt-in:
///
///     HARNESS_LIVE_TESTS=1 swift test
///
/// This is the suite that matters most. `probes/p5.jsonl` captured the runtime letting a command
/// execute when a hook outlived its timeout; these tests assert that with our helper in front of
/// it, the same situation ends in a denial instead.
@Suite("Live command interception",
       .enabled(if: ProcessInfo.processInfo.environment["HARNESS_LIVE_TESTS"] == "1"),
       .serialized)
struct LiveInterceptionTests {

    struct Harness {
        let supervisor: SessionSupervisor
        let broker: ApprovalBroker
        let events: AsyncStream<SupervisorEvent>
        let approvals: AsyncStream<ApprovalEvent>
        let workspace: URL
    }

    /// `runtimeTimeout` is kept small so the runtime's fail-open cancellation is a live threat
    /// within the test's own time budget; the helper deadline sits inside it.
    static func makeHarness(
        runtimeTimeout: Int = 60,
        helperDeadline: Int = 6,
        operatorWait: TimeInterval = 600,
        policy: PolicyStore = PolicyStore()
    ) async throws -> Harness {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("harness-live-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let socketPath = ApprovalBrokerTests.temporarySocketPath()
        let broker = ApprovalBroker(socketPath: socketPath, policy: policy, operatorWait: operatorWait)
        let approvals = try await broker.start()

        let installer = try ApprovalHookInstaller(
            helperPath: ApprovalHelperTests.helperURL.path,
            socketPath: socketPath,
            runtimeTimeout: runtimeTimeout,
            helperDeadline: helperDeadline,
            matchers: ["Bash"])
        let settingsURL = workspace.appendingPathComponent("settings.json")
        try installer.writeSettings(to: settingsURL)

        var configuration = SessionConfiguration(
            workingDirectory: workspace,
            model: "haiku",
            tools: ["Bash"],
            settingsPath: settingsURL,
            additionalEnvironment: installer.environment)
        // Clear the static denylist so the hook is unambiguously the thing under test.
        configuration.disallowedTools = []
        configuration.additionalArguments = ["--allowedTools", "Bash(echo *)"]

        let supervisor = SessionSupervisor(configuration: configuration)
        let events = try await supervisor.start()
        return Harness(
            supervisor: supervisor, broker: broker,
            events: events, approvals: approvals, workspace: workspace)
    }

    struct Observed {
        var toolResults: [ToolResult] = []
        var sidecars: [ToolUseResultSidecar] = []
        var hookResponses: [HookResponse] = []
        var denials: [PermissionDenial] = []
        var turns = 0
    }

    /// Runs one prompt to its turn boundary, collecting what the agent actually observed.
    static func run(_ harness: Harness, prompt: String) async throws -> Observed {
        try await harness.supervisor.send(userMessage: prompt)
        var observed = Observed()
        for await event in harness.events {
            switch event {
            case .frame(let frame):
                observed.toolResults += frame.toolResults
                if case .user(let message) = frame.kind, let sidecar = message.toolUseResult {
                    observed.sidecars.append(sidecar)
                }
                if case .hookResponse(let response) = frame.kind {
                    observed.hookResponses.append(response)
                }
            case .turnCompleted(let result):
                observed.turns += 1
                observed.denials += result.permissionDenials
                await harness.supervisor.endInput()
            case .exited:
                break
            default:
                break
            }
        }
        await harness.broker.stop()
        return observed
    }

    /// **The regression test for Finding 1.**
    ///
    /// No operator ever answers. In `probes/p5.jsonl` — the same situation without our helper — the
    /// runtime cancelled the hook and ran the command, returning real output with `is_error: false`
    /// and recording no denial. With the helper owning a deadline inside the runtime's, the command
    /// must instead be blocked.
    @Test("An unanswered approval blocks the command instead of executing it", .timeLimit(.minutes(3)))
    func unansweredApprovalBlocksExecution() async throws {
        let harness = try await Self.makeHarness(helperDeadline: 6)

        // Deliberately never resolve anything.
        let ignoring = Task { for await _ in harness.approvals {} }
        defer { ignoring.cancel() }

        let observed = try await Self.run(
            harness, prompt: "Run the bash command: echo intercepted-marker")

        let result = try #require(observed.toolResults.first, "The agent never attempted the tool")
        #expect(result.isError, "An unanswered approval must reach the agent as an error")
        #expect(!result.text.contains("intercepted-marker"),
                "The command must not have executed. Got: \(result.text)")
        #expect(result.text.contains("AgentHarness"), "The denial should identify its source")
        #expect(observed.denials.count == 1, "The block must be recorded for audit")

        let response = try #require(observed.hookResponses.first)
        #expect(response.outcome == "success",
                "The helper must answer, not be cancelled by the runtime")
        #expect(!response.indicatesFailOpen)
    }

    @Test("An operator rejection reaches the agent as re-plannable feedback", .timeLimit(.minutes(3)))
    func operatorRejectionFeedsBack() async throws {
        let harness = try await Self.makeHarness(helperDeadline: 30)

        let feedback = "Do not echo that marker; echo the word REPLANNED instead."
        let resolving = Task {
            for await event in harness.approvals {
                if case .pending(let pending) = event { pending.deny(feedback: feedback) }
            }
        }
        defer { resolving.cancel() }

        let observed = try await Self.run(
            harness, prompt: "Run the bash command: echo intercepted-marker")

        let result = try #require(observed.toolResults.first)
        #expect(result.isError)
        #expect(result.text == feedback, "Feedback must arrive verbatim so the agent can re-plan")
        #expect(observed.denials.count >= 1)
    }

    @Test("An approved command executes and its output returns", .timeLimit(.minutes(3)))
    func approvedCommandExecutes() async throws {
        let harness = try await Self.makeHarness(helperDeadline: 30)

        let resolving = Task {
            for await event in harness.approvals {
                if case .pending(let pending) = event {
                    #expect(pending.payload.bashCommand?.contains("approved-marker") == true)
                    pending.approveOnce()
                }
            }
        }
        defer { resolving.cancel() }

        let observed = try await Self.run(
            harness, prompt: "Run the bash command: echo approved-marker")

        let result = try #require(observed.toolResults.first)
        #expect(!result.isError, "An approved command should succeed. Got: \(result.text)")
        #expect(result.text.contains("approved-marker"))
        #expect(observed.denials.isEmpty)

        guard case .process(let output)? = observed.sidecars.first else {
            Issue.record("Expected a structured process sidecar")
            return
        }
        #expect(output.stdout.contains("approved-marker"))
    }

    /// An allowlist rule resolves without ever raising a sheet, so routine commands do not train
    /// operators to click through prompts.
    @Test("An allowlisted command runs without raising a sheet", .timeLimit(.minutes(3)))
    func allowlistedCommandSkipsTheSheet() async throws {
        var policy = PolicyStore()
        policy.add(.allowBashPrefix("echo"))
        let harness = try await Self.makeHarness(helperDeadline: 30, policy: policy)

        let sawSheet = LockedFlag()
        let watching = Task {
            for await event in harness.approvals {
                if case .pending = event { sawSheet.set() }
            }
        }
        defer { watching.cancel() }

        let observed = try await Self.run(
            harness, prompt: "Run the bash command: echo allowlisted-marker")

        let result = try #require(observed.toolResults.first)
        #expect(!result.isError)
        #expect(result.text.contains("allowlisted-marker"))
        #expect(!sawSheet.value, "An allowlisted command must not prompt the operator")
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}
