import Darwin
import Foundation

/// A stored approval rule.
///
/// Rules are matched against the tool name and, for `Bash`, the command string. Deny rules always
/// beat allow rules.
public struct ApprovalRule: Sendable, Hashable, Codable, Identifiable {
    public enum Matcher: Sendable, Hashable, Codable {
        case any
        case exact(String)
        case prefix(String)
        /// `fnmatch` glob, e.g. `git status*`. The shape operators are used to writing.
        case glob(String)

        func matches(_ candidate: String) -> Bool {
            switch self {
            case .any:
                return true
            case .exact(let value):
                return candidate == value
            case .prefix(let value):
                return candidate.hasPrefix(value)
            case .glob(let pattern):
                return fnmatch(pattern, candidate, 0) == 0
            }
        }

        public var displayText: String {
            switch self {
            case .any: return "*"
            case .exact(let value): return value
            case .prefix(let value): return "\(value)…"
            case .glob(let value): return value
            }
        }
    }

    public enum Effect: String, Sendable, Codable {
        case allow
        case deny
    }

    /// How long a rule survives. Session rules die with the session; nothing is persisted silently.
    public enum Scope: String, Sendable, Codable {
        case session
        case project
        case persistent
    }

    public var id: UUID
    public var toolName: Matcher
    /// Applied to the command string for `Bash`, and to the tool's summary otherwise.
    public var argument: Matcher
    public var effect: Effect
    public var scope: Scope
    public var reason: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        toolName: Matcher,
        argument: Matcher = .any,
        effect: Effect,
        scope: Scope = .session,
        reason: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.toolName = toolName
        self.argument = argument
        self.effect = effect
        self.scope = scope
        self.reason = reason
        self.createdAt = createdAt
    }

    public func matches(payload: HookPayload) -> Bool {
        guard toolName.matches(payload.toolName) else { return false }
        return argument.matches(payload.bashCommand ?? payload.summary)
    }

    /// Convenience for the sheet's "always allow" button.
    public static func allowBashPrefix(_ prefix: String, scope: Scope = .session) -> ApprovalRule {
        ApprovalRule(toolName: .exact("Bash"), argument: .prefix(prefix), effect: .allow, scope: scope)
    }
}

/// The rule set consulted before an operator is ever asked.
public struct PolicyStore: Sendable, Codable {
    public private(set) var rules: [ApprovalRule]

    public init(rules: [ApprovalRule] = []) {
        self.rules = rules
    }

    public mutating func add(_ rule: ApprovalRule) {
        rules.append(rule)
    }

    public mutating func remove(id: UUID) {
        rules.removeAll { $0.id == id }
    }

    public mutating func removeAll(scope: ApprovalRule.Scope) {
        rules.removeAll { $0.scope == scope }
    }

    public struct Match: Sendable, Hashable {
        public let rule: ApprovalRule
        public let decision: ApprovalDecision
    }

    /// Evaluates the rule set. Deny rules are checked first and win outright, so adding an allow
    /// rule can never widen access past an existing denial.
    public func evaluate(payload: HookPayload) -> Match? {
        if let rule = rules.first(where: { $0.effect == .deny && $0.matches(payload: payload) }) {
            return Match(rule: rule, decision: ApprovalDecision(
                verdict: .deny,
                reason: rule.reason ?? "Blocked by AgentHarness rule: \(rule.toolName.displayText) \(rule.argument.displayText)",
                provenance: .denylistRule))
        }
        if let rule = rules.first(where: { $0.effect == .allow && $0.matches(payload: payload) }) {
            return Match(rule: rule, decision: ApprovalDecision(
                verdict: .allow,
                reason: rule.reason ?? "Allowed by AgentHarness rule: \(rule.toolName.displayText) \(rule.argument.displayText)",
                provenance: .allowlistRule))
        }
        return nil
    }

    /// What else an "always allow" rule would have matched this session. Shown on the sheet before
    /// the operator commits to a rule, so a broad pattern is visible as broad.
    public func wouldAlsoMatch(rule: ApprovalRule, among history: [HookPayload]) -> [HookPayload] {
        history.filter { rule.matches(payload: $0) }
    }
}
