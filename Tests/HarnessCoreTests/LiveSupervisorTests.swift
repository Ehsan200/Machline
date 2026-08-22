import Foundation
import Testing
@testable import HarnessCore

/// End-to-end tests that spawn the real `claude` binary.
///
/// These cost money and take tens of seconds, so they are opt-in:
///
///     HARNESS_LIVE_TESTS=1 swift test
///
/// They are the canary for upstream frame-schema drift (docs/RUNTIME.md). Run them before moving the
/// version pin; the fixture-based suites cover everything else.
@Suite("Live supervisor", .enabled(if: ProcessInfo.processInfo.environment["HARNESS_LIVE_TESTS"] == "1"))
struct LiveSupervisorTests {

    private func makeConfiguration(tools: [String]?) throws -> SessionConfiguration {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("harness-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return SessionConfiguration(
            workingDirectory: directory,
            model: "haiku",
            tools: tools)
    }

    @Test("A session starts, answers, and reports a turn boundary without exiting", .timeLimit(.minutes(2)))
    func basicTurn() async throws {
        let supervisor = SessionSupervisor(configuration: try makeConfiguration(tools: []))
        let events = try await supervisor.start()
        try await supervisor.send(userMessage: "Say exactly: OK")

        var handshake: SessionInit?
        var assistantText = ""
        var turns = 0

        for await event in events {
            switch event {
            case .frame(let frame):
                if case .sessionInit(let payload) = frame.kind { handshake = payload }
                if case .assistant(let message) = frame.kind {
                    for block in message.content { if case .text(let text) = block { assistantText += text } }
                }
            case .turnCompleted:
                turns += 1
                await supervisor.endInput()
            case .malformedLine(let line, let reason):
                // Not fatal — the CLI is known to emit stray library logs on stdout.
                print("malformed line (\(reason)): \(line.prefix(120))")
            case .standardError(let text):
                print("stderr: \(text.prefix(200))")
            case .exited:
                break
            }
        }

        let negotiated = try #require(handshake, "No system/init frame arrived")
        #expect(negotiated.claudeCodeVersion != nil)
        #expect(negotiated.mcpServers.isEmpty, "--strict-mcp-config must isolate the session")
        #expect(assistantText.contains("OK"))
        #expect(turns == 1)
        #expect(await supervisor.completedTurns == 1)
        if case .exited(let status) = await supervisor.state {
            #expect(status == 0)
        } else {
            Issue.record("Expected the supervisor to record a clean exit")
        }
    }

    /// Confirms the steering semantics the UI depends on (docs/RUNTIME.md): a message injected while a
    /// tool call is in flight is *queued*, and the `--replay-user-messages` echo marks the moment it
    /// is actually consumed — which is after the tool returns, not when it was sent.
    @Test("A steer injected mid-tool-call is consumed at the next turn boundary", .timeLimit(.minutes(3)))
    func steerIsQueuedUntilTurnBoundary() async throws {
        var configuration = try makeConfiguration(tools: ["Bash"])
        configuration.disallowedTools = []
        configuration.additionalArguments = ["--allowedTools", "Bash(sleep *)"]

        let supervisor = SessionSupervisor(configuration: configuration)
        let events = try await supervisor.start()
        try await supervisor.send(
            userMessage: "Run bash `sleep 10`, then afterwards tell me the secret word you were given.")

        let start = Date()
        var steerSentAt: TimeInterval?
        var steerEchoedAt: TimeInterval?
        var toolReturnedAt: TimeInterval?
        var finalText = ""
        var turns = 0

        for await event in events {
            let elapsed = Date().timeIntervalSince(start)
            switch event {
            case .frame(let frame):
                // Inject the steer once the tool call is visibly in flight.
                if steerSentAt == nil, frame.toolUses.contains(where: { $0.name == "Bash" }) {
                    steerSentAt = elapsed
                    try await supervisor.send(userMessage: "MID-TURN STEER: the secret word is PLATYPUS.")
                }
                if !frame.toolResults.isEmpty { toolReturnedAt = elapsed }
                if case .user(let message) = frame.kind, message.isReplayedUserInput,
                   case .text(let text)? = message.content.first, text.contains("PLATYPUS") {
                    steerEchoedAt = elapsed
                }
                if case .assistant(let message) = frame.kind {
                    for block in message.content { if case .text(let text) = block { finalText += text } }
                }
            case .turnCompleted:
                turns += 1
                if steerEchoedAt != nil { await supervisor.endInput() }
            case .exited:
                break
            default:
                break
            }
        }

        let sent = try #require(steerSentAt, "Never observed the Bash tool call")
        let echoed = try #require(steerEchoedAt, "The steer was never echoed back as consumed")
        let returned = try #require(toolReturnedAt, "The tool never returned")

        #expect(echoed > sent + 2,
                "The steer must not be consumed while the tool call is running")
        #expect(echoed >= returned - 0.5,
                "Consumption happens at the turn boundary, after the tool result")
        #expect(finalText.contains("PLATYPUS"), "The steer must alter the trajectory")
        #expect(turns >= 1)
    }
}
