import Foundation
import Testing
@testable import HarnessCore

@Suite("Session launch configuration")
struct SessionConfigurationTests {

    /// Defaults to sealed so the isolation assertions below read as assertions about that mode.
    /// The app's own default is `.inherited`; that is asserted separately.
    private func arguments(
        isolation: SessionConfiguration.Isolation = .sealed,
        _ configure: (inout SessionConfiguration) -> Void = { _ in }
    ) -> [String] {
        var configuration = SessionConfiguration(
            workingDirectory: URL(fileURLWithPath: "/tmp"), isolation: isolation)
        configure(&configuration)
        return configuration.arguments()
    }

    /// Without `--verbose` the CLI emits no streaming frames at all in `-p` mode. Losing this flag
    /// produces a session that launches cleanly and then appears to hang forever.
    @Test("--verbose is always present")
    func verboseAlwaysPresent() {
        #expect(arguments().contains("--verbose"))
    }

    /// Guards docs/RUNTIME.md Finding 4: `--setting-sources ""` does not isolate MCP servers, so the
    /// strict flag is not a companion to `--mcp-config`.
    @Test("Sealed mode passes --strict-mcp-config regardless of an MCP config file")
    func strictMCPConfigUnconditionalWhenSealed() {
        #expect(arguments().contains("--strict-mcp-config"))
        #expect(arguments { $0.mcpConfigPath = URL(fileURLWithPath: "/tmp/mcp.json") }
            .contains("--strict-mcp-config"))
    }

    @Test("Sealed mode does not inherit operator settings")
    func settingSourcesSuppressedWhenSealed() {
        let args = arguments()
        let index = args.firstIndex(of: "--setting-sources")
        #expect(index != nil)
        if let index { #expect(args[index + 1].isEmpty) }
    }

    /// Inherited mode is the app's default: a session behaves like `claude` in a terminal, so the
    /// operator's commands, skills, `CLAUDE.md`, and MCP servers all load.
    @Test("Inherited mode omits both isolation flags")
    func inheritedModeOmitsIsolationFlags() {
        let args = arguments(isolation: .inherited)
        #expect(!args.contains("--setting-sources"))
        #expect(!args.contains("--strict-mcp-config"))
    }

    /// Everything the gate depends on is independent of setting sources, so widening isolation
    /// must not quietly widen execution.
    @Test("Inherited mode keeps the gate and the static denylist")
    func inheritedModeKeepsEnforcement() {
        let args = arguments(isolation: .inherited) {
            $0.settingsPath = URL(fileURLWithPath: "/tmp/settings.json")
        }
        #expect(args.contains("--settings"))
        #expect(args.contains("--disallowedTools"))
        #expect(args.contains { $0.hasPrefix("Bash(rm ") })
        #expect(args.contains("--verbose"))
    }

    @Test("Isolation defaults to sealed at the configuration layer")
    func configurationDefaultsToSealed() {
        let configuration = SessionConfiguration(workingDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(configuration.isolation == .sealed)
    }

    /// The crash-proof backstop from docs/RUNTIME.md Finding 3 — the only enforcement that survives the
    /// app dying, so it must never default to empty.
    @Test("A static denylist is passed by default")
    func denylistByDefault() {
        let args = arguments()
        #expect(args.contains("--disallowedTools"))
        #expect(args.contains { $0.hasPrefix("Bash(rm ") })
    }

    @Test("Duplex stream-json transport is configured")
    func duplexTransport() {
        let args = arguments()
        for flag in ["--input-format", "--output-format", "--replay-user-messages",
                     "--forward-subagent-text", "--include-hook-events"] {
            #expect(args.contains(flag), "Missing \(flag)")
        }
        #expect(args.filter { $0 == "stream-json" }.count == 2)
    }

    /// Print mode is not used. The duplex transport works without it, and the handshake carries
    /// more outside print mode — `terminal_slash_commands`, `plugins`, `capabilities`, and
    /// `memory_paths` are absent under `-p`. Probe-verified over a two-turn exchange.
    @Test("Print mode is not used")
    func printModeNotUsed() {
        #expect(!arguments().contains("-p"))
        #expect(!arguments().contains("--print"))
    }

    /// A bare `--tools` consumes the following flag as if it were a tool name. Emitting it before
    /// `--strict-mcp-config` swallowed the isolation flag outright, and a session that should have
    /// had one MCP server connected ten — including account connectors with outbound-messaging and
    /// record-write tools. The empty tool set must be spelled `--tools ""`.
    @Test("An empty tool set never emits a bare variadic flag")
    func emptyToolSetUsesExplicitEmptyValue() {
        let args = arguments { $0.tools = [] }
        let index = args.firstIndex(of: "--tools")
        #expect(index != nil)
        if let index {
            #expect(index + 1 < args.count, "--tools must not be the final argument")
            #expect(args[index + 1] == "", "The empty tool set is spelled --tools \"\"")
            #expect(!args[index + 1].hasPrefix("--"), "A bare --tools would swallow the next flag")
        }
    }

    /// Generalises the bug: no variadic flag may ever be followed immediately by another flag, in
    /// any configuration.
    @Test("No variadic flag is left without a value")
    func variadicFlagsAlwaysCarryValues() {
        let variadics = ["--tools", "--allowedTools", "--disallowedTools"]
        let configurations: [(inout SessionConfiguration) -> Void] = [
            { _ in },
            { $0.tools = [] },
            { $0.tools = ["Bash"] },
            { $0.disallowedTools = [] },
            { $0.tools = []; $0.disallowedTools = [] },
            { $0.tools = []; $0.disallowedTools = []; $0.mcpConfigPath = URL(fileURLWithPath: "/tmp/m.json") },
        ]
        for configure in configurations {
            let args = arguments(configure)
            for (index, argument) in args.enumerated() where variadics.contains(argument) {
                #expect(index + 1 < args.count, "\(argument) is the last argument")
                if index + 1 < args.count {
                    #expect(!args[index + 1].hasPrefix("--"),
                            "\(argument) is immediately followed by \(args[index + 1])")
                }
            }
        }
    }

    /// Ordering is a safety property, not a style choice: isolation flags must be parsed before any
    /// variadic flag gets a chance to swallow them.
    @Test("Isolation flags precede every variadic flag")
    func isolationFlagsComeFirst() {
        let args = arguments { $0.tools = []; $0.mcpConfigPath = URL(fileURLWithPath: "/tmp/m.json") }
        let strict = try! #require(args.firstIndex(of: "--strict-mcp-config"))
        let mcpConfig = try! #require(args.firstIndex(of: "--mcp-config"))
        for variadic in ["--tools", "--disallowedTools"] {
            if let index = args.firstIndex(of: variadic) {
                #expect(strict < index, "--strict-mcp-config must precede \(variadic)")
                #expect(mcpConfig < index, "--mcp-config must precede \(variadic)")
            }
        }
    }

    @Test("Partial messages are opt-in")
    func partialMessagesOptIn() {
        #expect(!arguments().contains("--include-partial-messages"))
        #expect(arguments { $0.includePartialMessages = true }.contains("--include-partial-messages"))
    }
}

/// Which account a session bills against.
///
/// The CLI resolves credentials in a fixed order and an environment variable outranks the
/// signed-in profile, so a stray `ANTHROPIC_API_KEY` moves every session onto API billing without
/// anything changing in the interface. That is the failure this suite exists to prevent.
@Suite("Session billing")
struct SessionBillingTests {

    private func environment(
        billing: SessionConfiguration.Billing,
        inheriting base: [String: String]
    ) -> [String: String] {
        SessionConfiguration(
            workingDirectory: URL(fileURLWithPath: "/tmp"), billing: billing)
            .resolvedEnvironment(inheriting: base)
    }

    @Test("Subscription billing is the default")
    func subscriptionIsDefault() {
        let configuration = SessionConfiguration(workingDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(configuration.billing == .subscription)
    }

    @Test("Every credential override is stripped under subscription billing")
    func stripsCredentialOverrides() {
        let base = [
            "ANTHROPIC_API_KEY": "sk-test",
            "ANTHROPIC_AUTH_TOKEN": "token",
            "ANTHROPIC_BASE_URL": "https://example.test",
            "CLAUDE_CODE_USE_BEDROCK": "1",
            "CLAUDE_CODE_USE_VERTEX": "1",
            "PATH": "/usr/bin"
        ]
        let resolved = environment(billing: .subscription, inheriting: base)

        for key in SessionConfiguration.credentialOverrides {
            #expect(resolved[key] == nil, "\(key) survived")
        }
        // Everything else the operator's shell provides must still reach the child.
        #expect(resolved["PATH"] == "/usr/bin")
    }

    @Test("Environment billing leaves credentials alone")
    func environmentBillingPassesThrough() {
        let resolved = environment(
            billing: .environment, inheriting: ["ANTHROPIC_API_KEY": "sk-test"])
        #expect(resolved["ANTHROPIC_API_KEY"] == "sk-test")
    }

    /// The approval helper learns its socket path this way, so the merge must still win.
    @Test("Explicit additions still override the inherited environment")
    func additionsStillWin() {
        var configuration = SessionConfiguration(workingDirectory: URL(fileURLWithPath: "/tmp"))
        configuration.additionalEnvironment = ["HARNESS_SOCKET": "/tmp/sock"]
        let resolved = configuration.resolvedEnvironment(inheriting: ["HARNESS_SOCKET": "stale"])
        #expect(resolved["HARNESS_SOCKET"] == "/tmp/sock")
    }

    /// A dropped screenshot is copied into the attachment store, so a session that cannot read
    /// that directory answers a file the operator just handed it with a permission error.
    @Test("The attachment store is on --add-dir by default")
    func attachmentDirectoryGranted() {
        let args = SessionConfiguration(
            workingDirectory: URL(fileURLWithPath: "/tmp")).arguments()
        guard let index = args.firstIndex(of: "--add-dir") else {
            Issue.record("--add-dir was not passed")
            return
        }
        let granted = args[(index + 1)...].prefix { !$0.hasPrefix("--") }
        #expect(granted.contains(AttachmentStore.defaultDirectory.resolvingSymlinksInPath().path))
    }

    /// `--add-dir` is variadic, so a bare one would eat whatever flag came next — the same fault
    /// `appendVariadic` exists to prevent for `--tools`.
    @Test("No directories means no --add-dir at all")
    func noAddDirWhenEmpty() {
        var configuration = SessionConfiguration(workingDirectory: URL(fileURLWithPath: "/tmp"))
        configuration.additionalDirectories = []
        #expect(!configuration.arguments().contains("--add-dir"))
    }
}

@Suite("Attachment store")
struct AttachmentStoreTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The drop directory macOS hands a dragged screenshot over in.
    @Test("A file in the per-user temporary tree is out of the agent's reach")
    func temporaryFilesNeedCopying() {
        let dropped = FileManager.default.temporaryDirectory
            .appendingPathComponent("TemporaryItems/NSIRD_screencaptureui_ABC/Screenshot.png")
        #expect(AttachmentStore.isUnreachableByAgent(dropped))
        #expect(!AttachmentStore.isUnreachableByAgent(URL(fileURLWithPath: "/Users/x/project/a.png")))
    }

    @Test("Adopting copies the file and leaves the original alone")
    func adoptCopies() throws {
        let source = try temporaryDirectory()
        let store = AttachmentStore(directory: try temporaryDirectory())
        let original = source.appendingPathComponent("Screenshot 1.png")
        try Data("bytes".utf8).write(to: original)

        let adopted = try store.adopt(original)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(try Data(contentsOf: adopted) == Data("bytes".utf8))
    }

    /// The copied path is written into a prompt as an `@mention`, and a space there ends the
    /// mention early — so the agent would be handed `@/…/Screenshot` and nothing after it.
    @Test("Whitespace is folded out of the copied name")
    func nameIsMentionable() throws {
        #expect(
            AttachmentStore.mentionable("Screenshot 2026-08-22 at 9.45.42 PM.png")
                == "Screenshot-2026-08-22-at-9.45.42-PM.png")

        let store = AttachmentStore(directory: try temporaryDirectory())
        let source = try temporaryDirectory().appendingPathComponent("a b.png")
        try Data().write(to: source)
        #expect(try store.adopt(source).lastPathComponent == "a-b.png")
    }

    @Test("Two files of the same name do not collide")
    func adoptionsAreDistinct() throws {
        let store = AttachmentStore(directory: try temporaryDirectory())
        let first = try temporaryDirectory().appendingPathComponent("shot.png")
        let second = try temporaryDirectory().appendingPathComponent("shot.png")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)

        let a = try store.adopt(first)
        let b = try store.adopt(second)
        #expect(a != b)
        #expect(try Data(contentsOf: a) == Data("one".utf8))
        #expect(try Data(contentsOf: b) == Data("two".utf8))
    }

    @Test("Pruning drops what is past its age and keeps the rest")
    func pruneByAge() throws {
        let store = AttachmentStore(directory: try temporaryDirectory())
        let recent = try store.adopt(try makeFile(named: "recent.png"))
        let old = try store.adopt(try makeFile(named: "old.png"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: old.deletingLastPathComponent().path)

        store.prune(olderThan: 60)
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    private func makeFile(named name: String) throws -> URL {
        let url = try temporaryDirectory().appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }
}
