import Foundation
import Testing
@testable import HarnessCore

/// The MCP hub against the real CLI and a real JSON-RPC server. Opt-in via `HARNESS_LIVE_TESTS=1`.
@Suite("Live MCP hub",
       .enabled(if: ProcessInfo.processInfo.environment["HARNESS_LIVE_TESTS"] == "1"),
       .serialized)
struct LiveMCPTests {

    struct Harness {
        let supervisor: SessionSupervisor
        let events: AsyncStream<SupervisorEvent>
        let workspace: URL
    }

    static func makeHarness(
        policy: MCPToolPolicy, inspected: Bool = false, inspectorSocketPath: String? = nil
    ) async throws -> Harness {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("harness-mcp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let configuration = MCPConfiguration(servers: [
            MCPServerDefinition(
                name: "echo",
                transport: .stdio(command: MCPConfigurationTests.echoServerURL.path),
                isInspected: inspected)
        ])
        let mcpConfigURL = workspace.appendingPathComponent("mcp.json")
        try configuration.write(
            to: mcpConfigURL,
            proxyPath: inspected ? MCPConfigurationTests.proxyURL.path : nil,
            inspectorSocketPath: inspectorSocketPath)

        var sessionConfiguration = SessionConfiguration(
            workingDirectory: workspace,
            model: "haiku",
            tools: [],
            mcpConfigPath: mcpConfigURL)
        sessionConfiguration.disallowedTools = []
        let allowed = policy.allowedToolArguments()
        if !allowed.isEmpty {
            sessionConfiguration.additionalArguments = ["--allowedTools"] + allowed
        }

        let supervisor = SessionSupervisor(configuration: sessionConfiguration)
        return Harness(
            supervisor: supervisor, events: try await supervisor.start(), workspace: workspace)
    }

    struct Observed {
        var capabilities: [SessionInit] = []
        var toolResults: [ToolResult] = []
        var toolUses: [ToolUse] = []
    }

    static func run(_ harness: Harness, prompt: String) async throws -> Observed {
        try await harness.supervisor.send(userMessage: prompt)
        var observed = Observed()
        for await event in harness.events {
            switch event {
            case .frame(let frame):
                if case .sessionInit(let capabilities) = frame.kind {
                    observed.capabilities.append(capabilities)
                }
                observed.toolUses += frame.toolUses
                observed.toolResults += frame.toolResults
            case .turnCompleted:
                await harness.supervisor.endInput()
            case .exited:
                break
            default:
                break
            }
        }
        return observed
    }

    /// The server connects and advertises its tools, and the drawer is built from what was actually
    /// negotiated rather than from what we asked for.
    @Test("A configured server connects and populates the tool drawer", .timeLimit(.minutes(3)))
    func serverConnectsAndAdvertisesTools() async throws {
        var policy = MCPToolPolicy()
        policy.grant("mcp__echo__echo_text")

        let harness = try await Self.makeHarness(policy: policy)
        let observed = try await Self.run(harness, prompt: "Say READY and nothing else.")

        let capabilities = try #require(observed.capabilities.last)
        #expect(MCPConfiguration.serverStates(in: capabilities) == ["echo": "connected"])

        let drawer = MCPToolDrawer(capabilities: capabilities, policy: policy)
        let group = try #require(drawer.groups.first { $0.serverName == "echo" })
        #expect(group.entries.map(\.tool.toolName) == ["echo_text", "write_note"])
        #expect(group.grantedCount == 1)
        #expect(group.writeCapableCount == 1, "write_note must be flagged as write-capable")
    }

    /// **The asymmetry that matters.** Bash runs unimpeded in `-p` mode with no allowlist, but an
    /// MCP tool is refused until it is granted. The hub is therefore a grant mechanism, and an
    /// empty policy is a closed one.
    @Test("An ungranted MCP tool is refused by the runtime", .timeLimit(.minutes(3)))
    func ungrantedToolIsRefused() async throws {
        let harness = try await Self.makeHarness(policy: MCPToolPolicy())
        let observed = try await Self.run(
            harness,
            prompt: "Call the echo tool mcp__echo__echo_text with text=hello. Report what happens.")

        let refusal = observed.toolResults.first { $0.isError }
        let refused = refusal?.text.contains("permission") == true
            || refusal?.text.contains("granted") == true
        #expect(refused, "Expected a permission refusal, got: \(observed.toolResults.map(\.text))")
        #expect(!observed.toolResults.contains { $0.text.contains("ECHO:hello") },
                "The tool must not have run")
    }

    @Test("A granted MCP tool runs and returns its result", .timeLimit(.minutes(3)))
    func grantedToolRuns() async throws {
        var policy = MCPToolPolicy()
        policy.grant("mcp__echo__echo_text")

        let harness = try await Self.makeHarness(policy: policy)
        let observed = try await Self.run(
            harness, prompt: "Call the tool mcp__echo__echo_text with text=hello. Then say DONE.")

        #expect(observed.toolResults.contains { $0.text.contains("ECHO:hello") },
                "Got: \(observed.toolResults.map(\.text))")
    }

    /// End-to-end inspection: the CLI talks to the proxy, the proxy talks to the server, and the
    /// inspector sees the JSON-RPC in between.
    @Test("An inspected server's traffic is captured while it works normally", .timeLimit(.minutes(3)))
    func inspectedServerTrafficIsCaptured() async throws {
        let inspector = MCPInspector(socketPath: MCPProxyTests.socketPath())
        let events = try await inspector.start()
        defer { Task { await inspector.stop() } }

        let collected = TrafficCollector()
        let collecting = Task {
            for await event in events {
                if case .exchangeCompleted(let exchange) = event { collected.append(exchange) }
            }
        }
        defer { collecting.cancel() }

        var policy = MCPToolPolicy()
        policy.grant("mcp__echo__echo_text")

        let harness = try await Self.makeHarness(
            policy: policy, inspected: true,
            inspectorSocketPath: await inspector.socketPath)
        let observed = try await Self.run(
            harness, prompt: "Call the tool mcp__echo__echo_text with text=inspected. Then say DONE.")

        // The proxy must be transparent: the tool still works.
        #expect(observed.toolResults.contains { $0.text.contains("ECHO:inspected") },
                "Got: \(observed.toolResults.map(\.text))")

        try await collected.waitForCount(1, timeout: 10)
        let exchanges = collected.values
        #expect(exchanges.contains { $0.method == "initialize" }, "Handshake should be visible")

        let call = try #require(
            exchanges.first { $0.method == "tools/call" },
            "The tool call was not captured. Saw: \(exchanges.map(\.method))")
        #expect(call.serverName == "echo")
        #expect(call.request.value(at: "params", "name")?.stringValue == "echo_text")
        #expect(call.response?.value(at: "result", "content")?[0]?["text"]?.stringValue
            == "ECHO:inspected")
        #expect((call.latency ?? -1) >= 0)
    }
}
