import Foundation

/// How the harness reaches an MCP server.
public enum MCPTransport: Sendable, Hashable, Codable {
    /// A child process speaking JSON-RPC over stdio.
    case stdio(command: String, arguments: [String] = [], environment: [String: String] = [:])
    case http(url: String, headers: [String: String] = [:])
    case sse(url: String, headers: [String: String] = [:])

    public var isStdio: Bool {
        if case .stdio = self { return true }
        return false
    }

    public var displayTarget: String {
        switch self {
        case .stdio(let command, let arguments, _):
            return ([command] + arguments).joined(separator: " ")
        case .http(let url, _), .sse(let url, _):
            return url
        }
    }
}

/// One configured MCP server.
public struct MCPServerDefinition: Sendable, Hashable, Codable, Identifiable {
    public var id: String { name }
    /// Becomes the middle segment of every tool id: `mcp__<name>__<tool>`.
    public var name: String
    public var transport: MCPTransport
    public var isEnabled: Bool
    /// Route stdio traffic through the harness proxy so it can be inspected. Only meaningful for
    /// stdio servers (docs/RUNTIME.md).
    public var isInspected: Bool

    public init(
        name: String, transport: MCPTransport, isEnabled: Bool = true, isInspected: Bool = false
    ) {
        self.name = name
        self.transport = transport
        self.isEnabled = isEnabled
        self.isInspected = isInspected
    }

    /// Tool ids from this server are namespaced with this prefix.
    public var toolPrefix: String { "mcp__\(name)__" }

    public func toolID(_ tool: String) -> String { toolPrefix + tool }
}

/// A tool advertised by a server, as reported in the session handshake.
public struct MCPTool: Sendable, Hashable, Identifiable {
    public var id: String { qualifiedName }
    /// Full id, e.g. `mcp__filesystem__write_file`.
    public let qualifiedName: String
    public let serverName: String
    public let toolName: String
    public var description: String?

    public init(qualifiedName: String, description: String? = nil) {
        self.qualifiedName = qualifiedName
        self.description = description
        // `mcp__<server>__<tool>`; a tool name may itself contain underscores, so split on the
        // double-underscore delimiter rather than on `_`.
        let body = qualifiedName.hasPrefix("mcp__")
            ? String(qualifiedName.dropFirst("mcp__".count)) : qualifiedName
        if let separator = body.range(of: "__") {
            serverName = String(body[body.startIndex..<separator.lowerBound])
            toolName = String(body[separator.upperBound...])
        } else {
            serverName = ""
            toolName = body
        }
    }

    /// Reads the tool list out of a session handshake.
    public static func tools(in capabilities: SessionInit) -> [MCPTool] {
        capabilities.tools
            .filter { $0.hasPrefix("mcp__") }
            .map { MCPTool(qualifiedName: $0) }
    }
}

/// The `--mcp-config` document.
public struct MCPConfiguration: Sendable {
    public var servers: [MCPServerDefinition]

    public init(servers: [MCPServerDefinition] = []) {
        self.servers = servers
    }

    public var enabledServers: [MCPServerDefinition] { servers.filter(\.isEnabled) }

    /// Renders the config, rewriting inspected stdio servers to run behind the proxy.
    ///
    /// - Parameters:
    ///   - proxyPath: the `harness-mcp-proxy` binary. Required only if a server has inspection on.
    ///   - inspectorSocketPath: where the proxy tees traffic.
    public func json(proxyPath: String? = nil, inspectorSocketPath: String? = nil) throws -> String {
        var entries: [String: JSONValue] = [:]

        for server in enabledServers {
            switch server.transport {
            case .stdio(let command, let arguments, let environment):
                var environment = environment
                var command = command
                var arguments = arguments

                if server.isInspected, let proxyPath, let inspectorSocketPath {
                    // The proxy takes the real command after `--` and relays both directions.
                    arguments = ["--server-name", server.name, "--"] + [command] + arguments
                    command = proxyPath
                    environment["HARNESS_MCP_INSPECTOR_SOCKET"] = inspectorSocketPath
                }

                var entry: [String: JSONValue] = [
                    "command": .string(command),
                    "args": .array(arguments.map(JSONValue.string))
                ]
                if !environment.isEmpty {
                    entry["env"] = .object(environment.mapValues(JSONValue.string))
                }
                entries[server.name] = .object(entry)

            case .http(let url, let headers):
                var entry: [String: JSONValue] = ["type": .string("http"), "url": .string(url)]
                if !headers.isEmpty { entry["headers"] = .object(headers.mapValues(JSONValue.string)) }
                entries[server.name] = .object(entry)

            case .sse(let url, let headers):
                var entry: [String: JSONValue] = ["type": .string("sse"), "url": .string(url)]
                if !headers.isEmpty { entry["headers"] = .object(headers.mapValues(JSONValue.string)) }
                entries[server.name] = .object(entry)
            }
        }

        let document = JSONValue.object(["mcpServers": .object(entries)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(document), as: UTF8.self)
    }

    @discardableResult
    public func write(
        to url: URL, proxyPath: String? = nil, inspectorSocketPath: String? = nil
    ) throws -> URL {
        try json(proxyPath: proxyPath, inspectorSocketPath: inspectorSocketPath)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Server connection state, read back from the session handshake.
    public static func serverStates(in capabilities: SessionInit) -> [String: String] {
        var states: [String: String] = [:]
        for server in capabilities.mcpServers {
            guard let name = server["name"]?.stringValue else { continue }
            states[name] = server["status"]?.stringValue ?? "unknown"
        }
        return states
    }
}
