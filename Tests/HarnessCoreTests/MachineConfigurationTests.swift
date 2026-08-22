import Foundation
import Testing
@testable import HarnessCore

/// The machine's own rules are the one thing in the gate that can overrule the operator, so what
/// the app reports about them has to match what the runtime will actually do.
@Suite("Machine configuration")
struct MachineConfigurationTests {

    private func configuration(_ json: String) throws -> MachineConfiguration {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return MachineConfiguration.parse(value)
    }

    @Test("Permission rules and hooks are read from the settings file")
    func readsRulesAndHooks() throws {
        let configuration = try configuration("""
        {
          "permissions": {
            "allow": ["Bash(ls:*)"],
            "deny": ["Bash(git push:*)", "Bash(npm publish:*)"]
          },
          "hooks": {
            "PreToolUse": [
              {"matcher": "Bash", "hooks": [{"type": "command", "command": "rtk hook claude"}]}
            ]
          }
        }
        """)

        #expect(configuration.allowRules == ["Bash(ls:*)"])
        #expect(configuration.denyRules == ["Bash(git push:*)", "Bash(npm publish:*)"])
        #expect(configuration.preToolUseHookCount == 1)
        #expect(!configuration.isEmpty)
    }

    @Test("A settings file with no permissions section imposes nothing")
    func emptySettings() throws {
        #expect(try configuration(#"{"theme":"dark"}"#).isEmpty)
        #expect(MachineConfiguration.read(from: URL(fileURLWithPath: "/nonexistent/settings.json"))
            .isEmpty)
    }

    /// `Bash(git push:*)` is the CLI's prefix form: it covers the bare command and anything that
    /// continues it, and nothing that merely starts with the same letters.
    @Test("Prefix rules match the command and its arguments, not a longer word")
    func prefixRuleMatching() throws {
        let configuration = try configuration("""
        {"permissions": {"deny": ["Bash(git push:*)"]}}
        """)

        #expect(configuration.deniesBashCommand("git push") == "Bash(git push:*)")
        #expect(configuration.deniesBashCommand("git push origin main") == "Bash(git push:*)")
        #expect(configuration.deniesBashCommand("  git push --force  ") == "Bash(git push:*)")
        #expect(configuration.deniesBashCommand("git pushall") == nil)
        #expect(configuration.deniesBashCommand("git status") == nil)
    }

    @Test("Exact rules match only that command")
    func exactRuleMatching() throws {
        let configuration = try configuration("""
        {"permissions": {"deny": ["Bash(make release)", "Read(/etc/**)"]}}
        """)

        #expect(configuration.deniesBashCommand("make release") == "Bash(make release)")
        #expect(configuration.deniesBashCommand("make release --dry-run") == nil)
        // A non-Bash rule is not a command rule, and must not be reported against one.
        #expect(configuration.deniesBashCommand("cat /etc/hosts") == nil)
    }

    @Test("An empty command matches nothing")
    func emptyCommand() throws {
        let configuration = try configuration(#"{"permissions": {"deny": ["Bash(git push:*)"]}}"#)
        #expect(configuration.deniesBashCommand("   ") == nil)
    }
}
