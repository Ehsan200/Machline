import HarnessCore
import SwiftUI

/// The workspace: session rail, event timeline with composer, run panel.
///
/// There is no centre header and no run-panel header — both repeated context the rails already
/// carry. `HSplitView` is used rather than `NavigationSplitView` because the rails need fixed
/// preferred widths with hard maximums: extra window width belongs to the timeline and to wide
/// diffs, not to the rails.
struct ContentView: View {
    @Binding var target: WindowTarget

    /// One window holds one project's sessions, each with its own child process and approval
    /// broker. Tabs are drawn by the app; see `WindowModel` for why not AppKit's.
    ///
    /// Kept in a box because `@State`'s initial value is an ordinary expression: SwiftUI keeps
    /// only the first one it is handed, but the expression itself runs every time the view is
    /// re-created. Building a `WindowModel` reads the recents list, the machine configuration and
    /// the stored settings off disk, so `= WindowModel()` did all of that on every pass and threw
    /// the result away.
    @State private var box = WindowModelBox()

    private var window: WindowModel { box.model }

    private var model: AppModel { window.current }

    var body: some View {
        ZStack {
            Theme.Colors.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                // The update check's answer is *not* here. It hangs off the version badge in a
                // popover — see `UpdateCard`. As a row in this column it moved every pane below it
                // the moment an answer landed, which is a poor trade for a sentence.

                // Always present: it carries the version badge and the new-tab control, so
                // hiding it at one tab cost a whole row of chrome to show the same information.
                SessionTabStrip(window: window)
                Hairline()

                // Mounted unconditionally, and it decides for itself whether to draw anything.
                // stderr lands on the session pump, so reading it from *this* body would rebuild
                // the whole window — rails, timeline, composer — every time the CLI clears its
                // throat. Kept inside its own view, only the banner rebuilds.
                WarningBanner(model: model)

                if model.isGateDegraded {
                    degradedBanner
                    Hairline(color: Theme.Colors.error)
                }

                // A window with no project has nothing to put in the rails, and an empty
                // three-pane frame around a landing page is just chrome.
                if model.workspace == nil {
                    HomeView(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.Colors.canvas)
                } else {
                    workspacePanes
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.Colors.accent)
        .navigationTitle(model.windowTitle)
        .background(WindowBackground())
        .focusedSceneValue(\.windowModel, window)
        .task { await adopt(target) }
        // The approval sheet is deliberately modal: an approval that can be ignored is an approval
        // that eventually gets rubber-stamped or times out.
        .sheet(item: ApprovalBinding(model: model)) { pending in
            // A question is not an approval, so it gets its own sheet rather than a "deny with
            // feedback" field pressed into service as an answer box.
            if AskUserQuestion.isQuestion(pending.payload) {
                QuestionSheet(model: model, pending: pending)
            } else {
                ApprovalSheet(model: model, pending: pending)
            }
        }
        .sheet(item: Binding(
            get: { model.diffModalPath },
            set: { model.diffModalPath = $0 })
        ) { target in
            FileDiffModal(model: model, path: target.path)
        }
        .sheet(item: Binding(
            get: { model.viewerPath },
            set: { model.viewerPath = $0 })
        ) { target in
            FileViewer(model: model, path: target.path)
        }
        .sheet(item: Binding(
            get: { model.reportCommand },
            set: { model.reportCommand = $0 })
        ) { command in
            StatusSheet(model: model, command: command)
        }
    }

    /// The three-pane workspace. Either rail can be put away, the way an editor puts its sidebars
    /// away; the `HSplitView` is rebuilt without it, which is what lets the centre take the width
    /// back — a pane squeezed to zero width would leave its divider behind.
    private var workspacePanes: some View {
        HSplitView {
            if window.isSessionRailVisible {
                SessionRailView(model: model, window: window)
                    .frame(
                        minWidth: Theme.Layout.railMinWidth,
                        idealWidth: Theme.Layout.railWidth,
                        maxWidth: Theme.Layout.railMaxWidth)
            }

            CenterStageView(model: model)
                .frame(minWidth: Theme.Layout.centerMinWidth)
                .layoutPriority(1)

            if window.isRunPanelVisible {
                RunPanelView(model: model, window: window)
                    .frame(
                        minWidth: Theme.Layout.runPanelMinWidth,
                        idealWidth: Theme.Layout.runPanelWidth,
                        maxWidth: Theme.Layout.runPanelMaxWidth)
            }
        }
    }

    /// Opens the window's project and, if it names one, resumes its session.
    ///
    /// Runs once per window. The session is only auto-started when the window was opened to resume
    /// a specific conversation — a plain project window waits for the operator.
    private func adopt(_ target: WindowTarget) async {
        guard model.workspace == nil else { return }
        model.loadRecentProjects()
        guard let workspace = target.workspace else { return }
        model.open(workspace: workspace)

        guard let resumeSessionID = target.resumeSessionID else { return }
        // History is read off the main actor, so the session being resumed may not be listed yet.
        await model.waitForHistory()
        if let recorded = model.projectSessions.first(where: { $0.id == resumeSessionID }) {
            model.resume(recorded)
        }
    }

    /// A failed approval channel or an observed fail-open means commands may be running ungated.
    /// It gets a persistent banner rather than a transient alert.
    private var degradedBanner: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 15))
                .foregroundStyle(Theme.Colors.error)

            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text("Approval gate degraded")
                    .font(Theme.Typography.controlMedium)
                    .foregroundStyle(Theme.Colors.textStrong)
                ForEach(model.failOpenIncidents, id: \.self) { incident in
                    Text(incident)
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.muted)
                }
                if let failure = model.approvalChannelFailure {
                    Text(failure)
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.muted)
                }
            }

            Spacer(minLength: Theme.Space.lg)

            QuietButton(title: "Stop session", role: .danger) { model.stop() }
            QuietButton(title: "Dismiss") { model.dismissIncidents() }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.error.opacity(0.12))
    }
}

/// What the CLI wrote to stderr, in the operator's way but not in their face.
///
/// These are worth seeing exactly when a session opens — a flag the CLI no longer honours, a
/// settings file it could not read, a model it quietly swapped are all cheap to act on then and
/// expensive to discover an hour later. Until now they only existed in `/status`, which nobody
/// opens while everything still looks fine.
///
/// One line collapsed, the rest behind a disclosure, and a dismiss that means it.
struct WarningBanner: View {
    @Bindable var model: AppModel

    @State private var isExpanded = false

    var body: some View {
        let warnings = model.pendingWarnings
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.md) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.warning)
                    Text(warnings.count == 1
                        ? "Claude Code wrote a warning"
                        : "Claude Code wrote \(warnings.count) warnings")
                        .font(Theme.Typography.controlMedium)
                        .foregroundStyle(Theme.Colors.textStrong)
                        .fixedSize()

                    // The first line collapsed: most warnings are one line, and reading it should
                    // not cost a click.
                    if !isExpanded, let first = warnings.first {
                        Text(first)
                            .font(Theme.Typography.monoMeta)
                            .foregroundStyle(Theme.Colors.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: Theme.Space.md)

                    if warnings.count > 1 || !isExpanded {
                        QuietButton(title: isExpanded ? "Hide" : "Show") { isExpanded.toggle() }
                    }
                    IconButton(systemName: "xmark", help: "Dismiss these warnings") {
                        isExpanded = false
                        model.dismissWarnings()
                    }
                }

                if isExpanded {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                            ForEach(warnings, id: \.self) { warning in
                                Text(warning)
                                    .font(Theme.Typography.monoSmall)
                                    .foregroundStyle(Theme.Colors.muted)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.vertical, Theme.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.warning.opacity(0.10))

            Hairline(color: Theme.Colors.warning.opacity(0.4))
        }
    }
}

/// Bridges the pending-approval queue to `.sheet(item:)`.
private struct ApprovalBinding: Identifiable, Equatable {
    let id: String
    let pending: PendingApproval

    static func == (lhs: ApprovalBinding, rhs: ApprovalBinding) -> Bool { lhs.id == rhs.id }

    @MainActor
    init?(model: AppModel) {
        guard let pending = model.currentApproval else { return nil }
        self.pending = pending
        self.id = pending.payload.toolUseID
    }
}

extension View {
    fileprivate func sheet(
        item: ApprovalBinding?,
        @ViewBuilder content: @escaping (PendingApproval) -> some View
    ) -> some View {
        sheet(isPresented: .constant(item != nil)) {
            if let item { content(item.pending) }
        }
    }
}

/// A dot carrying agent state. Paired with a state word everywhere it appears — state is never
/// communicated by colour alone.
struct AgentStateDot: View {
    let state: AgentState
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(Self.tint(for: state))
            .frame(width: size, height: size)
    }

    static func tint(for state: AgentState) -> Color {
        switch state {
        case .idle: return Theme.Colors.subtle
        case .thinking: return Theme.Colors.info
        case .executingTool: return Theme.Colors.accent
        case .waitingForApproval: return Theme.Colors.warning
        case .blocked: return Theme.Colors.warning
        case .completed: return Theme.Colors.success
        case .errored: return Theme.Colors.error
        case .cancelled: return Theme.Colors.subtle
        }
    }

    /// The short state vocabulary shown in rows: Working, Needs input, Done.
    static func shortLabel(for state: AgentState) -> String {
        switch state {
        case .idle: return "Idle"
        case .thinking, .executingTool: return "Working"
        case .waitingForApproval: return "Needs input"
        case .blocked: return "Blocked"
        case .completed: return "Done"
        case .errored: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}
