import Foundation

/// Advisory classification of what an MCP tool is likely to do.
///
/// Like `RiskClassifier`, this is a **labelling aid, not a security boundary** — it reads names and
/// descriptions, which a server author controls. It decides which tools get flagged for mandatory
/// confirmation in the UI (README, Runtime); it never decides what runs.
public enum MCPToolCapability: String, Sendable, Codable, CaseIterable {
    case read
    case write
    case unknown

    /// Verbs that indicate a tool changes state somewhere.
    static let writeVerbs = [
        "write", "create", "add", "update", "modify", "edit", "set", "put", "patch",
        "delete", "remove", "destroy", "drop", "clear", "reset",
        "send", "post", "publish", "push", "upload", "commit", "merge",
        "run", "exec", "execute", "invoke", "install", "deploy", "move", "rename",
        "assign", "approve", "reject", "cancel", "schedule", "issue", "import", "bulk"
    ]

    static let readVerbs = [
        "get", "list", "read", "show", "search", "find", "query", "fetch", "describe",
        "inspect", "view", "status", "count", "check", "resolve", "explore"
    ]

    public static func classify(_ tool: MCPTool) -> MCPToolCapability {
        let name = tool.toolName.lowercased()
        let separators = CharacterSet(charactersIn: "_-. /")
        let words = name.components(separatedBy: separators).filter { !$0.isEmpty }

        // A leading verb is the strongest signal; `list_leads` reads, `delete_leads` writes.
        if let first = words.first {
            if writeVerbs.contains(first) { return .write }
            if readVerbs.contains(first) { return .read }
        }
        if words.contains(where: { writeVerbs.contains($0) }) { return .write }
        if words.contains(where: { readVerbs.contains($0) }) { return .read }

        if let description = tool.description?.lowercased() {
            if writeVerbs.contains(where: { description.contains($0 + " ") }) { return .write }
            if readVerbs.contains(where: { description.contains($0 + " ") }) { return .read }
        }
        // Unclassifiable means "treat as dangerous", not "treat as safe".
        return .unknown
    }

    /// Anything not clearly read-only gets mandatory confirmation.
    public var requiresConfirmation: Bool { self != .read }
}

/// Which tools each agent may use.
///
/// MCP tools are **denied by default** by the runtime — a session with a connected server still
/// cannot call its tools until they are named in `--allowedTools` (verified; see README, Runtime). That
/// makes this type the grant mechanism rather than a restriction mechanism: an empty policy is a
/// closed one.
public struct MCPToolPolicy: Sendable, Codable {

    /// Tools granted to every agent in the session.
    public private(set) var globalGrants: Set<String> = []
    /// Additional grants for one named subagent.
    public private(set) var agentGrants: [String: Set<String>] = [:]
    /// Tools explicitly withheld, overriding any grant.
    public private(set) var revoked: Set<String> = []

    public init(
        globalGrants: Set<String> = [], agentGrants: [String: Set<String>] = [:],
        revoked: Set<String> = []
    ) {
        self.globalGrants = globalGrants
        self.agentGrants = agentGrants
        self.revoked = revoked
    }

    public mutating func grant(_ toolID: String, toAgent agent: String? = nil) {
        revoked.remove(toolID)
        if let agent {
            agentGrants[agent, default: []].insert(toolID)
        } else {
            globalGrants.insert(toolID)
        }
    }

    public mutating func revoke(_ toolID: String, fromAgent agent: String? = nil) {
        if let agent {
            agentGrants[agent]?.remove(toolID)
        } else {
            globalGrants.remove(toolID)
            revoked.insert(toolID)
        }
    }

    public func isGranted(_ toolID: String, toAgent agent: String? = nil) -> Bool {
        if revoked.contains(toolID) { return false }
        if globalGrants.contains(toolID) { return true }
        guard let agent else { return false }
        return agentGrants[agent]?.contains(toolID) ?? false
    }

    /// Grants every tool from a server at once, for the server-level toggle.
    public mutating func grantAll(from server: MCPServerDefinition, tools: [MCPTool], toAgent agent: String? = nil) {
        for tool in tools where tool.serverName == server.name {
            grant(tool.qualifiedName, toAgent: agent)
        }
    }

    public mutating func revokeAll(from server: MCPServerDefinition, tools: [MCPTool]) {
        for tool in tools where tool.serverName == server.name {
            revoke(tool.qualifiedName)
        }
    }

    /// The `--allowedTools` values for the session.
    ///
    /// Ordered so the argument list is stable across launches, which keeps generated configs
    /// diffable and prompt caches warm.
    public func allowedToolArguments() -> [String] {
        globalGrants.subtracting(revoked).sorted()
    }

    /// The `--disallowedTools` values: an explicit denylist beats everything else and survives an
    /// app crash (Finding 3).
    public func disallowedToolArguments() -> [String] {
        revoked.sorted()
    }

    /// Tools an agent may use, for building its `--agents` entry.
    public func tools(forAgent agent: String) -> [String] {
        globalGrants.union(agentGrants[agent] ?? []).subtracting(revoked).sorted()
    }
}

/// A server plus its advertised tools and their grant state — the shape the tool drawer renders.
public struct MCPToolDrawer: Sendable {
    public struct Entry: Sendable, Identifiable {
        public var id: String { tool.qualifiedName }
        public let tool: MCPTool
        public let capability: MCPToolCapability
        public let isGranted: Bool
        public var requiresConfirmation: Bool { capability.requiresConfirmation }
    }

    public struct Group: Sendable, Identifiable {
        public var id: String { serverName }
        public let serverName: String
        public let connectionStatus: String
        public let entries: [Entry]

        public init(serverName: String, connectionStatus: String, entries: [Entry]) {
            self.serverName = serverName
            self.connectionStatus = connectionStatus
            self.entries = entries
        }

        public var grantedCount: Int { entries.filter(\.isGranted).count }
        public var writeCapableCount: Int { entries.filter { $0.capability == .write }.count }
    }

    public let groups: [Group]

    /// Builds the drawer from a session handshake and the current policy.
    public init(capabilities: SessionInit, policy: MCPToolPolicy, agent: String? = nil) {
        let states = MCPConfiguration.serverStates(in: capabilities)
        let tools = MCPTool.tools(in: capabilities)
        let grouped = Dictionary(grouping: tools, by: \.serverName)

        // Include servers that connected but advertised nothing, so a broken server is visible
        // rather than silently absent.
        var serverNames = Set(grouped.keys)
        serverNames.formUnion(states.keys)

        groups = serverNames.sorted().map { serverName in
            let entries = (grouped[serverName] ?? [])
                .sorted { $0.toolName < $1.toolName }
                .map { tool in
                    Entry(
                        tool: tool,
                        capability: MCPToolCapability.classify(tool),
                        isGranted: policy.isGranted(tool.qualifiedName, toAgent: agent))
                }
            return Group(
                serverName: serverName,
                connectionStatus: states[serverName] ?? "unknown",
                entries: entries)
        }
    }
}
