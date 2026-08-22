import HarnessCore
import SwiftUI

/// What the gate answers on its own, and the rules already standing.
///
/// The rules list exists because "Always allow" on the sheet used to create state nothing ever
/// showed again. A standing allow rule is a security decision; it has to be inspectable and
/// revocable.
struct ApprovalsPanel: View {
    @Bindable var model: AppModel

    /// The machine's rule list is folded away until asked for: it is long, it is not ours, and the
    /// headline above it already says what it does.
    @State private var isMachineListExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            isolationSection
            Hairline()
            autoModeSection
            Hairline()
            modeSection
            Hairline()
            machineSection
            Hairline()
            rulesSection
            Hairline()
            answeredSection
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

    // MARK: - Auto mode

    /// One switch for the common case: run the local work, stop at the door.
    ///
    /// The two controls below still exist for an operator who wants a different line, but nobody
    /// should have to assemble "get on with it" out of a ceiling and a toggle.
    private var autoModeSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            SwitchToggle(isOn: Binding(
                get: { model.autoApproval.isFullAuto },
                set: { model.autoApproval = $0 ? .auto : .manual })
            ) {
                HStack(spacing: Theme.Space.sm) {
                    Text("Auto mode")
                        .font(Theme.Typography.control)
                        .foregroundStyle(Theme.Colors.text)
                    if model.autoApproval.isFullAuto {
                        Text("on")
                            .font(Theme.Typography.monoMeta)
                            .foregroundStyle(Theme.Colors.warning)
                    }
                }
            }

            Text(model.autoApproval.isFullAuto
                ? "Local work runs unasked. Anything that leaves this machine still waits for you — "
                    + "push, publish, release, deploy — and so does anything privileged, "
                    + "destructive, or writing outside the project."
                : "Runs local work without asking and holds back everything that leaves this "
                    + "machine. Turning it on sets the two controls below.")
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.Colors.subtle)
                .fixedSize(horizontal: false, vertical: true)

            if model.autoApproval.isEnabled {
                SwitchToggle(isOn: Binding(
                    get: { model.autoApproval.holdsOutwardCommands },
                    set: { hold in
                        model.autoApproval = AutoApproval(
                            bashCeiling: model.autoApproval.bashCeiling,
                            workspaceFileEdits: model.autoApproval.workspaceFileEdits,
                            holdsOutwardCommands: hold)
                    })
                ) {
                    Text("Always ask before anything leaves this machine")
                        .font(Theme.Typography.control)
                        .foregroundStyle(Theme.Colors.text)
                }

                Text(model.autoApproval.holdsOutwardCommands
                    ? "git push, git commit, npm publish, docker push, gh release, kubectl apply, "
                        + "terraform apply, scp, rsync — held back whatever the ceiling says."
                    : "Nothing is held back: at the network ceiling a push or a publish runs "
                        + "unread.")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(model.autoApproval.holdsOutwardCommands
                        ? Theme.Colors.subtle
                        : Theme.Colors.error)
                    .fixedSize(horizontal: false, vertical: true)
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
                              detail: "also curl, pipes, and chained commands")
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
                    bashCeiling: model.autoApproval.bashCeiling,
                    workspaceFileEdits: $0,
                    holdsOutwardCommands: model.autoApproval.holdsOutwardCommands) })
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
            workspaceFileEdits: model.autoApproval.workspaceFileEdits,
            holdsOutwardCommands: model.autoApproval.holdsOutwardCommands)
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
            return "Also runs commands that reach the network or are chained — curl, pipes, and "
                + "substitutions — without asking."
        case .privileged, .destructive:
            return "Above the permitted ceiling."
        }
    }

    // MARK: - Machine rules

    /// The rules that are not ours.
    ///
    /// With machine config inherited, the CLI also reads `~/.claude/settings.json`, and a `deny`
    /// there outranks this gate: approve the command here and the runtime refuses it anyway, with
    /// nothing on screen explaining why.
    ///
    /// Folded away by default, and never just a list. Seventeen red lines nobody can act on is a
    /// wall, not an explanation — so the headline says what they do, and the two things that
    /// actually change the outcome sit next to it: edit them where they live, or run sessions
    /// sealed so they do not load at all.
    @ViewBuilder
    private var machineSection: some View {
        let configuration = model.enforcedMachineConfiguration
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Text("From ~/.claude")
                    .font(Theme.Typography.control)
                    .foregroundStyle(Theme.Colors.muted)
                Spacer(minLength: Theme.Space.sm)
                if !configuration.denyRules.isEmpty {
                    Text("\(configuration.denyRules.count) deny")
                        .font(Theme.Typography.monoMeta)
                        .foregroundStyle(Theme.Colors.error)
                    Button {
                        withAnimation(.easeOut(duration: 0.12)) { isMachineListExpanded.toggle() }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.Colors.subtle)
                            .rotationEffect(.degrees(isMachineListExpanded ? 90 : 0))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isMachineListExpanded ? "Hide the rules" : "Show the rules")
                }
            }

            if model.isolation == .sealed {
                Text("Sealed sessions read none of it, so only the rules above apply.")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.subtle)
                    .fixedSize(horizontal: false, vertical: true)
            } else if configuration.isEmpty {
                Text("Your Claude configuration adds no permission rules of its own.")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.subtle)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if !configuration.denyRules.isEmpty {
                    Text("\(configuration.denyRules.count) rule(s) here outrank this gate: "
                        + "approving one of them still ends in the runtime refusing it, and the "
                        + "agent is told the system blocked it.")
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.warning)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: Theme.Space.sm) {
                        QuietButton(title: "Edit in settings.json") {
                            model.openMachineSettings()
                        }
                        QuietButton(title: "Reload") { model.reloadMachineConfiguration() }
                        QuietButton(title: "Run sealed") { model.isolation = .sealed }
                        Spacer(minLength: 0)
                    }

                    Text("Machline does not rewrite that file — it is shared with every other "
                        + "Claude session on this machine. “Run sealed” leaves it alone and stops "
                        + "loading it instead, from the next session on.")
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.subtle)
                        .fixedSize(horizontal: false, vertical: true)

                    if isMachineListExpanded {
                        ForEach(configuration.denyRules, id: \.self) { rule in
                            HStack(spacing: Theme.Space.sm) {
                                Text("deny")
                                    .font(Theme.Typography.monoMeta)
                                    .foregroundStyle(Theme.Colors.error)
                                Text(rule)
                                    .font(Theme.Typography.monoMeta)
                                    .foregroundStyle(Theme.Colors.text)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                                IconButton(systemName: "doc.on.doc", help: "Copy this rule") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(rule, forType: .string)
                                }
                            }
                        }
                    }
                }

                if configuration.preToolUseHookCount > 0 {
                    Text("\(configuration.preToolUseHookCount) of your own PreToolUse hook(s) run "
                        + "alongside this gate and can refuse a call on their own.")
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.subtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Answered without you

    /// What the gate decided on its own, most recent first.
    ///
    /// Auto mode is only tolerable if what it did is visible where it was switched on, rather than
    /// scrolled past in a rail somewhere. Each row carries the decision's own reason.
    @ViewBuilder
    private var answeredSection: some View {
        let answered = model.auditLog.filter { $0.provenance == .autoApproved }.prefix(8)
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text("Answered automatically")
                    .font(Theme.Typography.control)
                    .foregroundStyle(Theme.Colors.muted)
                Spacer(minLength: Theme.Space.sm)
                if !answered.isEmpty {
                    Text("\(answered.count)")
                        .font(Theme.Typography.monoMeta)
                        .foregroundStyle(Theme.Colors.subtle)
                }
            }

            if answered.isEmpty {
                Text(model.autoApproval.isEnabled
                    ? "Nothing yet. Calls answered without you will be listed here."
                    : "Nothing is answered without you.")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.subtle)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(answered) { entry in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: Theme.Space.sm) {
                            Text("auto")
                                .font(Theme.Typography.monoMeta)
                                .foregroundStyle(Theme.Colors.warning)
                            Text(entry.summary)
                                .font(Theme.Typography.monoMeta)
                                .foregroundStyle(Theme.Colors.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        Text(entry.reason)
                            .font(Theme.Typography.meta)
                            .foregroundStyle(Theme.Colors.subtle)
                            .lineLimit(2)
                    }
                }
            }
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
