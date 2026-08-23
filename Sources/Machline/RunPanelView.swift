import HarnessCore
import SwiftUI

/// The right rail: what the session is spending, what its agents are doing, and what it has
/// changed on disk.
///
/// There is no header and no Status section — the composer's status strip already carries session
/// state, and repeating it here costs the vertical space that subagents and changed files need.
struct RunPanelView: View {
    @Bindable var model: AppModel
    /// Only for the control that puts this rail away — the panel's own contents are the session's.
    @Bindable var window: WindowModel

    @State private var isUsageExpanded = false
    @State private var isApprovalsExpanded = false
    @State private var isCompletedExpanded = false
    @State private var isGitExpanded = false

    var body: some View {
        // One scroll view over the whole rail, not one over the top half.
        //
        // The workbench sections used to sit outside it, pinned to the foot. Expanding one then
        // grew a `VStack` taller than the window, and a `VStack` that overflows does it at *both*
        // ends: the Approvals panel ran off the top of the rail and off the bottom at once, with
        // no way to reach either. Anything that can grow has to be inside the scroll.
        //
        // The foot still reads as a foot: the content is held to at least the rail's own height,
        // so the `Spacer` pushes the workbenches down while there is room, and simply scrolls once
        // there is not.
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    // No header row: the tab strip already carries a run-panel toggle that is
                    // visible whether the panel is open or shut, so a second one here was a row of
                    // chrome saying what the strip already says.

                    // What is happening now, at the top.
                    ContextSummary(model: model, isExpanded: $isUsageExpanded)

                    if !model.sessionChanges.isEmpty {
                        Hairline()
                        ChangesSection(model: model)
                    }

                    Hairline()
                    DisclosureSection(
                        title: "Git",
                        count: (model.git?.repositories.count ?? 0) > 1
                            ? "· \(model.git?.repositories.count ?? 0) repos"
                            : nil,
                        isExpanded: $isGitExpanded
                    ) {
                        if let git = model.git {
                            GitWorkbenchView(git: git, model: model)
                        } else {
                            emptyNote("Open a project to use the Git workbench.")
                        }
                    }

                    Spacer(minLength: 0)

                    // Everything that is a workbench rather than a readout sits at the foot,
                    // collapsed. These were eight equal-weight headings competing with the live
                    // state above them.
                    Hairline()

                    DisclosureSection(
                        title: "Approvals",
                        count: model.autoApproval.isEnabled ? "· auto" : nil,
                        isExpanded: $isApprovalsExpanded
                    ) {
                        ApprovalsPanel(model: model)
                    }

                    DisclosureSection(
                        title: "Completed agents",
                        count: model.completedAgents.isEmpty ? nil : "· \(model.completedAgents.count)",
                        isExpanded: $isCompletedExpanded
                    ) {
                        CompletedAgentsList(model: model)
                    }
                }
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .scrollContentBackground(.hidden)
        }
        .background(Theme.Colors.panel)
        .selectableTextTint()
        // `/context`, `/permissions`, and `/mcp` answer here rather than in a sheet: this is where
        // the controls are, so a read-only copy of the panel would be a dead end.
        // The hop off this turn is not cosmetic. An `onChange` handler runs *inside* the view
        // update, so opening a section with `withAnimation` there queued a transaction that
        // SwiftUI then flushed mid-update — `AttributeGraph precondition failure: setting value
        // during update`, which aborts the process. Typing `/context` crashed the app outright.
        // Deferring to the next main-actor turn puts both writes safely after the update.
        .onChange(of: model.focusedPanelSection) { _, section in
            guard let section else { return }
            Task { @MainActor in
                withAnimation(.easeOut(duration: 0.15)) {
                    switch section {
                    case .context: isUsageExpanded = true
                    case .approvals: isApprovalsExpanded = true
                    }
                }
                model.focusedPanelSection = nil
            }
        }
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.meta)
            .foregroundStyle(Theme.Colors.subtle)
            .padding(.horizontal, Theme.Space.railPadding)
    }
}

// MARK: - Context

/// Context fill at a glance: a ring for the proportion, the exact counts beside it for precision,
/// and cumulative cost kept quiet. Input/output/cache accounting stays behind Details.
struct ContextSummary: View {
    @Bindable var model: AppModel
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(alignment: .center, spacing: Theme.Space.md) {
                ContextRing(fraction: model.contextFraction, tint: ringTint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.contextUsedLabel)
                        .font(Theme.Typography.monoStrong)
                        .foregroundStyle(Theme.Colors.text)
                        .help("Context in use — what the last model call carried.")
                    Text("\(model.contextRemainingLabel) left")
                        .font(Theme.Typography.monoMeta)
                        .foregroundStyle(Theme.Colors.subtle)
                    // Kept separate from the ring: this is everything the session has sent and
                    // received, which passes the window's size many times over on a long
                    // conversation and is not a proportion of anything.
                    Text("\(model.tokensSpentLabel) tokens spent")
                        .font(Theme.Typography.monoMeta)
                        .foregroundStyle(Theme.Colors.subtle)
                        .help("Every token sent or received this session, cached reads included.")
                }

                Spacer(minLength: 0)

                // Spend moved to the title bar, where it is visible without opening anything.
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 2) {
                        Text("Details")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.link)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                VStack(spacing: Theme.Space.xs) {
                    ForEach(model.usageDetails, id: \.label) { row in
                        HStack {
                            Text(row.label)
                                .font(Theme.Typography.meta)
                                .foregroundStyle(Theme.Colors.subtle)
                            Spacer()
                            Text(row.value)
                                .font(Theme.Typography.monoMeta)
                                .foregroundStyle(Theme.Colors.muted)
                        }
                    }
                }
                .padding(.top, Theme.Space.xs)
            }
        }
        .padding(.horizontal, Theme.Space.railPadding)
        .padding(.vertical, Theme.Space.md)
    }

    /// Near the limit the ring takes the warning colour; the numeric label carries the same fact,
    /// so colour is never the only signal.
    private var ringTint: Color {
        model.contextFraction > 0.85 ? Theme.Colors.warning : Theme.Colors.accent
    }
}

struct ContextRing: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.Colors.surface, lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.Colors.text)
        }
        .frame(width: 44, height: 44)
    }
}

// MARK: - Subagents

/// The most detailed persistent section in the rail: role, activity, current tool, counts.
/// Agents needing input or in a failed state rise to the top.
struct ActiveSubagentsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            SectionLabel("Working", trailing: "\(model.activeAgents.count)")

            ForEach(model.activeAgents) { node in
                ActiveAgentCard(node: node, isSelected: model.selectedAgent?.id == node.id) {
                    model.select(agentID: node.id)
                }
            }
        }
        .padding(.horizontal, Theme.Space.railPadding)
        .padding(.vertical, Theme.Space.md)
    }
}

struct ActiveAgentCard: View {
    let node: AgentNode
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: roleIcon)
                        .font(.system(size: 11))
                        .foregroundStyle(AgentStateDot.tint(for: node.state))
                    Text(node.title)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Colors.textStrong)
                        .lineLimit(1)
                    Spacer(minLength: Theme.Space.sm)
                    Text(AgentStateDot.shortLabel(for: node.state))
                        .font(Theme.Typography.meta)
                        .foregroundStyle(AgentStateDot.tint(for: node.state))
                }

                Text(node.state.label)
                    .font(Theme.Typography.titleRegular)
                    .foregroundStyle(Theme.Colors.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let tool = currentTool {
                    HStack(spacing: Theme.Space.xs) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.Colors.subtle)
                        Text(tool)
                            .font(Theme.Typography.monoMeta)
                            .foregroundStyle(Theme.Colors.subtle)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Text(counts)
                    .font(Theme.Typography.monoMeta)
                    .foregroundStyle(Theme.Colors.subtle)
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.surface.opacity(isSelected ? 1 : 0.55))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Layout.radius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Layout.radius)
                    .strokeBorder(
                        isSelected ? Theme.Colors.accent.opacity(0.5) : .clear,
                        lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Icons supplement the role text; they never replace it.
    private var roleIcon: String {
        if node.isRoot { return "circle.grid.cross" }
        switch node.title.lowercased() {
        case let title where title.contains("review"): return "eye"
        case let title where title.contains("search"), let title where title.contains("explore"):
            return "magnifyingglass"
        case let title where title.contains("plan"): return "list.bullet.rectangle"
        case let title where title.contains("test"): return "checkmark.seal"
        default: return "cube"
        }
    }

    /// The tool the agent is on now, taken from its state rather than guessed from the transcript.
    private var currentTool: String? {
        if case .executingTool(let name, _) = node.state { return name }
        if case .waitingForApproval(let name, _) = node.state { return "\(name) · awaiting approval" }
        return nil
    }

    private var counts: String {
        var parts: [String] = []
        parts.append("\(node.telemetry.toolUseCount) tools")
        if let tokens = node.telemetry.totalTokens { parts.append("\(tokens.abbreviated) tokens") }
        if let duration = node.telemetry.durationMS { parts.append(duration.durationLabel) }
        return parts.joined(separator: " · ")
    }
}

struct CompletedAgentsList: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if model.completedAgents.isEmpty {
                Text("No agent has finished yet.")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.subtle)
            } else {
                ForEach(model.completedAgents) { node in
                    Button { model.select(agentID: node.id) } label: {
                        HStack(spacing: Theme.Space.sm) {
                            Text(node.title)
                                .font(Theme.Typography.control)
                                .foregroundStyle(Theme.Colors.text)
                                .lineLimit(1)
                            Spacer(minLength: Theme.Space.sm)
                            Text(outcome(node))
                                .font(Theme.Typography.monoMeta)
                                .foregroundStyle(outcomeTint(node))
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, Theme.Space.railPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A finished agent shows its outcome, never its last tool — that would read as still running.
    private func outcome(_ node: AgentNode) -> String {
        var parts = [AgentStateDot.shortLabel(for: node.state)]
        if let duration = node.telemetry.durationMS { parts.append(duration.durationLabel) }
        if let tokens = node.telemetry.totalTokens { parts.append(tokens.abbreviated) }
        return parts.joined(separator: " · ")
    }

    private func outcomeTint(_ node: AgentNode) -> Color {
        switch node.state {
        case .errored: return Theme.Colors.error
        case .cancelled: return Theme.Colors.warning
        default: return Theme.Colors.subtle
        }
    }
}

// MARK: - Changes

/// Session-wide net file changes. Clicking a row opens the whole file diff.
struct ChangesSection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.sm) {
                SectionLabel(
                    "Changes",
                    trailing: changedFiles.isEmpty ? nil : "\(changedFiles.count) files")
                if !changedFiles.isEmpty {
                    DiffCounts(additions: totalAdditions, deletions: totalDeletions)
                }
            }

            if true {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ForEach(changedFiles) { diff in
                        ChangedFileRow(
                            diff: diff,
                            status: model.changeStatus(for: diff.newPath),
                            onOpen: { model.openDiffModal(path: diff.newPath) },
                            onView: { model.openViewer(path: diff.newPath) },
                            onReveal: { model.revealInFinder(path: diff.newPath) })
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.railPadding)
        .padding(.vertical, Theme.Space.md)
    }

    private var changedFiles: [GitFileDiff] { model.sessionChanges }
    private var totalAdditions: Int { changedFiles.reduce(0) { $0 + $1.additions } }
    private var totalDeletions: Int { changedFiles.reduce(0) { $0 + $1.deletions } }
}

struct ChangedFileRow: View {
    let diff: GitFileDiff
    let status: String
    let onOpen: () -> Void
    let onView: () -> Void
    let onReveal: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Theme.Space.sm) {
                Text(status)
                    .font(Theme.Typography.monoStrong)
                    .foregroundStyle(statusTint)
                    .frame(width: 12, alignment: .leading)

                FileIconView(path: diff.newPath, size: 10)

                // Truncating from the middle keeps the filename readable, which is the part the
                // operator is looking for.
                Text(diff.newPath)
                    .font(Theme.Typography.monoMeta)
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: Theme.Space.sm)

                if diff.isBinary {
                    Text("binary")
                        .font(Theme.Typography.monoMeta)
                        .foregroundStyle(Theme.Colors.subtle)
                } else {
                    DiffCounts(additions: diff.additions, deletions: diff.deletions)
                }
            }
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, 3)
            .rowSurface(isSelected: false, isHovering: isHovering)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("View file") { onView() }
            Button("Show diff") { onOpen() }
            Divider()
            Button("Show in Finder") { onReveal() }
        }
    }

    private var statusTint: Color {
        switch status {
        case "A": return Theme.Colors.success
        case "D": return Theme.Colors.error
        case "R": return Theme.Colors.info
        default: return Theme.Colors.muted
        }
    }
}

// `Int.abbreviated` and `Int.durationLabel` live in `HarnessCore` beside the accounting that uses
// them, so both can be tested.
