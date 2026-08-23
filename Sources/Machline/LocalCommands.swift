import HarnessCore
import SwiftUI

/// Commands Machline answers itself.
///
/// Claude Code's terminal client owns a set of commands — `/status`, `/theme`, `/login` and the
/// rest — that it never advertises over `stream-json`, because they act on the client rather than
/// on the agent. Sending one as a message would just put the literal text in the transcript. Where
/// the command describes something Machline knows, it is answered here instead.
enum LocalCommand: String, CaseIterable, Identifiable {
    var id: String { rawValue }

    case status
    case help
    case context
    case cost
    case permissions
    case mcp
    case skills
    case agents
    case tools
    case export
    case memory
    case clear

    /// What the completion list shows for it.
    var summary: String {
        switch self {
        case .status: return "session, model, approvals, and gate state"
        case .help: return "every command, local and from the CLI"
        case .context: return "context window occupancy"
        case .cost: return "spend and token accounting"
        case .permissions: return "approval mode and standing rules"
        case .mcp: return "MCP servers and tool grants"
        case .skills: return "skills this session loaded"
        case .agents: return "subagents this session can launch"
        case .tools: return "tools the session negotiated"
        case .export: return "write the transcript to a file"
        case .memory: return "open this project's CLAUDE.md"
        case .clear: return "empty the conversation, here and in the CLI"
        }
    }

    /// Where the answer lives.
    enum Destination {
        /// A tabbed report in a sheet.
        case report
        /// A section of the run panel, expanded and scrolled to.
        case panel(RunPanelSection)
        /// Something that happens rather than something to read.
        case action
    }

    var destination: Destination {
        switch self {
        case .status, .help, .skills, .agents, .tools, .mcp: return .report
        case .context, .cost: return .panel(.context)
        case .permissions: return .panel(.approvals)
        case .export, .memory, .clear: return .action
        }
    }

    static func parse(_ draft: String) -> LocalCommand? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let name = trimmed.dropFirst().prefix { !$0.isWhitespace }
        return LocalCommand(rawValue: String(name))
    }
}

/// What `/status` reports. Every value is read from the running session, the CLI, or the app's own
/// state — nothing here is inferred.
struct StatusReport {
    struct Row: Identifiable {
        let label: String
        let value: String
        var tint: Color = Theme.Colors.text
        var id: String { label }
    }

    struct Tab: Identifiable, Hashable {
        let title: String
        let icon: String
        var id: String { title }
    }

    let sections: [(tab: Tab, rows: [Row])]

    var tabs: [Tab] { sections.map(\.tab) }

    func rows(for tab: Tab) -> [Row] {
        sections.first { $0.tab == tab }?.rows ?? []
    }
}

extension AppModel {

    var statusReport: StatusReport {
        var session: [StatusReport.Row] = [
            .init(label: "State", value: sessionState.label),
            .init(label: "Project", value: workspace?.url.path ?? "—")
        ]
        if let id = liveSessionID { session.append(.init(label: "Session", value: id)) }
        if let resumedFrom {
            session.append(.init(label: "Resumed from", value: resumedFrom.title))
        }
        if let branch = git?.status?.branch.head {
            session.append(.init(label: "Branch", value: branch))
        }

        var model: [StatusReport.Row] = [
            .init(label: "Requested", value: modelLabel)
        ]
        model.append(.init(label: "Machline", value: appVersion))
        if let negotiated = graph.root?.capabilities?.model {
            model.append(.init(label: "In use", value: negotiated))
        }
        if let version = claudeCodeVersion {
            model.append(.init(label: "CLI", value: version))
        }
        if let mode = graph.root?.capabilities?.permissionMode {
            model.append(.init(label: "Permission mode", value: mode))
        }
        // `none` means the signed-in account is paying, which is what an operator on a
        // subscription expects. Anything else is API billing and is worth seeing.
        if let source = graph.root?.capabilities?.apiKeySource {
            model.append(.init(
                label: "Credential source",
                value: source == "none" ? "signed-in account" : source,
                tint: source == "none" ? Theme.Colors.text : Theme.Colors.warning))
        }

        // The two settings that decide what a session can reach. Both are stated plainly, in the
        // words used where they are configured.
        let gate: [StatusReport.Row] = [
            .init(
                label: "Machine config",
                value: isolation == .inherited ? "inherited from ~/.claude" : "sealed",
                tint: isolation == .inherited ? Theme.Colors.warning : Theme.Colors.text),
            .init(
                label: "Approvals",
                value: isGateDegraded ? "DEGRADED" : approvalSummary,
                tint: isGateDegraded
                    ? Theme.Colors.error
                    : (autoApproval.isEnabled ? Theme.Colors.warning : Theme.Colors.text)),
            .init(label: "Standing rules", value: "\(activeRules.count)"),
            .init(label: "Static denylist", value: "\(SessionConfiguration.defaultDenylist.count) patterns"),
            // Not ours, and it outranks us: a deny here refuses a call this gate has approved.
            .init(
                label: "Your ~/.claude denies",
                value: enforcedMachineConfiguration.denyRules.isEmpty
                    ? "none"
                    : "\(enforcedMachineConfiguration.denyRules.count) rule(s) — these override "
                        + "an approval",
                tint: enforcedMachineConfiguration.denyRules.isEmpty
                    ? Theme.Colors.text
                    : Theme.Colors.warning)
        ]

        var usage: [StatusReport.Row] = [
            .init(label: "Context", value: "\(contextUsedLabel) (\(Int(contextFraction * 100))%)"),
            .init(label: "Cost", value: costLabel),
            .init(label: "Agents", value: "\(agents.count)")
        ]
        if let turns = lastTurn?.numTurns { usage.append(.init(label: "Turns", value: "\(turns)")) }

        var capability: [StatusReport.Row] = [
            .init(label: "Commands", value: "\(slashCommands.count)"),
            .init(label: "Indexed files", value: "\(fileIndex.count)")
        ]
        if let tools = graph.root?.capabilities?.tools.count {
            capability.append(.init(label: "Tools", value: "\(tools)"))
        }
        if let servers = graph.root?.capabilities?.mcpServers.count {
            capability.append(.init(
                label: "MCP servers",
                value: isolation == .inherited && servers > 0
                    ? "\(servers) (ambient, not listed in the hub)"
                    : "\(servers)"))
        }

        var account: [StatusReport.Row] = []
        if let signedIn = accountStatus {
            account = [
                .init(
                    label: "Signed in",
                    value: signedIn.loggedIn ? "yes" : "no",
                    tint: signedIn.loggedIn ? Theme.Colors.text : Theme.Colors.error)
            ]
            if let email = signedIn.email { account.append(.init(label: "Account", value: email)) }
            if let org = signedIn.orgName { account.append(.init(label: "Organisation", value: org)) }
            if let plan = signedIn.subscriptionType {
                account.append(.init(label: "Plan", value: plan))
            }
            account.append(.init(
                label: "Billing",
                value: billing == .subscription
                    ? "subscription — API key variables removed"
                    : "environment — an API key variable would take over",
                tint: billing == .subscription ? Theme.Colors.text : Theme.Colors.warning))
            if let method = signedIn.authMethod {
                account.append(.init(label: "Auth method", value: method))
            }
            if let provider = signedIn.apiProvider {
                account.append(.init(label: "Provider", value: provider))
            }
        } else {
            account = [.init(
                label: "Account",
                value: isLoadingAccount ? "reading…" : "could not read `claude auth status`",
                tint: Theme.Colors.subtle)]
        }

        var diagnostics: [StatusReport.Row] = []
        if !malformedLines.isEmpty {
            // stdout is not strictly JSONL; a stray library log line is expected and skipped.
            diagnostics.append(.init(
                label: "Unparsed lines",
                value: "\(malformedLines.count) — skipped, not fatal",
                tint: Theme.Colors.warning))
            for line in malformedLines.suffix(5) {
                diagnostics.append(.init(label: "", value: line, tint: Theme.Colors.subtle))
            }
        }
        if !standardError.isEmpty {
            diagnostics.append(.init(
                label: "Standard error",
                value: "\(standardError.count) line(s)",
                tint: Theme.Colors.warning))
            for line in standardError.suffix(5) {
                diagnostics.append(.init(label: "", value: line, tint: Theme.Colors.subtle))
            }
        }
        if diagnostics.isEmpty {
            diagnostics = [.init(
                label: "", value: "Nothing unusual.", tint: Theme.Colors.subtle)]
        }

        return StatusReport(sections: [
            (.init(title: "Session", icon: "bubble.left.and.text.bubble.right"), session),
            (.init(title: "Model", icon: "cpu"), model),
            (.init(title: "Gate", icon: "lock.shield"), gate),
            (.init(title: "Usage", icon: "chart.bar"), usage),
            (.init(title: "Capability", icon: "wrench.and.screwdriver"), capability),
            (.init(title: "Account", icon: "person.crop.circle"), account),
            (.init(title: "Diagnostics", icon: "stethoscope"), diagnostics)
        ])
    }

    private var approvalSummary: String {
        guard autoApproval.isEnabled else { return "every call asks" }
        var parts: [String] = []
        if autoApproval.isFullAuto { return "auto mode — outward calls still ask" }
        if let ceiling = autoApproval.bashCeiling { parts.append("auto ≤ \(ceiling.label)") }
        if autoApproval.workspaceFileEdits { parts.append("auto project edits") }
        if autoApproval.holdsOutwardCommands { parts.append("outward calls ask") }
        return parts.joined(separator: ", ")
    }

    /// Runs a command Machline owns. Returns false when the draft is not one, so the caller sends
    /// it to the agent as usual.
    func runLocalCommand() -> Bool {
        guard let command = LocalCommand.parse(promptDraft) else { return false }

        switch command.destination {
        case .report:
            reportCommand = command
            if command == .status { refreshAccountStatus() }
        case .panel(let section):
            // Answered in the panel rather than in a sheet: the panel is where the controls are,
            // so a read-only copy of it would be a dead end.
            focusedPanelSection = section
        case .action:
            switch command {
            case .export: exportTranscript()
            case .memory: openProjectMemory()
            case .clear: clearConversation()
            default: break
            }
        }

        recordHistory(promptDraft.trimmingCharacters(in: .whitespacesAndNewlines))
        promptDraft = ""
        dismissCompletions()
        return true
    }

    /// Writes the visible conversation to a Markdown file and reveals it.
    private func exportTranscript() {
        guard let workspace else { return }
        var blocks: [String] = ["# \(workspace.name)"]
        if let session = liveSessionID { blocks.append("Session `\(session)`") }

        for entry in replay {
            switch entry.kind {
            case .user(let text): blocks.append("## You\n\n\(text)")
            case .assistant(let text): blocks.append("## Agent\n\n\(text)")
            case .thinking(let text): blocks.append("> \(text)")
            case .toolCall(let name, let detail):
                blocks.append("### \(name)\n\n```\n\(detail)\n```")
            case .toolResult(let text, let isError):
                blocks.append("\(isError ? "**Blocked**" : "Result")\n\n```\n\(text)\n```")
            }
        }
        for node in agents {
            for entry in node.transcript {
                switch entry {
                case .text(_, _, let text): blocks.append("## Agent\n\n\(text)")
                case .steerDelivered(_, let text), .steerQueued(_, let text):
                    blocks.append("## You\n\n\(text)")
                case .steerDropped(_, let text):
                    blocks.append("## You (not delivered)\n\n\(text)")
                case .toolCall(_, let use):
                    blocks.append("### \(use.name)\n\n```\n\(use.bashCommand ?? "")\n```")
                default: break
                }
            }
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(workspace.name)-transcript.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? blocks.joined(separator: "\n\n").write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Opens the project's `CLAUDE.md` in whatever handles Markdown.
    private func openProjectMemory() {
        guard let url = fileURL(for: "CLAUDE.md") else {
            archiveError = "This project has no CLAUDE.md."
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// The report a `/`-command asked for.
    func report(for command: LocalCommand) -> StatusReport {
        switch command {
        case .help: return helpReport
        case .mcp: return mcpReport
        case .skills: return listReport(
            title: "Skills", icon: "sparkles",
            items: graph.root?.capabilities?.skills ?? [],
            empty: "This session loaded no skills.")
        case .agents: return listReport(
            title: "Agents", icon: "person.2",
            items: graph.root?.capabilities?.agents ?? [],
            empty: "This session declares no subagents.")
        case .tools: return listReport(
            title: "Tools", icon: "wrench.and.screwdriver",
            items: graph.root?.capabilities?.tools ?? [],
            empty: "No handshake yet — start a session.")
        default: return statusReport
        }
    }

    private func listReport(
        title: String, icon: String, items: [String], empty: String
    ) -> StatusReport {
        guard !items.isEmpty else {
            return StatusReport(sections: [(
                .init(title: title, icon: icon),
                [.init(label: "", value: empty, tint: Theme.Colors.subtle)])])
        }
        return StatusReport(sections: [(
            .init(title: "\(title) · \(items.count)", icon: icon),
            items.map { .init(label: "", value: $0) })])
    }

    /// The MCP servers this session negotiated.
    ///
    /// A report rather than a panel: per-tool grants only mean anything in sealed mode, and
    /// sessions inherit `~/.claude` by default — where servers join unannounced and a grant list
    /// would be describing a surface it does not control.
    private var mcpReport: StatusReport {
        guard let drawer = mcp.drawer, !drawer.groups.isEmpty else {
            return StatusReport(sections: [(
                .init(title: "MCP", icon: "puzzlepiece.extension"),
                [.init(
                    label: "",
                    value: isolation == .inherited
                        ? "No servers reported yet. In inherited mode they connect as the CLI "
                            + "configures them, without passing through Machline."
                        : "No servers. This session is sealed, so only servers Machline "
                            + "configured could connect.",
                    tint: Theme.Colors.subtle)])])
        }

        return StatusReport(sections: drawer.groups.map { group in
            (
                .init(title: group.serverName, icon: "puzzlepiece.extension"),
                [StatusReport.Row(
                    label: "status",
                    value: group.connectionStatus,
                    tint: group.connectionStatus == "connected"
                        ? Theme.Colors.success
                        : Theme.Colors.warning)]
                    + group.entries.map { entry in
                        StatusReport.Row(
                            label: "",
                            value: entry.tool.toolName
                                + (entry.requiresConfirmation ? "  · write-capable" : ""))
                    }
            )
        })
    }

    /// Everything typing `/` can reach, split by who answers it.
    private var helpReport: StatusReport {
        let local = LocalCommand.allCases.map {
            StatusReport.Row(label: "/\($0.rawValue)", value: $0.summary)
        }
        let advertised = slashCommands.sorted().map {
            StatusReport.Row(label: "/\($0)", value: "", tint: Theme.Colors.muted)
        }
        return StatusReport(sections: [
            (.init(title: "Machline · \(local.count)", icon: "app.badge"), local),
            (.init(title: "Claude Code · \(advertised.count)", icon: "terminal"), advertised)
        ])
    }
}

/// Which run-panel section a command wants opened.
enum RunPanelSection: String, Hashable {
    case context, approvals
}

struct StatusSheet: View {
    @Bindable var model: AppModel
    let command: LocalCommand
    @Environment(\.dismiss) private var dismiss

    @State private var selected: StatusReport.Tab?

    private var report: StatusReport { model.report(for: command) }
    private var current: StatusReport.Tab { selected ?? report.tabs[0] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline(color: Theme.Colors.border)
            tabBar
            Hairline(color: Theme.Colors.border)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    ForEach(report.rows(for: current)) { row in
                        HStack(alignment: .top, spacing: Theme.Space.md) {
                            if !row.label.isEmpty {
                                Text(row.label)
                                    .font(Theme.Typography.meta)
                                    .foregroundStyle(Theme.Colors.subtle)
                                    .frame(width: 140, alignment: .leading)
                            }
                            Text(row.value)
                                .font(Theme.Typography.monoMeta)
                                .foregroundStyle(row.tint)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(Theme.Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 600, height: 480)
        .background(Theme.Colors.canvas)
        .selectableTextTint()
        .onExitCommand { dismiss() }
    }

    private var header: some View {
        HStack {
            Text("/\(command.rawValue)")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Colors.textStrong)
            Spacer()
            // The whole report, not just the visible tab — a copied status that omitted five of
            // six tabs would be worse than useless in a bug report.
            CopyButton(text: plainText, help: "Copy the whole report")
            IconButton(systemName: "xmark", help: "Close (esc)") { dismiss() }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(report.tabs) { tab in
                    Button { selected = tab } label: {
                        HStack(spacing: Theme.Space.xs) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 10))
                            Text(tab.title)
                                .font(Theme.Typography.control)
                        }
                        .foregroundStyle(tab == current
                            ? Theme.Colors.textStrong
                            : Theme.Colors.muted)
                        .padding(.horizontal, Theme.Space.md)
                        .frame(height: 32)
                        .background(tab == current ? Theme.Colors.panel : .clear)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(tab == current ? Theme.Colors.accent : .clear)
                                .frame(height: 2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var plainText: String {
        report.sections.map { section in
            ([section.tab.title] + section.rows.map { "  \($0.label): \($0.value)" })
                .joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }
}
