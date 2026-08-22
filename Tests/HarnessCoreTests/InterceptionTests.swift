import Foundation
import Testing
@testable import HarnessCore

/// Regression guards for the interception findings in docs/RUNTIME.md These encode *observed runtime
/// behaviour*, including behaviour we consider unsafe — if a CLI upgrade changes any of them, these
/// tests fail and the security design must be revisited before the version pin moves.
@Suite("Command interception behaviour")
struct InterceptionTests {

    @Test("A hook denial becomes the agent's tool result, verbatim and flagged as an error")
    func hookDenialFeedsBackToAgent() throws {
        let frames = try Fixture.hookDeny.frames()

        let response = try #require(frames.compactMap { frame -> HookResponse? in
            guard case .hookResponse(let response) = frame.kind else { return nil }
            return response
        }.first)
        #expect(response.outcome == "success")
        #expect(response.hookEvent == "PreToolUse")
        #expect(!response.indicatesFailOpen)

        let result = try #require(frames.flatMap(\.toolResults).first)
        #expect(result.isError, "A denial must reach the agent as an error")
        #expect(result.text.contains("operator rejected"))

        let denials = try #require(frames.compactMap { frame -> TurnResult? in
            guard case .result(let result) = frame.kind else { return nil }
            return result
        }.first).permissionDenials
        #expect(denials.count == 1)
        #expect(denials.first?.toolName == "Bash")
    }

    /// **FINDING 1 — the runtime's hook timeout fails OPEN.**
    ///
    /// This fixture captures a `PreToolUse` hook that outlived its 5-second timeout. The runtime
    /// cancelled it and ran the command anyway: the tool result is a *success* carrying real
    /// output, and `permission_denials` is empty. This is why the helper must enforce its own
    /// deadline strictly below the runtime's and print an explicit `deny` itself — the runtime's
    /// cancellation path must never be what ends the wait.
    @Test("Known-unsafe: a timed-out hook lets the command execute")
    func hookTimeoutFailsOpen() throws {
        let frames = try Fixture.hookTimeoutFailOpen.frames()

        let response = try #require(frames.compactMap { frame -> HookResponse? in
            guard case .hookResponse(let response) = frame.kind else { return nil }
            return response
        }.first)
        #expect(response.outcome == "cancelled")
        #expect(response.exitCode == 1)
        #expect(response.indicatesFailOpen, "This is the signal the app must surface loudly")

        let result = try #require(frames.flatMap(\.toolResults).first)
        #expect(!result.isError, "Documents the unsafe behaviour: the command ran")
        #expect(result.text.contains("timeout-test"), "Real command output came back")

        let turn = try #require(frames.compactMap { frame -> TurnResult? in
            guard case .result(let result) = frame.kind else { return nil }
            return result
        }.first)
        #expect(turn.permissionDenials.isEmpty, "The bypass is not even recorded as a denial")
    }

    /// A hook that takes 20 s under a 600 s timeout completes normally — the basis for the
    /// helper-owns-its-deadline design. Long human deliberation is viable.
    @Test("A long but in-budget hook wait resolves cleanly")
    func longHookWaitSucceeds() throws {
        let frames = try Fixture.hookLongWaitDeny.frames()
        let response = try #require(frames.compactMap { frame -> HookResponse? in
            guard case .hookResponse(let response) = frame.kind else { return nil }
            return response
        }.first)
        #expect(response.outcome == "success")
        #expect(!response.indicatesFailOpen)

        let result = try #require(frames.flatMap(\.toolResults).first)
        #expect(result.isError)
        #expect(result.text.contains("operator denied"))
    }

    @Test("Bash tool calls expose their command string for the approval sheet")
    func bashCommandIsExtractable() throws {
        let frames = try Fixture.bashToolCall.frames()
        let use = try #require(frames.flatMap(\.toolUses).first)
        #expect(use.name == "Bash")
        #expect(use.bashCommand == "echo hello-from-tool")
        #expect(use.callerType == "direct")
        #expect(!use.id.isEmpty, "tool_use id ties the approval sheet to the tree node")
    }
}
