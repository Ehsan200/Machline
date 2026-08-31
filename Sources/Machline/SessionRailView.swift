import HarnessCore
import SwiftUI

/// The left rail: two utility rows, the live agent hierarchy grouped under its project, and a
/// quiet approvals footer.
///
/// The project name is carried once by the group heading rather than repeated in every row, and
/// there is no standalone product label — the window already provides identity.
struct SessionRailView: View {
    @Bindable var model: AppModel
    @Bindable var window: WindowModel

    @State private var search = ""
    @State private var isSearchFocused = false
    @State private var isProjectExpanded = true
    @State private var isAuditExpanded = false
    @State private var isArchiveExpanded = false
    @State private var pendingDelete: HistoricalSession?
    /// Groups the operator has toggled away from their default state.
    @State private var toggledGroups: Set<SessionAge> = []
    @State private var renaming: HistoricalSession?
    @State private var renameDraft = "" 

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            utilityHeader
            Hairline()

            // What is running, at the top of the rail where the eye already is. This was in the
            // run panel behind a heading that said "no agent is currently working" most of the
            // time, which is exactly when nobody looks at it.
            if !model.activeAgents.isEmpty {
                workingStrip
                Hairline()
            }

            if model.workspace == nil {
                emptyState
            } else {
                sessionList
            }

            if !model.archivedSessions.isEmpty {
                Hairline()
                archivedFooter
            }

            Hairline()
            auditFooter
        }
        .background(Theme.Colors.panel)
        // Another tab archiving or deleting a conversation leaves this list offering one that is
        // no longer there. Each tab holds its own copy, so each has to be told.
        .onChange(of: LiveSessions.shared.historyRevision) { model.refreshHistory() }
        .alert(
            "Delete this conversation?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let pendingDelete { model.deleteSession(pendingDelete) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            // Archiving is the reversible option, so the alert points at it rather than only
            // warning about the irreversible one.
            Text("The transcript is removed from disk permanently. Archive it instead to keep it "
                + "without listing it.")
        }
        .alert(
            "Could not change that conversation",
            isPresented: Binding(
                get: { model.archiveError != nil },
                set: { if !$0 { model.archiveError = nil } })
        ) {
            Button("OK", role: .cancel) { model.archiveError = nil }
        } message: {
            Text(model.archiveError ?? "")
        }
    }

    /// Archived conversations: quiet, collapsed, and restorable.
    private var archivedFooter: some View {
        DisclosureSection(
            title: "Archived",
            count: "· \(model.archivedSessions.count)",
            isExpanded: $isArchiveExpanded
        ) {
            // Capped *and* scrollable. A height cap on its own does not bound a list, it hides
            // the end of one — the rows past 220pt were simply unreachable.
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    ForEach(model.archivedSessions) { session in
                    HStack(spacing: Theme.Space.sm) {
                        Text(session.title)
                            .font(Theme.Typography.meta)
                            .foregroundStyle(Theme.Colors.muted)
                            .lineLimit(1)
                        Spacer(minLength: Theme.Space.sm)
                        Button("Restore") { model.restoreSession(session) }
                            .buttonStyle(.plain)
                            .font(Theme.Typography.meta)
                            .foregroundStyle(Theme.Colors.link)
                        IconButton(
                            systemName: "trash", help: "Delete permanently",
                            tint: Theme.Colors.error
                        ) {
                            pendingDelete = session
                        }
                    }
                    }
                }
                .padding(.horizontal, Theme.Space.railPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
        }
        .frame(maxHeight: isArchiveExpanded ? 220 : nil)
    }

    /// The agents doing something right now.
    private var workingStrip: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ForEach(model.activeAgents) { node in
                Button {
                    model.select(agentID: node.id)
                } label: {
                    HStack(spacing: Theme.Space.sm) {
                        Spinner(size: 9, color: AgentStateDot.tint(for: node.state))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(node.title)
                                .font(Theme.Typography.controlMedium)
                                .foregroundStyle(Theme.Colors.textStrong)
                                .lineLimit(1)
                            Text(node.state.label)
                                .font(Theme.Typography.meta)
                                .foregroundStyle(Theme.Colors.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Space.railPadding)
        .padding(.vertical, Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.accent.opacity(0.07))
    }

    // MARK: - Utility header

    private var utilityHeader: some View {
        VStack(spacing: 0) {
            searchRow
            projectRow
        }
    }

    /// The whole row is the search affordance, not just the icon.
    private var searchRow: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Colors.subtle)

            TextField("Search agents", text: $search)
                .textFieldStyle(.plain)
                .font(Theme.Typography.control)
                .foregroundStyle(Theme.Colors.text)

            if !search.isEmpty {
                IconButton(systemName: "xmark.circle.fill", help: "Clear search") {
                    search = ""
                }
            }

            IconButton(
                systemName: "square.and.pencil",
                help: "New session tab",
                tint: model.workspace == nil ? Theme.Colors.subtle : Theme.Colors.muted
            ) {
                window.openBlankTab()
            }
            .disabled(model.workspace == nil)
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: Theme.Layout.utilityRowHeight)
        .contentShape(Rectangle())
    }

    /// The project selector switches between projects already opened and offers the open panel for
    /// a new one. It does not introduce a second navigation structure.
    private var projectRow: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "folder")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Colors.subtle)

            Select(
                selection: Binding(
                    get: { model.workspace?.url.standardizedFileURL.path ?? "" },
                    set: { path in
                        guard !path.isEmpty else { return }
                        adopt(workspace: URL(fileURLWithPath: path))
                    }),
                options: projectOptions,
                placeholder: "No project",
                isTechnical: false,
                // Always searchable: the list runs to every project on the machine.
                showsSearch: true,
                onCommandSelect: { path in
                    openInNewWindow(URL(fileURLWithPath: path))
                },
                commandHint: "⌘-click to open in a new window · right-click to remove",
                onRemove: { path in
                    model.removeProject(URL(fileURLWithPath: path))
                },
                removeTitle: "Remove from Machline")

            Spacer(minLength: 0)

            IconButton(systemName: "plus", help: "Open a project (⌘O)") {
                openProject()
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: Theme.Layout.utilityRowHeight)
    }

    /// The parent directory disambiguates two projects sharing a leaf name, which is common
    /// enough (`web/api`, `mobile/api`) to be worth the second line.
    private var projectOptions: [Select<String>.Option] {
        (model.knownProjects.isEmpty ? model.recentProjects : model.knownProjects).map { url in
            .init(
                url.standardizedFileURL.path,
                label: url.lastPathComponent,
                detail: url.deletingLastPathComponent().path)
        }
    }

    // MARK: - Agent list

    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(visibleGroups) { group in
                    Section {
                        if isExpanded(group.age) {
                            ForEach(group.sessions) { session in
                                SessionRow(
                                    session: session,
                                    title: model.title(for: session),
                                    isLive: session.id.lowercased() == liveSessionID,
                                    liveState: model.sessionState,
                                    relativeTime: session.lastActivityAt.relativeLabel,
                                    isRenaming: renaming?.id == session.id,
                                    draftName: $renameDraft,
                                    onOpen: { open(session) },
                                    onRename: { beginRename(session) },
                                    onCommitRename: { commitRename(session) },
                                    onArchive: { model.archiveSession(session) },
                                    onDelete: { pendingDelete = session })
                            }
                        }
                    } header: {
                        groupHeader(group)
                    }
                }

                if visibleGroups.isEmpty {
                    HStack(spacing: Theme.Space.sm) {
                        if model.isLoadingHistory {
                            Spinner(size: 10, color: Theme.Colors.subtle)
                        }
                        Text(model.isLoadingHistory ? "Reading history…" : "No sessions yet.")
                            .font(Theme.Typography.meta)
                            .foregroundStyle(Theme.Colors.subtle)
                    }
                    .padding(.horizontal, Theme.Space.railPadding)
                    .padding(.vertical, Theme.Space.sm)
                }

                // The agent tree belongs to the running session only; a recorded session has no
                // live agents to show.
                if model.agents.count > 1 {
                    SectionLabel("Agents", trailing: "\(model.agents.count)")
                        .padding(.horizontal, Theme.Space.railPadding)
                        .padding(.top, Theme.Space.lg)
                        .padding(.bottom, Theme.Space.xs)

                    ForEach(filteredAgents) { node in
                        AgentRow(
                            node: node,
                            depth: model.depth(of: node),
                            isSelected: model.selectedAgent?.id == node.id,
                            relativeTime: model.relativeUpdateTime(for: node)
                        ) {
                            model.select(agentID: node.id)
                        }
                    }
                }
            }
            .padding(.vertical, Theme.Space.sm)
        }
        .scrollContentBackground(.hidden)
    }

    /// Today's work is open; older groups are collapsed until the operator opens them.
    ///
    /// The set records which groups were *toggled away* from their default, so a group's default
    /// stays meaningful rather than being overwritten by the first interaction anywhere in the rail.
    private func isExpanded(_ age: SessionAge) -> Bool {
        // A search is a request to see matches wherever they are, so it opens every group.
        if !search.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        return toggledGroups.contains(age) ? !age.isExpandedByDefault : age.isExpandedByDefault
    }

    private func toggle(_ age: SessionAge) {
        if toggledGroups.contains(age) {
            toggledGroups.remove(age)
        } else {
            toggledGroups.insert(age)
        }
    }

    private func groupHeader(_ group: SessionGroup) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { toggle(group.age) }
        } label: {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Colors.subtle)
                    .rotationEffect(.degrees(isExpanded(group.age) ? 90 : 0))
                Text(group.age.title.uppercased())
                    .font(Theme.Typography.sectionLabel)
                    .tracking(0.6)
                    .foregroundStyle(group.age == .today
                        ? Theme.Colors.muted
                        : Theme.Colors.subtle)
                Text("\(group.sessions.count)")
                    .font(Theme.Typography.monoMeta)
                    .foregroundStyle(Theme.Colors.subtle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.railPadding)
            .padding(.vertical, Theme.Space.sm)
            .background(Theme.Colors.panel)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var visibleGroups: [SessionGroup] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return model.sessionGroups }
        return model.sessionGroups.compactMap { group in
            let matches = group.sessions.filter {
                model.title(for: $0).lowercased().contains(query)
            }
            return matches.isEmpty ? nil : SessionGroup(age: group.age, sessions: matches)
        }
    }

    /// The one row this tab is running, resolved once for the whole list.
    ///
    /// Asking each row to work it out invited more than one to answer yes. A single value computed
    /// per render makes multiple highlights impossible rather than merely unlikely — and it is the
    /// current tab's session, so other tabs' sessions are not marked here.
    private var liveSessionID: String? {
        guard model.session != nil else { return nil }
        return model.liveSessionID
    }

    private func beginRename(_ session: HistoricalSession) {
        renameDraft = model.hasCustomTitle(session) ? model.title(for: session) : ""
        renaming = session
    }

    private func commitRename(_ session: HistoricalSession) {
        model.rename(session, to: renameDraft)
        renaming = nil
        renameDraft = ""
    }

    /// Opens a session.
    ///
    /// Each session gets its own window, so opening one never disturbs another that is running.
    /// The exception is a window with nothing in it yet, which adopts the session in place rather
    /// than leaving an empty window behind.
    private func open(_ session: HistoricalSession) {
        guard let workspace = model.workspace?.url else { return }
        // A tab already showing this session is raised rather than opened twice; an untouched tab
        // is reused rather than left behind.
        window.open(session, in: workspace)
    }

    /// Picks a project and opens it. A window already holding one gets a new window rather than
    /// having its session replaced.
    private func openProject() {
        guard let url = WorkspacePicker.choose() else { return }
        adopt(workspace: url)
    }

    /// Switches this window to another project.
    ///
    /// In place rather than in a new window: picking from this menu is navigation, and navigation
    /// that spawns windows leaves the operator closing them. ⌘N is how a second window is asked
    /// for.
    private func adopt(workspace url: URL) {
        guard url.standardizedFileURL != model.workspace?.url.standardizedFileURL else { return }
        window.replaceProject(with: url)
    }

    /// The ⌘-click destination: a second window on that project, leaving this one as it was.
    ///
    /// Unique, like ⌘O and ⌘N: the operator asked for another window, not for an existing one on
    /// the same project to be raised.
    private func openInNewWindow(_ url: URL) {
        openWindow(id: "session", value: WindowTarget(workspace: url, isUnique: true))
    }

    /// One heading owns the agents beneath it, so no row repeats the folder icon and project name.
    private var projectHeading: some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { isProjectExpanded.toggle() }
        } label: {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Colors.subtle)
                    .rotationEffect(.degrees(isProjectExpanded ? 90 : 0))
                Text(model.workspace?.name ?? "Session")
                    .font(Theme.Typography.controlMedium)
                    .foregroundStyle(Theme.Colors.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.railPadding)
            .padding(.vertical, Theme.Space.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var filteredAgents: [AgentNode] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return model.agents }
        return model.agents.filter {
            $0.title.lowercased().contains(query)
                || AgentStateDot.shortLabel(for: $0.state).lowercased().contains(query)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.sm) {
            Spacer()
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 22))
                .foregroundStyle(Theme.Colors.subtle)
            Text(model.workspace == nil ? "No project" : "No agents")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Colors.muted)
            Text(model.workspace == nil
                ? "Open a project to begin."
                : "Start a session to see its agent tree.")
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.Colors.subtle)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, Theme.Space.railPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Approvals footer

    /// Approvals already decided are history, so they sit quietly at the bottom in the same
    /// treatment as an archived list rather than competing with live agents.
    private var auditFooter: some View {
        DisclosureSection(
            title: "Recent approvals",
            count: model.auditLog.isEmpty ? nil : "· \(model.auditLog.count)",
            isExpanded: $isAuditExpanded
        ) {
            // Same rule as everywhere else: what can grow past its box scrolls inside it.
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    if model.auditLog.isEmpty {
                        Text("No approvals yet.")
                            .font(Theme.Typography.meta)
                            .foregroundStyle(Theme.Colors.subtle)
                    } else {
                        ForEach(model.auditLog.prefix(12)) { entry in
                            AuditRow(entry: entry)
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.railPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
        }
        .frame(maxHeight: isAuditExpanded ? 260 : nil)
    }
}

// MARK: - Rows

/// A recorded conversation. Two lines: a quiet metadata line carrying state and time, and the
/// stronger title line taken from the first thing the operator said.
struct SessionRow: View {
    let session: HistoricalSession
    let title: String
    let isLive: Bool
    let liveState: AppModel.SessionState
    let relativeTime: String
    let isRenaming: Bool
    @Binding var draftName: String
    let onOpen: () -> Void
    let onRename: () -> Void
    let onCommitRename: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @FocusState private var isNameFocused: Bool

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Space.xs) {
                    Circle()
                        .fill(stateTint)
                        .frame(width: 7, height: 7)
                    Text(stateLabel)
                        .font(Theme.Typography.meta)
                        .foregroundStyle(stateTint)

                    if let branch = session.gitBranch, !branch.isEmpty, branch != "HEAD" {
                        Text(branch)
                            .font(Theme.Typography.monoMeta)
                            .foregroundStyle(Theme.Colors.subtle)
                            .lineLimit(1)
                    }

                    Spacer(minLength: Theme.Space.sm)

                    if isHovering {
                        Button(action: onRename) {
                            Image(systemName: "pencil")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.Colors.link)
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Rename this conversation")

                        Button(action: onArchive) {
                            Image(systemName: "archivebox")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.Colors.subtle)
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Archive — hides it from this list, keeps the transcript")
                    } else {
                        Text(relativeTime)
                            .font(Theme.Typography.monoMeta)
                            .foregroundStyle(Theme.Colors.subtle)
                    }
                }

                if isRenaming {
                    TextField(session.title, text: $draftName)
                        .textFieldStyle(.plain)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Colors.textStrong)
                        .focused($isNameFocused)
                        .onAppear { isNameFocused = true }
                        .onSubmit(onCommitRename)
                        // Leaving the field commits too: an edit abandoned by clicking elsewhere
                        // is still an edit the operator made.
                        .onChange(of: isNameFocused) { _, focused in
                            if !focused { onCommitRename() }
                        }
                        .padding(.vertical, 1)
                } else {
                    Text(title)
                        .font(Theme.Typography.title)
                        .foregroundStyle(isLive ? Theme.Colors.textStrong : Theme.Colors.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Theme.Space.railPadding)
            .padding(.vertical, Theme.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .rowSurface(isSelected: isLive, isHovering: isHovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(session.id)
        .contextMenu {
            Button("Resume") { onOpen() }
            // For resuming outside the app: the whole line, ready to paste into a terminal.
            Button("Copy Resume Command") { NSPasteboard.copy(session.resumeCommand) }
            Button("Rename…") { onRename() }
            Divider()
            Button("Archive") { onArchive() }
            Button("Delete…", role: .destructive) { onDelete() }
        }
    }

    private var stateLabel: String {
        isLive ? liveState.label : "Done"
    }

    private var stateTint: Color {
        guard isLive else { return Theme.Colors.subtle }
        switch liveState {
        case .running, .starting: return Theme.Colors.accent
        case .failed: return Theme.Colors.error
        case .exited(let status): return status == 0 ? Theme.Colors.subtle : Theme.Colors.error
        case .idle: return Theme.Colors.subtle
        }
    }

}

extension Date {
    /// `2m`, `18m`, `3h`, `4d` — the rail's time column.
    var relativeLabel: String {
        let elapsed = Int(Date().timeIntervalSince(self))
        if elapsed < 60 { return "\(max(elapsed, 0))s" }
        if elapsed < 3600 { return "\(elapsed / 60)m" }
        if elapsed < 86_400 { return "\(elapsed / 3600)h" }
        return "\(elapsed / 86_400)d"
    }
}

/// Two lines maximum: a strong title line, and a quiet metadata line carrying state and time.
struct AgentRow: View {
    let node: AgentNode
    let depth: Int
    let isSelected: Bool
    let relativeTime: String
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                if depth > 0 {
                    Rectangle()
                        .fill(Theme.Colors.border)
                        .frame(width: Theme.Layout.hairline)
                        .padding(.leading, CGFloat(depth - 1) * 10)
                        .padding(.vertical, 2)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Theme.Space.xs) {
                        AgentStateDot(state: node.state)
                        Text(AgentStateDot.shortLabel(for: node.state))
                            .font(Theme.Typography.meta)
                            .foregroundStyle(stateTextColor)
                        Spacer(minLength: Theme.Space.sm)
                        if node.hasFailOpenIncident {
                            Image(systemName: "exclamationmark.shield.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.Colors.error)
                                .help("A command ran without approval in this agent.")
                        }
                        Text(relativeTime)
                            .font(Theme.Typography.monoMeta)
                            .foregroundStyle(Theme.Colors.subtle)
                    }

                    Text(node.title)
                        .font(Theme.Typography.title)
                        .foregroundStyle(isSelected ? Theme.Colors.textStrong : Theme.Colors.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, Theme.Space.railPadding)
            .padding(.vertical, Theme.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .rowSurface(isSelected: isSelected, isHovering: isHovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var stateTextColor: Color {
        switch node.state {
        case .waitingForApproval, .blocked: return Theme.Colors.warning
        case .errored: return Theme.Colors.error
        case .thinking, .executingTool: return Theme.Colors.accent
        default: return Theme.Colors.subtle
        }
    }

}

struct AuditRow: View {
    let entry: AppModel.AuditEntry

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: entry.verdict == .allow ? "checkmark.circle" : "xmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(entry.verdict == .allow ? Theme.Colors.success : Theme.Colors.error)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.summary)
                    .font(Theme.Typography.monoMeta)
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(provenanceText)
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.subtle)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var provenanceText: String {
        switch entry.provenance {
        case .operatorDecision: return "You decided"
        case .autoApproved: return "Auto-approved — not reviewed"
        case .machineAllowlist: return "Allowed by this machine's settings"
        case .allowlistRule: return "Allowlist rule"
        case .denylistRule: return "Denylist rule"
        case .brokerTimeout, .helperTimeout: return "Denied — no response in time"
        case .brokerUnreachable: return "Denied — approval service unreachable"
        case .malformedPayload: return "Denied — unreadable request"
        case .internalError: return "Denied — internal error"
        }
    }
}
