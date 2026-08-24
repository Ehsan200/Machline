import Foundation
import Testing
@testable import HarnessCore

/// What "stop" has to mean.
///
/// Aborting one tool call used to send `SIGINT`, which stops the *process* — the frame stream ends
/// and the conversation is over because the operator wanted a command to stop. These pin the
/// difference against the real CLI, since only it can say whether the control request is honoured.
///
/// Opt-in via `HARNESS_LIVE_TESTS=1`.
@Suite("Live interrupt",
       .enabled(if: ProcessInfo.processInfo.environment["HARNESS_LIVE_TESTS"] == "1"),
       .serialized)
struct LiveInterruptTests {

    /// A turn long enough to be interrupted part-way through.
    private static let slowPrompt =
        "Run `sleep 25` with the Bash tool, then tell me it finished."

    @Test("Interrupting abandons the turn and leaves the session running")
    func interruptKeepsTheSessionAlive() async throws {
        var policy = PolicyStore()
        policy.add(.allowBashPrefix("sleep"))
        let (session, _) = try LiveSessionTests.makeSession(policy: policy)

        let updates = try await session.start()
        try await session.send(steer: Self.slowPrompt)

        var sawTurnEnd = false
        var sawExit = false
        var interrupted = false

        let watchdog = Task {
            try? await Task.sleep(for: .seconds(75))
            await session.stop()
        }
        defer { watchdog.cancel() }

        for await update in updates {
            // Interrupt once the turn is genuinely under way.
            if case .graphChanged = update, !interrupted {
                interrupted = true
                try? await Task.sleep(for: .seconds(6))
                await session.interrupt()
            }
            if case .turnCompleted = update { sawTurnEnd = true; break }
            if case .exited = update { sawExit = true; break }
        }

        #expect(interrupted, "the turn never started, so nothing was interrupted")
        // The distinction that matters: the turn ended, the process did not.
        #expect(sawTurnEnd || !sawExit, "interrupting ended the session instead of the turn")

        await session.stop()
    }

    /// The other half: a session that has been interrupted can still be spoken to. If the child is
    /// gone this write fails, which is exactly the regression being guarded.
    @Test("A session accepts another message after an interrupt")
    func sessionStillAcceptsInput() async throws {
        var policy = PolicyStore()
        policy.add(.allowBashPrefix("sleep"))
        let (session, _) = try LiveSessionTests.makeSession(policy: policy)

        let updates = try await session.start()
        try await session.send(steer: Self.slowPrompt)

        let drain = Task { for await _ in updates {} }
        defer { drain.cancel() }

        try await Task.sleep(for: .seconds(6))
        await session.interrupt()
        try await Task.sleep(for: .seconds(3))

        // Throws `notRunning` if the interrupt took the child with it.
        try await session.send(steer: "Say the word done.")

        await session.stop()
    }
}
