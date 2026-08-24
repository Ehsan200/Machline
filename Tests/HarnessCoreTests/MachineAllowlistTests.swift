import Foundation
import Testing
@testable import HarnessCore

/// Honouring `permissions.allow` keeps this gate from being stricter than the CLI it wraps — an
/// operator who has already allowed a command on this machine should not be asked again just
/// because they ran it in this window.
///
/// It also decides what runs without anyone seeing it, which is why the deny side is pinned here
/// too: a machine `deny` has to keep beating an allow.
@Suite("Machine allowlist")
struct MachineAllowlistTests {

    private func configuration(
        allow: [String] = [], deny: [String] = []
    ) -> MachineConfiguration {
        MachineConfiguration(denyRules: deny, allowRules: allow, preToolUseHookCount: 0)
    }

    @Test("A prefix rule covers the command and its arguments")
    func prefixRule() {
        let rules = configuration(allow: ["Bash(git status:*)"])
        #expect(rules.allowsBashCommand("git status") == "Bash(git status:*)")
        #expect(rules.allowsBashCommand("git status --short") == "Bash(git status:*)")
    }

    /// The reason a prefix rule is not a substring match: `git statusx` is a different command, and
    /// so is anything that merely starts with the same letters.
    @Test("A prefix rule stops at a word boundary")
    func prefixRuleIsNotASubstring() {
        let rules = configuration(allow: ["Bash(ls:*)"])
        #expect(rules.allowsBashCommand("lsof -i") == nil)
        #expect(rules.allowsBashCommand("ls -la") != nil)
    }

    @Test("An exact rule covers only that command")
    func exactRule() {
        let rules = configuration(allow: ["Bash(npm test)"])
        #expect(rules.allowsBashCommand("npm test") != nil)
        #expect(rules.allowsBashCommand("npm test --watch") == nil)
    }

    @Test("A command nobody allowed is not allowed")
    func unlisted() {
        let rules = configuration(allow: ["Bash(ls:*)"])
        #expect(rules.allowsBashCommand("rm -rf /") == nil)
        #expect(configuration().allowsBashCommand("ls") == nil)
    }

    /// The rule that keeps this from widening anything: the runtime refuses a denied command
    /// whatever the gate says, so the gate must not wave it through either.
    @Test("A deny rule still matches a command that is also allowed")
    func denyBeatsAllow() {
        let rules = configuration(allow: ["Bash(git:*)"], deny: ["Bash(git push:*)"])
        #expect(rules.allowsBashCommand("git push origin main") != nil)
        #expect(rules.deniesBashCommand("git push origin main") != nil)
        // The broker consults both and lets the denial win; neither answer alone is the decision.
        #expect(rules.deniesBashCommand("git status") == nil)
    }

    @Test("Rules for other tools are ignored")
    func nonBashRules() {
        let rules = configuration(allow: ["Read(//tmp/**)", "mcp__stitch__*"])
        #expect(rules.allowsBashCommand("cat /tmp/x") == nil)
    }

    @Test("An empty command matches nothing")
    func emptyCommand() {
        let rules = configuration(allow: ["Bash(ls:*)"])
        #expect(rules.allowsBashCommand("   ") == nil)
    }

    @Test("Rules are read from the settings file the CLI itself uses")
    func readsFromSettings() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("settings-\(UUID().uuidString).json")
        try #"""
            {"permissions": {"allow": ["Bash(ls:*)"], "deny": ["Bash(rm:*)"]}}
            """#.write(to: url, atomically: true, encoding: .utf8)

        let rules = MachineConfiguration.read(from: url)
        #expect(rules.allowsBashCommand("ls -la") != nil)
        #expect(rules.deniesBashCommand("rm -rf x") != nil)
    }
}
