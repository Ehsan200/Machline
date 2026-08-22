import HarnessCore
import SwiftUI

/// The composer, as three edge-to-edge bands: a status strip carrying real runtime state, a
/// dominant input body, and a labelled control footer.
///
/// Nothing here is invented. Every value in the status strip comes from the session — if the
/// runtime does not report it, it is not shown.
struct ComposerView: View {
    @Bindable var model: AppModel

    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            statusStrip
            Hairline()
            if let failure = model.failureMessage {
                failureStrip(failure)
                Hairline()
            }
            inputBody
            Hairline()
            controlFooter
        }
        .background(Theme.Colors.panel)
    }

    // MARK: - Band 1: status

    private var statusStrip: some View {
        HStack(spacing: Theme.Space.sm) {
            Circle()
                .fill(statusTint)
                .frame(width: 7, height: 7)

            Text(model.sessionState.label.uppercased())
                .font(Theme.Typography.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(statusTint)

            ForEach(statusFacts, id: \.self) { fact in
                Text("·")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.subtle)
                Text(fact)
                    .font(Theme.Typography.monoMeta)
                    .foregroundStyle(Theme.Colors.subtle)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if model.queuedSteerCount > 0 {
                Text("\(model.queuedSteerCount) queued")
                    .font(Theme.Typography.monoMeta)
                    .foregroundStyle(Theme.Colors.warning)
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .frame(height: Theme.Layout.composerStatusStrip)
    }

    private var statusFacts: [String] {
        var facts: [String] = []
        if let project = model.workspace?.name { facts.append(project) }
        if let session = model.shortSessionID { facts.append("session \(session)") }
        if let turns = model.selectedAgent?.telemetry.turnCount, turns > 0 {
            facts.append("turn \(turns)")
        }
        return facts
    }

    private var statusTint: Color {
        switch model.sessionState {
        case .idle: return Theme.Colors.subtle
        case .starting: return Theme.Colors.warning
        case .running: return Theme.Colors.accent
        case .exited(let status): return status == 0 ? Theme.Colors.subtle : Theme.Colors.error
        case .failed: return Theme.Colors.error
        }
    }

    /// A session that failed to start says why here. Without this the composer sits at a state
    /// word with no explanation, which reads as a hang rather than as a failure.
    private func failureStrip(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Colors.error)
            Text(message)
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.Colors.error)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.error.opacity(0.10))
    }

    // MARK: - Band 2: input

    private var inputBody: some View {
        ZStack(alignment: .topLeading) {
            // TextEditor is an NSTextView underneath, which reveals the caret on its own and only
            // scrolls when the caret leaves the viewport. It does not need the manual reveal a
            // custom text surface would.
            // One input for prose, commands, and mentions. `PromptEditor` is `NSTextView`-backed
            // because shell editing needs the caret, which SwiftUI's `TextEditor` does not expose.
            PromptEditor(
                text: Binding(
                    get: { model.promptDraft },
                    set: { model.promptDraft = $0; model.updateCompletions() }),
                onSubmit: { model.submit() },
                // History only when the completion list is not using the arrows.
                onHistory: { backward in model.navigateHistory(backward: backward) },
                onCompletionKey: { key in
                    guard model.isShowingCompletions else { return false }
                    switch key {
                    case .up: model.moveCompletionSelection(by: -1)
                    case .down: model.moveCompletionSelection(by: 1)
                    case .accept: model.acceptCompletion()
                    case .dismiss: model.dismissCompletions()
                    }
                    return true
                })

            if model.promptDraft.isEmpty {
                Text(placeholder)
                    .font(Theme.Typography.prose)
                    .foregroundStyle(Theme.Colors.subtle)
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.vertical, Theme.Space.md)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { subagentNotice }
        // Files dropped here become `@` mentions, the same shape the agent reads a path from.
        .dropDestination(for: URL.self) { urls, _ in
            model.mentionDroppedFiles(urls)
            return true
        } isTargeted: { isDropTarget = $0 }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: Theme.Layout.radius)
                    .strokeBorder(Theme.Colors.accent, style: StrokeStyle(lineWidth: 2, dash: [5]))
                    .padding(Theme.Space.sm)
                    .allowsHitTesting(false)
            }
        }
    }

    private var placeholder: String {
        model.sessionState.isRunning ? "Steer the agent…" : "Ask the agent"
    }

    /// Typing then pressing Return starts the session and sends the message, so the button says
    /// what will happen rather than naming the plumbing.
    private var submitTitle: String {
        if model.sessionState.isRunning { return "Steer" }
        return model.promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Start"
            : "Send"
    }

    /// Steering is queued, not immediate, and subagents have no input channel at all. Both are
    /// stated here rather than left to be discovered as an apparent hang.
    @ViewBuilder
    private var subagentNotice: some View {
        if let agent = model.selectedAgent, !agent.isRoot {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                Text("Subagents have no input channel. This goes to the parent session.")
                    .font(Theme.Typography.meta)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.Colors.subtle)
            .padding(.horizontal, Theme.Space.lg)
            .padding(.bottom, Theme.Space.sm)
        }
    }

    // MARK: - Band 3: controls

    private var controlFooter: some View {
        HStack(alignment: .center, spacing: Theme.Space.xl) {
            labelledCell("Model") {
                HStack(spacing: Theme.Space.sm) {
                    Select(
                        selection: Binding(
                            get: { model.model ?? "" },
                            set: { model.model = $0.isEmpty ? nil : $0 }),
                        options: modelOptions,
                        tint: model.isModelPendingRestart
                            ? Theme.Colors.warning
                            : Theme.Colors.text)

                    // `--model` is a launch flag, so a change cannot reach a session already
                    // running. Rather than pretend it applied, offer the restart that would.
                    if model.isModelPendingRestart {
                        Button("Restart") { model.restartSession() }
                            .buttonStyle(.plain)
                            .font(Theme.Typography.meta)
                            .foregroundStyle(Theme.Colors.warning)
                            .help("Restarts the session so the new model takes effect. "
                                + "The transcript is not carried over.")
                    }
                }
            }

            // Auto-approval must never be silent. This cell is on screen at all times.
            labelledCell("Approvals") {
                Text(approvalsLabel)
                    .font(Theme.Typography.monoStrong)
                    .foregroundStyle(approvalsTint)
                    .help(model.autoApproval.isEnabled
                        ? "Some calls run without asking. Configure under Approvals in the right panel."
                        : "Every gated call waits for you.")
            }

            labelledCell("Agents") {
                Text("\(model.agents.count)")
                    .font(Theme.Typography.monoStrong)
                    .foregroundStyle(Theme.Colors.text)
            }

            // Context and spend sit with the other per-session facts rather than in the title
            // bar, where they were cramped into a corner.
            if model.contextUsed > 0 {
                labelledCell("Context") {
                    Text("\(Int((model.contextFraction * 100).rounded()))%")
                        .font(Theme.Typography.monoStrong)
                        .foregroundStyle(model.contextFraction > 0.85
                            ? Theme.Colors.warning
                            : Theme.Colors.text)
                        .help("Context: \(model.contextUsedLabel)")
                }
            }

            labelledCell("Spend") {
                Text(model.costLabel)
                    .font(Theme.Typography.monoStrong)
                    .foregroundStyle(model.hasRecordedCost
                        ? Theme.Colors.text
                        : Theme.Colors.subtle)
                    .help(model.costExplanation)
            }

            Spacer(minLength: Theme.Space.md)

            // A menu item alone is not a control anyone finds. The shell earns a visible toggle.
            Button {
                model.toggleTerminal()
            } label: {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(model.isTerminalVisible
                        ? Theme.Colors.accent
                        : Theme.Colors.muted)
                    .frame(width: Theme.Layout.iconButton, height: Theme.Layout.iconButton)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Layout.radius)
                            .fill(model.isTerminalVisible
                                ? Theme.Colors.accent.opacity(0.12)
                                : .clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Layout.radius)
                            .strokeBorder(
                                model.isTerminalVisible
                                    ? Theme.Colors.accent.opacity(0.5)
                                    : Theme.Colors.border,
                                lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(model.workspace == nil)
            .opacity(model.workspace == nil ? 0.45 : 1)
            .help(model.workspace == nil
                ? "Open a project to use the shell"
                : "Show or hide the shell (⌃`)")

            if model.sessionState.isRunning {
                Button {
                    model.interrupt()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Colors.error)
                        .frame(width: Theme.Layout.iconButton, height: Theme.Layout.iconButton)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Layout.radius)
                                .strokeBorder(Theme.Colors.error.opacity(0.6), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Abort the current tool call. Steering only lands at the next turn boundary.")
            }

            QuietButton(
                title: submitTitle,
                role: .primary,
                isEnabled: model.canSubmit
            ) {
                model.submit()
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .frame(height: Theme.Layout.composerFooter)
    }

    private var approvalsLabel: String {
        if model.isGateDegraded { return "degraded" }
        guard model.autoApproval.isEnabled else { return "enforced" }
        var parts: [String] = []
        if let ceiling = model.autoApproval.bashCeiling { parts.append("≤\(ceiling.label)") }
        if model.autoApproval.workspaceFileEdits { parts.append("edits") }
        return "auto " + parts.joined(separator: "+")
    }

    private var approvalsTint: Color {
        if model.isGateDegraded { return Theme.Colors.error }
        return model.autoApproval.isEnabled ? Theme.Colors.warning : Theme.Colors.text
    }

    /// Unset means no `--model` flag at all, so the CLI uses whatever the operator configured.
    private var modelOptions: [Select<String>.Option] {
        [.init("", label: "Claude default", detail: "whatever the CLI is configured to use")]
            + AppModel.knownModels.prefix(4).map {
                .init($0, label: $0, detail: "latest in the \($0) family")
            }
            + AppModel.knownModels.dropFirst(4).map { .init($0, label: $0, detail: "pinned") }
    }

    private func labelledCell(
        _ label: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(Theme.Typography.sectionLabel)
                .tracking(0.6)
                .foregroundStyle(Theme.Colors.subtle)
            content()
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// The autocomplete list for `/commands` and `@files`.
///
/// Arrow keys move, Tab or Return accepts, Escape dismisses — the list holds those keys only while
/// it is open, so ordinary typing is never intercepted.
struct CompletionList: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Sized to its contents up to a cap: a `ScrollView` fills whatever it is given, which
            // left three results sitting in a tall empty box.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.completions.enumerated()), id: \.element.id) { index, completion in
                            row(completion, isSelected: index == model.selectedCompletion)
                                .background(index == model.selectedCompletion
                                    ? Theme.Colors.selection
                                    : Color.clear)
                                .contentShape(Rectangle())
                                .id(index)
                                .onTapGesture {
                                    model.moveCompletionSelection(by: index - model.selectedCompletion)
                                    model.acceptCompletion()
                                }
                        }
                    }
                }
                .frame(height: listHeight)
                // Arrowing past the visible window has to bring the selection with it.
                .onChange(of: model.selectedCompletion) { _, index in
                    proxy.scrollTo(index, anchor: .center)
                }
            }

            Hairline(color: Theme.Colors.border)
            Text("↑↓ to move · tab to insert · esc to dismiss")
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.Colors.subtle)
                .padding(.horizontal, Theme.Space.md)
                .padding(.vertical, 5)
        }
        .frame(maxWidth: 460, alignment: .leading)
        .background(Theme.Colors.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Layout.radius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Layout.radius)
                .strokeBorder(Theme.Colors.border, lineWidth: Theme.Layout.hairline))
        .shadow(color: Theme.Colors.backdrop, radius: 12, y: 4)
    }

    private static let rowHeight: CGFloat = 24
    private static let maximumHeight: CGFloat = 260

    /// Measured rather than fixed: a `ScrollView` expands to fill whatever it is given, so three
    /// results in an unmeasured list sat at the top of a tall empty box.
    private var listHeight: CGFloat {
        let total = model.completions.reduce(CGFloat.zero) { height, _ in
            height + Self.rowHeight
        }
        return min(total, Self.maximumHeight)
    }

    private func row(_ completion: Completion, isSelected: Bool) -> some View {
        HStack(spacing: Theme.Space.sm) {
            switch completion.kind {
            case .slashCommand:
                Image(systemName: "terminal")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Colors.subtle)
                    .frame(width: 14)
            case .directory:
                FileIconView(path: completion.label, isDirectory: true, size: 10)
            case .file:
                FileIconView(path: completion.detail ?? completion.label, size: 10)
            }

            Text(completion.label)
                .font(Theme.Typography.monoStrong)
                .foregroundStyle(isSelected ? Theme.Colors.textStrong : Theme.Colors.text)
                .lineLimit(1)

            if let detail = completion.detail {
                // The containing directory disambiguates two files with the same name, which is
                // the common case in any project with a components directory.
                Text(detail)
                    .font(Theme.Typography.monoMeta)
                    .foregroundStyle(Theme.Colors.subtle)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 5)
    }
}
