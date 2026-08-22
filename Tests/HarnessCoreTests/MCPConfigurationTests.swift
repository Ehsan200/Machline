import Foundation
import Testing
@testable import HarnessCore

@Suite("MCP configuration and tool policy")
struct MCPConfigurationTests {

    static var echoServerURL: URL {
        Bundle.module.bundleURL.deletingLastPathComponent().appendingPathComponent("harness-echo-mcp")
    }

    static var proxyURL: URL {
        Bundle.module.bundleURL.deletingLastPathComponent().appendingPathComponent("harness-mcp-proxy")
    }

    private func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    // MARK: - Config generation

    /// Probe-verified shape: `{"mcpServers":{"<name>":{"command":…,"args":[…],"env":{…}}}}`.
    @Test("A stdio server renders in the verified config shape")
    func stdioConfigShape() throws {
        let configuration = MCPConfiguration(servers: [
            MCPServerDefinition(
                name: "echo",
                transport: .stdio(
                    command: "/usr/local/bin/echo-mcp",
                    arguments: ["--flag"],
                    environment: ["API_KEY": "secret"]))
        ])
        let value = try decode(try configuration.json())
        let entry = try #require(value.value(at: "mcpServers", "echo"))
        #expect(entry["command"]?.stringValue == "/usr/local/bin/echo-mcp")
        #expect(entry["args"]?.arrayValue?.compactMap(\.stringValue) == ["--flag"])
        #expect(entry.value(at: "env", "API_KEY")?.stringValue == "secret")
    }

    @Test("HTTP and SSE servers carry their transport type and headers")
    func remoteConfigShape() throws {
        let configuration = MCPConfiguration(servers: [
            MCPServerDefinition(name: "remote", transport: .http(
                url: "https://example.invalid/mcp", headers: ["Authorization": "Bearer x"])),
            MCPServerDefinition(name: "streamed", transport: .sse(url: "https://example.invalid/sse"))
        ])
        let value = try decode(try configuration.json())
        #expect(value.value(at: "mcpServers", "remote", "type")?.stringValue == "http")
        #expect(value.value(at: "mcpServers", "remote", "headers", "Authorization")?.stringValue
            == "Bearer x")
        #expect(value.value(at: "mcpServers", "streamed", "type")?.stringValue == "sse")
    }

    @Test("Disabled servers are omitted entirely")
    func disabledServersOmitted() throws {
        let configuration = MCPConfiguration(servers: [
            MCPServerDefinition(name: "on", transport: .stdio(command: "a")),
            MCPServerDefinition(name: "off", transport: .stdio(command: "b"), isEnabled: false)
        ])
        let servers = try #require(decode(try configuration.json())["mcpServers"]?.objectValue)
        #expect(servers.keys.sorted() == ["on"])
    }

    /// Inspection rewrites the command to run behind the proxy, preserving the original command and
    /// its arguments after the `--` separator.
    @Test("An inspected server is rewritten to run behind the proxy")
    func inspectedServerRewritten() throws {
        let configuration = MCPConfiguration(servers: [
            MCPServerDefinition(
                name: "echo",
                transport: .stdio(command: "/bin/real-server", arguments: ["--port", "1"]),
                isInspected: true)
        ])
        let value = try decode(try configuration.json(
            proxyPath: "/opt/harness-mcp-proxy", inspectorSocketPath: "/tmp/inspect.sock"))
        let entry = try #require(value.value(at: "mcpServers", "echo"))

        #expect(entry["command"]?.stringValue == "/opt/harness-mcp-proxy")
        #expect(entry["args"]?.arrayValue?.compactMap(\.stringValue)
            == ["--server-name", "echo", "--", "/bin/real-server", "--port", "1"])
        #expect(entry.value(at: "env", "HARNESS_MCP_INSPECTOR_SOCKET")?.stringValue
            == "/tmp/inspect.sock")
    }

    /// Without a proxy path there is nothing to route through, so the server must run directly
    /// rather than being silently dropped.
    @Test("Inspection without a proxy falls back to running the server directly")
    func inspectionWithoutProxyFallsBack() throws {
        let configuration = MCPConfiguration(servers: [
            MCPServerDefinition(
                name: "echo", transport: .stdio(command: "/bin/real-server"), isInspected: true)
        ])
        let entry = try #require(decode(try configuration.json()).value(at: "mcpServers", "echo"))
        #expect(entry["command"]?.stringValue == "/bin/real-server")
    }

    // MARK: - Tool identity

    @Test("Qualified tool names split on the double-underscore delimiter")
    func toolNameParsing() {
        let tool = MCPTool(qualifiedName: "mcp__my_server__write_file_now")
        #expect(tool.serverName == "my_server", "A server name may itself contain underscores")
        #expect(tool.toolName == "write_file_now")
    }

    // MARK: - Capability classification

    @Test("Leading verbs classify read and write tools", arguments: [
        ("mcp__fs__read_file", MCPToolCapability.read),
        ("mcp__fs__list_directory", .read),
        ("mcp__fs__get_status", .read),
        ("mcp__fs__write_file", .write),
        ("mcp__fs__delete_file", .write),
        ("mcp__slack__send_message", .write),
        ("mcp__crm__update_lead", .write),
        ("mcp__git__push_branch", .write),
    ])
    func capabilityClassification(name: String, expected: MCPToolCapability) {
        #expect(MCPToolCapability.classify(MCPTool(qualifiedName: name)) == expected)
    }

    /// An unclassifiable tool is treated as dangerous, not as safe.
    @Test("Unknown tools still require confirmation")
    func unknownRequiresConfirmation() {
        let capability = MCPToolCapability.classify(MCPTool(qualifiedName: "mcp__x__frobnicate"))
        #expect(capability == .unknown)
        #expect(capability.requiresConfirmation)
        #expect(!MCPToolCapability.read.requiresConfirmation)
        #expect(MCPToolCapability.write.requiresConfirmation)
    }

    // MARK: - Grants

    /// MCP tools are denied by the runtime until named in `--allowedTools`, so an empty policy is a
    /// closed one and this type grants rather than restricts.
    @Test("An empty policy grants nothing")
    func emptyPolicyIsClosed() {
        let policy = MCPToolPolicy()
        #expect(!policy.isGranted("mcp__echo__echo_text"))
        #expect(policy.allowedToolArguments().isEmpty)
    }

    @Test("Grants are global or per-agent, and revocation beats both")
    func grantScopes() {
        var policy = MCPToolPolicy()
        policy.grant("mcp__echo__echo_text")
        policy.grant("mcp__echo__write_note", toAgent: "writer")

        #expect(policy.isGranted("mcp__echo__echo_text"))
        #expect(policy.isGranted("mcp__echo__echo_text", toAgent: "writer"))
        #expect(!policy.isGranted("mcp__echo__write_note"), "Agent grants do not leak to the session")
        #expect(policy.isGranted("mcp__echo__write_note", toAgent: "writer"))
        #expect(policy.tools(forAgent: "writer") == ["mcp__echo__echo_text", "mcp__echo__write_note"])

        policy.revoke("mcp__echo__echo_text")
        #expect(!policy.isGranted("mcp__echo__echo_text", toAgent: "writer"),
                "A revocation must override an existing grant")
        #expect(policy.disallowedToolArguments() == ["mcp__echo__echo_text"])
    }

    @Test("Allowed-tool arguments are stable across launches")
    func stableArgumentOrder() {
        var policy = MCPToolPolicy()
        for name in ["mcp__b__two", "mcp__a__one", "mcp__c__three"] { policy.grant(name) }
        #expect(policy.allowedToolArguments() == ["mcp__a__one", "mcp__b__two", "mcp__c__three"])
    }

    @Test("Server-level toggles grant and revoke every tool at once")
    func serverLevelToggle() {
        let server = MCPServerDefinition(name: "echo", transport: .stdio(command: "x"))
        let tools = [
            MCPTool(qualifiedName: "mcp__echo__echo_text"),
            MCPTool(qualifiedName: "mcp__echo__write_note"),
            MCPTool(qualifiedName: "mcp__other__thing")
        ]
        var policy = MCPToolPolicy()
        policy.grantAll(from: server, tools: tools)
        #expect(policy.allowedToolArguments() == ["mcp__echo__echo_text", "mcp__echo__write_note"])
        #expect(!policy.isGranted("mcp__other__thing"), "Other servers are untouched")

        policy.revokeAll(from: server, tools: tools)
        #expect(policy.allowedToolArguments().isEmpty)
    }

    // MARK: - Drawer

    @Test("The drawer groups tools by server with grant and capability state")
    func drawerGrouping() {
        let capabilities = SessionInit(frame: .object([
            "tools": .array([
                .string("Bash"),
                .string("mcp__echo__echo_text"),
                .string("mcp__echo__write_note"),
                .string("mcp__notes__list_notes")
            ]),
            "mcp_servers": .array([
                .object(["name": .string("echo"), "status": .string("connected")]),
                .object(["name": .string("notes"), "status": .string("connected")]),
                .object(["name": .string("broken"), "status": .string("failed")])
            ])
        ]))

        var policy = MCPToolPolicy()
        policy.grant("mcp__echo__echo_text")

        let drawer = MCPToolDrawer(capabilities: capabilities, policy: policy)
        #expect(drawer.groups.map(\.serverName) == ["broken", "echo", "notes"])

        let echo = try! #require(drawer.groups.first { $0.serverName == "echo" })
        #expect(echo.entries.map(\.tool.toolName) == ["echo_text", "write_note"])
        #expect(echo.grantedCount == 1)
        #expect(echo.writeCapableCount == 1)
        #expect(echo.entries[0].isGranted)
        #expect(!echo.entries[1].isGranted)
        #expect(echo.entries[1].requiresConfirmation)

        // Built-in tools are not MCP tools and must not appear.
        #expect(!drawer.groups.contains { $0.entries.contains { $0.tool.toolName == "Bash" } })

        // A server that connected but advertised nothing stays visible so the failure is legible.
        let broken = try! #require(drawer.groups.first { $0.serverName == "broken" })
        #expect(broken.connectionStatus == "failed")
        #expect(broken.entries.isEmpty)
    }

    @Test("Server connection states are read back from the handshake")
    func serverStates() {
        let capabilities = SessionInit(frame: .object([
            "mcp_servers": .array([
                .object(["name": .string("echo"), "status": .string("connected")]),
                .object(["name": .string("down"), "status": .string("failed")])
            ])
        ]))
        let states = MCPConfiguration.serverStates(in: capabilities)
        #expect(states == ["echo": "connected", "down": "failed"])
    }
}
