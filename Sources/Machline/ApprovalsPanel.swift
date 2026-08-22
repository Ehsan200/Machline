import HarnessCore
import SwiftUI

/// What the gate answers on its own, and the rules already standing.
///
/// The rules list exists because "Always allow" on the sheet used to create state nothing ever
/// showed again. A standing allow rule is a security decision; it has to be inspectable and
/// revocable.
struct ApprovalsPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            isolationSection
            Hairline()
            modeSection
            Hairline()
            rulesSection
            Hairline()
            caveat
        }
        .padding(.horizontal, Theme.Space.railPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Isolation

    /// What a session inherits from `~/.claude`.
    ///
    /// This is the widest control in the app, so it says plainly what each mode gives up rather
    /// than leaving the operator to infer it from a switch label.
    private var isolationSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text("Machine config")
                    .font(Theme.Typography.control)
                    .foregroundStyle(Theme.Colors.muted)
                Spacer(minLength: Theme.Space.sm)
                Select(
                    selection: $model.isolation,
                    options: [
                        .init(.inherited, label: "inherited",
                              detail: "your commands, skills, CLAUDE.md, hooks, and MCP servers"),
                        .init(.sealed, label: "sealed",
                              detail: "nothing from ~/.claude reaches the session")
                    ],
                    tint: model.isolation == .inherited
                        ? Theme.Colors.warning
                        : Theme.Colors.text)
            }

            Text(model.isolation == .inherited
                ? "Your commands, skills, CLAUDE.md, hooks, and MCP servers all load, exactly as "
                    + "they would in a terminal. Ambient MCP servers join without appearing in the "
                    + "MCP hub, so per-tool grants do not apply."
                : "Nothing from ~/.claude reaches the session. The tool surface is known in "
                    + "advance and per-tool MCP grants apply.")
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.Colors.subtle)
                .fixedSize(horizontal: false, vertical: true)

            if model.sessionState.isRunning {
                Text("Applies to the next session — this one already launched.")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.warning)
            }
        }
    }

    // MARK: - Mode

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text("Shell commands")
                    .font(Theme.Typography.control)
                    .foregroundStyle(Theme.Colors.muted)
                Spacer(minLength: Theme.Space.sm)
                Select(
                    selection: Binding(
                        get: { model.autoApproval.bashCeiling.map(\.label) ?? "" },
                        set: { setCeiling(RiskClassifier.Level.named($0)) }),
                    options: [
                        .init("", label: "ask", detail: "every command waits for you"),
                        .init("benign", label: "auto ≤ benign",
                              detail: "plain commands with no risk signals"),
                        .init("network", label: "auto ≤ network",
                              detail: "also curl, git push, pipes, and chained commands")
                    ],
                    tint: model.autoApproval.bashCeiling == nil
                        ? Theme.Colors.text
                        : Theme.Colors.warning)
            }

            Text(ceilingExplanation)
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.Colors.subtle)
                .fixedSize(horizontal: false, vertical: true)

            SwitchToggle(isOn: Binding(
                get: { model.autoApproval.workspaceFileEdits },
                set: { model.autoApproval = AutoApproval(
                    bashCeiling: model.autoApproval.bashCeiling, workspaceFileEdits: $0) })
            ) {
                Text("Auto-approve edits inside the project")
                    .font(Theme.Typography.control)
                    .foregroundStyle(Theme.Colors.text)
            }

            Text("Writes outside the project directory are always asked about. Edits inside it "
                + "show up in Changes and can be discarded from the Git workbench.")
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.Colors.subtle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func setCeiling(_ level: RiskClassifier.Level?) {
        model.autoApproval = AutoApproval(
            bashCeiling: level,
            workspaceFileEdits: model.autoApproval.workspaceFileEdits)
    }

    private var ceilingLabel: String {
        switch model.autoApproval.bashCeiling {
        case .none: return "ask"
        case .some(let level): return "auto ≤ \(level.label)"
        }
    }

    private var ceilingExplanation: String {
        switch model.autoApproval.bashCeiling {
        case .none:
            return "Every command waits for you."
        case .benign:
            return "Runs plain commands with no risk signals. Anything piped, chained, "
                + "substituted, or matching a known pattern still waits for you."
        case .network:
            return "Also runs commands that reach the network or are chained — curl, git push, "
                + "pipes, and substitutions — without asking."
        case .privileged, .destructive:
            return "Above the permitted ceiling."
        }
    }

    // MARK: - Rules

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text("Standing rules")
                    .font(Theme.Typography.control)
                    .foregroundStyle(Theme.Colors.muted)
                Spacer(minLength: Theme.Space.sm)
                if !model.activeRules.isEmpty {
                    Text("\(model.activeRules.count)")
                        .font(Theme.Typography.monoMeta)
                        .foregroundStyle(Theme.Colors.subtle)
                }
            }

            if model.activeRules.isEmpty {
                Text(model.session == nil
                    ? "Rules live for the session. Start one to add them."
                    : "None. “Always allow” on an approval adds one here.")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.subtle)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.activeRules) { rule in
                    RuleRow(rule: rule) { model.removeRule(rule) }
                }
            }
        }
    }

    // MARK: - Caveat

    /// The classifier says of itself that it is not a security boundary. An operator turning auto
    /// mode on deserves to read that where the switch is, not in a source comment.
    private var caveat: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(Theme.Colors.subtle)
            Text("Risk levels are pattern matching, not analysis — an unrecognised command reads "
                + "as benign. The `--disallowedTools` denylist still blocks rm, sudo, and dd "
                + "regardless of this setting, and every auto-approval is recorded in Recent "
                + "approvals.")
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.Colors.subtle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct RuleRow: View {
    let rule: ApprovalRule
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Text(rule.effect == .allow ? "allow" : "deny")
                .font(Theme.Typography.monoMeta)
                .foregroundStyle(rule.effect == .allow
                    ? Theme.Colors.success
                    : Theme.Colors.error)

            Text("\(rule.toolName.displayText) \(rule.argument.displayText)")
                .font(Theme.Typography.monoMeta)
                .foregroundStyle(Theme.Colors.text)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: Theme.Space.sm)

            Text(rule.scope.rawValue)
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.Colors.subtle)

            IconButton(systemName: "xmark", help: "Remove this rule", action: onRemove)
        }
    }
}
