import Foundation

/// Generates the settings file that wires a session's `PreToolUse` hook to the approval helper.
///
/// The three deadlines must nest, outermost first:
///
///     runtime hook timeout  >  helper deadline  >  broker operator wait
///
/// If that ordering is ever inverted, the runtime's cancellation becomes the thing that ends the
/// wait — and the runtime's cancellation path *executes the command* (Finding 1). The
/// installer enforces the ordering rather than trusting call sites to get it right.
public struct ApprovalHookInstaller: Sendable {

    /// Tools routed through the approval gate. Anything that runs commands or writes to disk.
    public static let defaultMatchers = ["Bash", "Write", "Edit", "NotebookEdit"]

    public var helperPath: String
    public var socketPath: String
    /// The `timeout` written into the hook definition. 600 s is probe-verified as honoured.
    public var runtimeTimeout: Int
    /// The helper's own deadline. Must be below `runtimeTimeout`.
    public var helperDeadline: Int
    public var matchers: [String]

    public enum ConfigurationError: Error, Sendable, Equatable {
        case deadlinesNotNested(runtimeTimeout: Int, helperDeadline: Int)
        case helperNotExecutable(path: String)
    }

    public init(
        helperPath: String,
        socketPath: String,
        runtimeTimeout: Int = 600,
        helperDeadline: Int = 540,
        matchers: [String] = ApprovalHookInstaller.defaultMatchers
    ) throws {
        // A margin, not merely "less than": the helper needs room to write its verdict and exit.
        guard helperDeadline > 0, helperDeadline <= runtimeTimeout - 30 else {
            throw ConfigurationError.deadlinesNotNested(
                runtimeTimeout: runtimeTimeout, helperDeadline: helperDeadline)
        }
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            // A helper that cannot launch is exactly the fail-open case: the runtime times it out
            // and proceeds. Refuse to start a session that cannot be gated.
            throw ConfigurationError.helperNotExecutable(path: helperPath)
        }
        self.helperPath = helperPath
        self.socketPath = socketPath
        self.runtimeTimeout = runtimeTimeout
        self.helperDeadline = helperDeadline
        self.matchers = matchers
    }

    public func settingsJSON() throws -> String {
        let hooks = matchers.map { matcher -> JSONValue in
            .object([
                "matcher": .string(matcher),
                "hooks": .array([.object([
                    "type": .string("command"),
                    "command": .string(helperPath),
                    "timeout": .int(runtimeTimeout)
                ])])
            ])
        }
        let settings = JSONValue.object([
            "hooks": .object(["PreToolUse": .array(hooks)])
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(settings), as: UTF8.self)
    }

    @discardableResult
    public func writeSettings(to url: URL) throws -> URL {
        try settingsJSON().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Environment the session must pass down so the helper can find its broker.
    public var environment: [String: String] {
        [
            "HARNESS_APPROVAL_SOCKET": socketPath,
            "HARNESS_APPROVAL_DEADLINE_SECONDS": String(helperDeadline)
        ]
    }
}
