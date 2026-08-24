import Foundation

/// The permission rules the CLI reads from the operator's own `~/.claude` configuration.
///
/// These matter because they are *not ours*. In `inherited` isolation the CLI loads the machine's
/// settings, and a `permissions.deny` entry there beats an allow from our approval hook: the
/// operator clicks Approve, the gate answers `allow`, and the command is still refused — by the
/// runtime, with a message that reads as the system blocking it for no stated reason.
///
/// Reading them here lets the interface say so up front, instead of leaving an approval that
/// visibly did nothing.
public struct MachineConfiguration: Sendable, Hashable {

    /// `permissions.deny` — patterns the runtime refuses whatever the gate says.
    public let denyRules: [String]
    /// `permissions.allow` — patterns the runtime lets through without prompting. Our hook still
    /// sees them, so these do not weaken the gate; they only mean the runtime would not have asked.
    public let allowRules: [String]
    /// `PreToolUse` hooks the operator has installed, which run alongside ours and can deny on
    /// their own.
    public let preToolUseHookCount: Int

    public static let none = MachineConfiguration(
        denyRules: [], allowRules: [], preToolUseHookCount: 0)

    public init(denyRules: [String], allowRules: [String], preToolUseHookCount: Int) {
        self.denyRules = denyRules
        self.allowRules = allowRules
        self.preToolUseHookCount = preToolUseHookCount
    }

    public var isEmpty: Bool {
        denyRules.isEmpty && allowRules.isEmpty && preToolUseHookCount == 0
    }

    /// `~/.claude/settings.json`, the file the CLI reads for user-level settings.
    public static var defaultSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /// Reads what the machine would impose. A missing or unreadable file is not an error — it just
    /// means there is nothing to warn about.
    public static func read(from url: URL = MachineConfiguration.defaultSettingsURL) -> MachineConfiguration {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return .none }
        return parse(root)
    }

    static func parse(_ root: JSONValue) -> MachineConfiguration {
        func strings(_ value: JSONValue?) -> [String] {
            guard case .array(let entries)? = value else { return [] }
            return entries.compactMap(\.stringValue)
        }

        let permissions = root["permissions"]
        var hooks = 0
        if case .array(let matchers)? = root["hooks"]?["PreToolUse"] {
            hooks = matchers.reduce(0) { total, matcher in
                guard case .array(let commands)? = matcher["hooks"] else { return total }
                return total + commands.count
            }
        }

        return MachineConfiguration(
            denyRules: strings(permissions?["deny"]),
            allowRules: strings(permissions?["allow"]),
            preToolUseHookCount: hooks)
    }

    /// Whether a command looks like something the machine's denylist would refuse.
    ///
    /// Advisory, exactly like `RiskClassifier`: the runtime owns the real matching, and this only
    /// understands the two rule shapes that cover almost every entry — `Bash(prefix:*)` and
    /// `Bash(exact command)`. It exists so the approval sheet can warn before a click that will not
    /// take, never to decide anything.
    public func deniesBashCommand(_ command: String) -> String? {
        Self.match(command, against: denyRules)
    }

    /// The machine allowlist entry covering this command, if any.
    ///
    /// The CLI would not have prompted for these. Honouring them is what keeps the gate from being
    /// stricter than the thing it is wrapping — an operator who has already said `ls` is fine should
    /// not be asked again because they ran it in this window.
    public func allowsBashCommand(_ command: String) -> String? {
        Self.match(command, against: allowRules)
    }

    private static func match(_ command: String, against rules: [String]) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for rule in rules {
            guard rule.hasPrefix("Bash("), rule.hasSuffix(")") else { continue }
            let pattern = String(rule.dropFirst("Bash(".count).dropLast())
            if pattern.hasSuffix(":*") {
                let prefix = String(pattern.dropLast(2))
                if !prefix.isEmpty, trimmed == prefix || trimmed.hasPrefix(prefix + " ") { return rule }
            } else if pattern.hasSuffix("*") {
                let prefix = String(pattern.dropLast()).trimmingCharacters(in: .whitespaces)
                if !prefix.isEmpty, trimmed.hasPrefix(prefix) { return rule }
            } else if trimmed == pattern {
                return rule
            }
        }
        return nil
    }
}
