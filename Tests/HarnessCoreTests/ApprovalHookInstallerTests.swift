import Foundation
import Testing
@testable import HarnessCore

@Suite("Approval hook installation")
struct ApprovalHookInstallerTests {

    private func makeInstaller(
        runtimeTimeout: Int = 600, helperDeadline: Int = 540
    ) throws -> ApprovalHookInstaller {
        try ApprovalHookInstaller(
            helperPath: ApprovalHelperTests.helperURL.path,
            socketPath: "/tmp/ah-test.sock",
            runtimeTimeout: runtimeTimeout,
            helperDeadline: helperDeadline)
    }

    /// The ordering that makes the whole gate sound: the helper must always end the wait before the
    /// runtime can cancel it. An inverted configuration is refused rather than silently accepted.
    @Test("Deadlines must nest inside the runtime timeout")
    func deadlineNestingIsEnforced() throws {
        #expect(throws: Never.self) { try makeInstaller(runtimeTimeout: 600, helperDeadline: 540) }
        #expect(throws: ApprovalHookInstaller.ConfigurationError.self) {
            try makeInstaller(runtimeTimeout: 60, helperDeadline: 60)
        }
        #expect(throws: ApprovalHookInstaller.ConfigurationError.self) {
            try makeInstaller(runtimeTimeout: 60, helperDeadline: 120)
        }
        // Too little margin to write a verdict and exit.
        #expect(throws: ApprovalHookInstaller.ConfigurationError.self) {
            try makeInstaller(runtimeTimeout: 60, helperDeadline: 59)
        }
    }

    /// A helper that cannot launch is precisely the fail-open case — the runtime times it out and
    /// proceeds — so a session that cannot be gated must refuse to start.
    @Test("A missing or non-executable helper is refused")
    func missingHelperIsRefused() {
        #expect(throws: ApprovalHookInstaller.ConfigurationError.self) {
            try ApprovalHookInstaller(
                helperPath: "/nonexistent/harness-approve", socketPath: "/tmp/ah-test.sock")
        }
    }

    @Test("Generated settings register the helper for every gated tool")
    func settingsShape() throws {
        let installer = try makeInstaller()
        let json = try installer.settingsJSON()
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))

        let hooks = try #require(value.value(at: "hooks", "PreToolUse")?.arrayValue)
        #expect(hooks.count == ApprovalHookInstaller.defaultMatchers.count)

        let matchers = hooks.compactMap { $0["matcher"]?.stringValue }
        #expect(Set(matchers) == Set(ApprovalHookInstaller.defaultMatchers))

        let first = try #require(hooks.first?.value(at: "hooks")?.arrayValue?.first)
        #expect(first["type"]?.stringValue == "command")
        #expect(first["command"]?.stringValue == ApprovalHelperTests.helperURL.path)
        #expect(first["timeout"]?.intValue == 600)
    }

    @Test("The session environment carries the socket and deadline to the helper")
    func environmentWiring() throws {
        let environment = try makeInstaller(runtimeTimeout: 600, helperDeadline: 540).environment
        #expect(environment["HARNESS_APPROVAL_SOCKET"] == "/tmp/ah-test.sock")
        #expect(environment["HARNESS_APPROVAL_DEADLINE_SECONDS"] == "540")

        var configuration = SessionConfiguration(workingDirectory: URL(fileURLWithPath: "/tmp"))
        configuration.additionalEnvironment = environment
        let resolved = configuration.resolvedEnvironment()
        #expect(resolved["HARNESS_APPROVAL_SOCKET"] == "/tmp/ah-test.sock")
        #expect(resolved["PATH"] != nil, "Inherited environment must survive the merge")
    }
}
