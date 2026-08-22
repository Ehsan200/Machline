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
    @State private var window = WindowModel()

    private var model: AppModel { window.current }

    var body: some View {
        ZStack {
            Theme.Colors.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                if let outcome = model.updateOutcome {
                    updateBanner(outcome)
                    Hairline()
                }

                // Always present: it carries the version badge and the new-tab control, so
                // hiding it at one tab cost a whole row of chrome to show the same information.
                SessionTabStrip(window: window)
                Hairline()

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
                HSplitView {
                    SessionRailView(model: model, window: window)
                        .frame(
                            minWidth: Theme.Layout.railMinWidth,
                            idealWidth: Theme.Layout.railWidth,
                            maxWidth: Theme.Layout.railMaxWidth)

                    CenterStageView(model: model)
                        .frame(minWidth: Theme.Layout.centerMinWidth)
                        .layoutPriority(1)

                    RunPanelView(model: model)
                        .frame(
                            minWidth: Theme.Layout.runPanelMinWidth,
                            idealWidth: Theme.Layout.runPanelWidth,
                            maxWidth: Theme.Layout.runPanelMaxWidth)
                }
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

    /// The result of a manual update check.
    ///
    /// Machline is ad-hoc signed, so there is no updater here — the banner reports what exists and
    /// opens the release page. Replacing a running app with an unverified download is the one
    /// thing an update mechanism must not do.
    @ViewBuilder
    private func updateBanner(_ outcome: UpdateCheck.Outcome) -> some View {
        HStack(spacing: Theme.Space.md) {
            switch outcome {
            case .available(let release):
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.accent)
                Text("Machline \(release.version) is available — you have \(model.appVersion).")
                    .font(Theme.Typography.control)
                    .foregroundStyle(Theme.Colors.text)
                Spacer(minLength: Theme.Space.md)
                updateActions(for: release)

            case .upToDate:
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.success)
                Text("Machline \(model.appVersion) is the latest release.")
                    .font(Theme.Typography.control)
                    .foregroundStyle(Theme.Colors.muted)
                Spacer(minLength: Theme.Space.md)

            case .unavailable(let reason):
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.subtle)
                Text(reason)
                    .font(Theme.Typography.control)
                    .foregroundStyle(Theme.Colors.subtle)
                Spacer(minLength: Theme.Space.md)
            }

            IconButton(systemName: "xmark", help: "Dismiss") { model.dismissUpdateNotice() }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.panel)
    }

    /// The right-hand end of the update banner: fetch the build, watch it arrive, open it.
    ///
    /// A release published without a build attached still gets the page, because then the page is
    /// genuinely the only thing there is.
    @ViewBuilder
    private func updateActions(for release: UpdateCheck.Release) -> some View {
        switch model.updateDownload {
        case .running(let fraction):
            HStack(spacing: Theme.Space.sm) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 130)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(Theme.Typography.monoMeta)
                    .foregroundStyle(Theme.Colors.subtle)
                    .monospacedDigit()
                QuietButton(title: "Cancel") { model.cancelUpdateDownload() }
            }

        case .finished(let file):
            HStack(spacing: Theme.Space.sm) {
                Text(file.lastPathComponent)
                    .font(Theme.Typography.monoMeta)
                    .foregroundStyle(Theme.Colors.subtle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                QuietButton(title: "Show in Finder") { model.revealDownloadedUpdate() }
                QuietButton(title: "Open", role: .primary) { model.openDownloadedUpdate() }
            }

        case .failed(let message):
            HStack(spacing: Theme.Space.sm) {
                Text(message)
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.error)
                    .lineLimit(2)
                QuietButton(title: "Open release") { NSWorkspace.shared.open(release.url) }
                QuietButton(title: "Retry", role: .primary) { model.retryUpdateDownload() }
            }

        case .idle:
            HStack(spacing: Theme.Space.sm) {
                QuietButton(title: "Release notes") { NSWorkspace.shared.open(release.url) }
                if let asset = release.asset {
                    QuietButton(title: downloadTitle(for: asset), role: .primary) {
                        model.downloadUpdate(release)
                    }
                }
            }
        }
    }

    /// The size is on the button because it is what decides whether now is a good moment.
    private func downloadTitle(for asset: UpdateCheck.Asset) -> String {
        guard asset.byteCount > 0 else { return "Download" }
        let megabytes = Double(asset.byteCount) / 1_000_000
        return String(format: "Download (%.1f MB)", megabytes)
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
