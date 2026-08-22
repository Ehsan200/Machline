import Foundation
import Testing
@testable import HarnessCore

@Suite("Subagent hierarchy and turn boundaries")
struct SubagentTests {

    /// **The turn-boundary invariant.** A `result` frame ends a *turn*, not the session. This
    /// transcript contains two, because a background subagent finished after its parent's turn had
    /// already ended. A supervisor that tears down on the first `result` truncates the session.
    @Test("A single run emits multiple result frames")
    func resultIsATurnBoundaryNotEOF() throws {
        let results = try Fixture.subagent.frames().compactMap { frame -> TurnResult? in
            guard case .result(let result) = frame.kind else { return nil }
            return result
        }
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.subtype == "success" })
        #expect(results.allSatisfy { $0.terminalReason == "completed" })
    }

    /// The tree edge: `task_started.tool_use_id` matches the parent's `tool_use` block id, and the
    /// subagent's own frames carry that same id as `parent_tool_use_id`.
    @Test("Subagent frames link to the parent tool_use that spawned them")
    func subagentTreeEdge() throws {
        let frames = try Fixture.subagent.frames()

        let launch = try #require(frames.flatMap(\.toolUses).first { $0.isSubagentLaunch })
        #expect(launch.name == "Agent", "The Task tool emits blocks named Agent")

        let started = try #require(frames.compactMap { frame -> TaskStarted? in
            guard case .taskStarted(let payload) = frame.kind else { return nil }
            return payload
        }.first)
        #expect(started.toolUseID == launch.id, "task_started must point at the launching block")
        #expect(started.subagentType == "echoer")
        #expect(started.prompt == "say hi")

        let childFrames = frames.filter { $0.parentToolUseID == launch.id }
        #expect(!childFrames.isEmpty, "Subagent output must be attributable to its parent")
        #expect(frames.filter { $0.parentToolUseID == nil }.count > childFrames.count)
    }

    @Test("Task lifecycle frames carry status and per-subagent telemetry")
    func taskLifecycle() throws {
        let frames = try Fixture.subagent.frames()

        let updated = try #require(frames.compactMap { frame -> TaskUpdated? in
            guard case .taskUpdated(let payload) = frame.kind else { return nil }
            return payload
        }.first)
        #expect(updated.status == "completed")
        #expect(updated.endTime != nil)

        let notification = try #require(frames.compactMap { frame -> TaskNotification? in
            guard case .taskNotification(let payload) = frame.kind else { return nil }
            return payload
        }.first)
        #expect(notification.status == "completed")
        #expect(notification.summary == "HI")
        #expect(notification.totalTokens == 666, "Per-subagent cost accounting arrives for free")
        #expect(notification.durationMS != nil)
        #expect(notification.taskID == updated.taskID)

        let snapshots = frames.compactMap { frame -> [BackgroundTask]? in
            guard case .backgroundTasksChanged(let tasks) = frame.kind else { return nil }
            return tasks
        }
        #expect(snapshots.count == 2, "One snapshot on spawn, one on drain")
        #expect(snapshots.first?.count == 1)
        #expect(snapshots.last?.isEmpty == true)
    }

    /// The sidecar hands us stdout and stderr already separated, so the terminal buffer can style
    /// them differently without parsing concatenated output.
    @Test("Bash results arrive with stdout and stderr pre-separated")
    func toolUseResultSidecar() throws {
        let frames = try Fixture.bashToolCall.frames()
        let sidecar = try #require(frames.compactMap { frame -> ToolUseResultSidecar? in
            guard case .user(let message) = frame.kind else { return nil }
            return message.toolUseResult
        }.first)
        guard case .process(let output) = sidecar else {
            Issue.record("Expected a structured process result, got \(sidecar)")
            return
        }
        #expect(output.stdout == "hello-from-tool")
        #expect(output.stderr.isEmpty)
        #expect(!output.interrupted)
    }

    /// The same field is a bare string when a hook denies, which is why the sidecar is an enum.
    @Test("The sidecar degrades to text for hook denials")
    func toolUseResultSidecarText() throws {
        let sidecar = try #require(try Fixture.hookDeny.frames().compactMap { frame -> ToolUseResultSidecar? in
            guard case .user(let message) = frame.kind else { return nil }
            return message.toolUseResult
        }.first)
        guard case .text(let text) = sidecar else {
            Issue.record("Expected a text sidecar, got \(sidecar)")
            return
        }
        #expect(text.contains("operator rejected"))
    }
}
