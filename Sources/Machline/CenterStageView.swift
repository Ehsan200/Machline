import HarnessCore
import SwiftUI

/// The centre: one chronological event timeline, with the composer attached at the bottom.
///
/// There is no header. The rails already carry project and agent identity, and a header here only
/// delays access to the first event.
struct CenterStageView: View {
    @Bindable var model: AppModel

    /// The composer's height, remembered across launches.
    @AppStorage("composerHeight") private var storedComposerHeight = Theme.Layout.composerHeight
    @AppStorage("terminalHeight") private var storedTerminalHeight: Double = 260
    @State private var draggedTerminalHeight: CGFloat?
    /// The height during a drag.
    ///
    /// Writing to `@AppStorage` on every drag frame goes through `UserDefaults` and triggers a full
    /// view update per event, which is what made the drag feel like it was catching. The stored
    /// value is written once, when the drag ends.
    @State private var draggedHeight: CGFloat?

    private var composerHeight: CGFloat { draggedHeight ?? storedComposerHeight }

    var body: some View {
        GeometryReader { geometry in
            content(availableHeight: geometry.size.height)
        }
        .task { await loadShellOptions() }
    }

    private func content(availableHeight: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            stack(availableHeight: availableHeight)

            // Anchored to the composer rather than to the timeline: with the shell pane open the
            // timeline ends well above the input, and a list pinned there floats in mid-window.
            if model.isShowingCompletions {
                CompletionList(model: model)
                    .padding(.horizontal, Theme.Space.timelinePadding)
                    .padding(.bottom, composerOffset(availableHeight: availableHeight))
            }
        }
    }

    /// How far above the bottom edge the composer's top sits.
    private func composerOffset(availableHeight: CGFloat) -> CGFloat {
        let composer = min(
            composerHeight,
            max(Theme.Layout.composerMinHeight, availableHeight * Theme.Layout.composerMaxFraction))
        return composer + Theme.Space.sm
    }

    private func stack(availableHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            Group {
                // A just-resumed session has replayed history but no agent yet — its first frame
                // has not landed. Gating the timeline on an agent hid that history behind an
                // empty state.
                if model.selectedAgent != nil || !model.replay.isEmpty || model.isLoadingReplay {
                    TimelineView(model: model, agent: model.selectedAgent)
                } else {
                    emptyState
                }
            }

            // Mounted once opened and collapsed rather than removed when hidden: tearing the view
            // down ends the shell, so a running build would die every time the pane was toggled.
            if model.hasOpenedTerminal, let workspace = model.workspace?.url {
                terminalSection(workspace: workspace, availableHeight: availableHeight)
                    .frame(height: model.isTerminalVisible ? nil : 0)
                    .opacity(model.isTerminalVisible ? 1 : 0)
                    .allowsHitTesting(model.isTerminalVisible)
                    .clipped()
            }

            ResizeHandle(
                onDrag: { translation in
                    // Dragging up grows the composer, so the delta is inverted. Rounded and
                    // written only on a change: every write here rebuilds the whole column.
                    let next = min(
                        composerCeiling(availableHeight: availableHeight),
                        max(Theme.Layout.composerMinHeight, composerHeight - translation))
                        .rounded()
                    if next != draggedHeight { draggedHeight = next }
                },
                onEnd: {
                    if let draggedHeight { storedComposerHeight = draggedHeight }
                    draggedHeight = nil
                },
                onReset: {
                    draggedHeight = nil
                    storedComposerHeight = Theme.Layout.composerHeight
                })

            ComposerView(model: model)
                .frame(height: min(
                    composerHeight, composerCeiling(availableHeight: availableHeight)))
        }
        .background(Theme.Colors.canvas)
    }

    /// The tallest the composer may be in the space actually available.
    ///
    /// Two ceilings, whichever is lower: the share of the window it may occupy, and whatever is
    /// left after the timeline keeps a usable strip. A remembered height is *remembered* — it
    /// outlives the window it was chosen in, and a window later opened smaller must not let it
    /// push the composer's own controls past the bottom edge.
    private func composerCeiling(availableHeight: CGFloat) -> CGFloat {
        PaneLayout.composerHeight(
            requested: .greatestFiniteMagnitude,
            available: availableHeight,
            minimum: Theme.Layout.composerMinHeight,
            maximumFraction: Theme.Layout.composerMaxFraction,
            timelineMinimum: Theme.Layout.timelineMinHeight)
    }

    private var terminalHeight: CGFloat { draggedTerminalHeight ?? storedTerminalHeight }

    /// The pane's handle and header, which take height before the emulator gets any.
    private static let terminalChrome: CGFloat = 9 + 34
    private static let terminalMinHeight: CGFloat = 120
    private static let terminalMaxFraction: CGFloat = 0.75

    private func terminalCeiling(availableHeight: CGFloat) -> CGFloat {
        PaneLayout.shellCeiling(
            available: availableHeight,
            composer: min(composerHeight, composerCeiling(availableHeight: availableHeight)),
            chrome: Self.terminalChrome,
            minimum: Self.terminalMinHeight,
            maximumFraction: Self.terminalMaxFraction,
            timelineMinimum: Theme.Layout.timelineMinHeight)
    }

    /// The login shell first, then everything `/etc/shells` lists.
    ///
    /// Loaded once into state, never computed in a body. Working this out reads the account's
    /// directory record, which means a subprocess and a `waitUntilExit` that spins a runloop —
    /// and a runloop spun inside a view body re-enters SwiftUI's own update and aborts the process
    /// in AttributeGraph. It was reachable simply by opening the shell pane.
    @State private var shellOptions: [Select<String>.Option] = []

    private func loadShellOptions() async {
        let (login, available) = await Task.detached(priority: .userInitiated) {
            (LoginShell.path(), LoginShell.available())
        }.value
        shellOptions =
            [.init("", label: (login as NSString).lastPathComponent, detail: "login shell")]
            + available
                .filter { $0 != login }
                .map { .init($0, label: ($0 as NSString).lastPathComponent, detail: $0) }
    }

    /// The shell, between the transcript and the composer.
    ///
    /// Its own drag handle and its own remembered height: an operator watching a build wants it
    /// large, and one glancing at `git status` wants it small.
    private func terminalSection(workspace: URL, availableHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            ResizeHandle(
                onDrag: { translation in
                    let next = min(
                        terminalCeiling(availableHeight: availableHeight),
                        max(Self.terminalMinHeight, terminalHeight - translation))
                        .rounded()
                    if next != draggedTerminalHeight { draggedTerminalHeight = next }
                },
                onEnd: {
                    if let draggedTerminalHeight { storedTerminalHeight = draggedTerminalHeight }
                    draggedTerminalHeight = nil
                })

            HStack(spacing: Theme.Space.md) {
                Image(systemName: "terminal")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Colors.subtle)
                Text("SHELL")
                    .font(Theme.Typography.sectionLabel)
                    .tracking(0.6)
                    .foregroundStyle(Theme.Colors.subtle)
                Text(workspace.lastPathComponent)
                    .font(Theme.Typography.monoMeta)
                    .foregroundStyle(Theme.Colors.subtle)

                Spacer(minLength: 0)

                Select(
                    selection: Binding(
                        get: { model.terminalShell ?? "" },
                        set: { model.terminalShell = $0.isEmpty ? nil : $0 }),
                    options: shellOptions)

                QuietButton(title: "Restart") { model.restartTerminal() }
                IconButton(systemName: "chevron.down", help: "Hide the shell (⌃`)") {
                    model.isTerminalVisible = false
                }
                IconButton(systemName: "xmark", help: "Close the shell and end it") {
                    model.closeTerminal()
                }
            }
            .padding(.horizontal, Theme.Space.md)
            // 28pt is exactly the icon button's own height, which left it touching the edges.
            .frame(height: 34)
            .background(Theme.Colors.panel)

            TerminalPane(
                workingDirectory: workspace,
                shell: model.terminalShell,
                generation: Binding(
                    get: { model.terminalGeneration },
                    set: { _ in }))
                .frame(height: min(terminalHeight, terminalCeiling(availableHeight: availableHeight)))
        }
    }

    /// Shown when the centre has nothing to draw: no live agent and no replayed history.
    ///
    /// It used to read "Nothing selected — start a session, then pick an agent", which describes a
    /// sequence the operator cannot perform: there is nothing to select here, and agents are not
    /// picked but spawned by the session as it works. What is actually true depends on where the
    /// session is, so the copy follows that — and in every case the way forward is the composer
    /// directly below.
    private var emptyState: some View {
        VStack(spacing: Theme.Space.sm) {
            Spacer()
            Image(systemName: emptyIcon)
                .font(.system(size: 24))
                .foregroundStyle(Theme.Colors.subtle)
            Text(emptyTitle)
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Colors.muted)
            Text(emptyDetail)
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.Colors.subtle)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyIcon: String {
        switch model.sessionState {
        case .idle: return "text.alignleft"
        case .starting, .running: return "ellipsis"
        case .exited(let status): return status == 0 ? "checkmark.circle" : "exclamationmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var emptyTitle: String {
        switch model.sessionState {
        case .idle: return "No session yet"
        case .starting: return "Starting the session…"
        case .running: return "Waiting for the first reply"
        case .exited(let status): return status == 0 ? "Session ended" : "Session exited (\(status))"
        case .failed: return "The session could not start"
        }
    }

    private var emptyDetail: String {
        switch model.sessionState {
        case .idle:
            return "Type below and press Return to start one. Earlier conversations are in the rail."
        case .starting:
            return "The gate comes up first, then the CLI."
        case .running:
            return "The session is up. Whatever it sends back lands here."
        case .exited:
            return "Type below to start another, or resume an earlier one from the rail."
        case .failed(let message):
            return message
        }
    }
}

// MARK: - Timeline

/// One stream, in order. Importance is carried by spacing, type family, and surface — never by
/// moving lower-priority events somewhere else.
struct TimelineView: View {
    @Bindable var model: AppModel
    /// `nil` while a resumed session's first frame is still in flight. The replayed history above
    /// is still worth showing.
    let agent: AgentNode?

    /// Anchors the foot of the timeline. Scrolling to a fixed anchor rather than to the last
    /// event's id means one code path covers replayed history, live events, and the empty case —
    /// and it still works while the lazy stack has not built the rows in between.
    private static let bottomAnchor = "timeline.bottom"

    /// Set once the view has jumped to the foot of a freshly loaded conversation. Until then a
    /// scroll must be instant: animating a jump across hundreds of replayed entries reads as the
    /// window flinging itself around.
    @State private var hasSettled = false

    /// False while the operator has scrolled up. Two things hang off it: the jump-to-latest pill,
    /// and the auto-scroll — a timeline that yanks itself to the foot while someone is reading
    /// three screens up is worse than one that never scrolls at all.
    @State private var isAtBottom = true
    /// How many events have landed since they scrolled away from the foot.
    @State private var unseenCount = 0

    /// The bottom anchor is treated as reached within this many points, so a resting scroll that
    /// stops a hair short still counts as being at the end.
    private static let bottomSlack: CGFloat = 24

    var body: some View {
        ScrollViewReader { proxy in
            timeline(proxy)
                .overlay(alignment: .bottom) {
                    if !isAtBottom {
                        jumpToLatest(proxy)
                            .padding(.bottom, Theme.Space.md)
                    }
                }
        }
    }

    /// The pill shown when there is more below: says how much, and goes there.
    private func jumpToLatest(_ proxy: ScrollViewProxy) -> some View {
        Pill(
            title: unseenCount > 0 ? "\(unseenCount) new below" : "Jump to latest",
            systemImage: "arrow.down",
            isProminent: true
        ) {
            unseenCount = 0
            scrollToBottom(proxy, animated: true)
        }
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }

    private func timeline(_ proxy: ScrollViewProxy) -> some View {
        GeometryReader { viewport in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // What the resumed conversation already contained. Read from the transcript,
                    // because resuming continues a session rather than replaying it.
                    if model.isLoadingReplay {
                        HStack(spacing: Theme.Space.sm) {
                            Spinner(size: 10, color: Theme.Colors.subtle)
                            Text("Reading earlier messages…")
                                .font(Theme.Typography.meta)
                                .foregroundStyle(Theme.Colors.subtle)
                        }
                        .padding(.vertical, Theme.Space.lg)
                    }
                    ForEach(model.replay) { entry in
                        ReplayEntryView(model: model, entry: entry)
                    }
                    if !model.replay.isEmpty {
                        resumeMarker
                    }

                    ForEach(model.timelineEvents) { event in
                        TimelineEventView(model: model, event: event)
                            .id(event.id)
                    }

                    // The reply as it is written. Superseded by the assembled block the moment
                    // it lands, so the two are never on screen together.
                    if let agent, !agent.streamingText.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            Text("AGENT")
                                .font(Theme.Typography.sectionLabel)
                                .tracking(0.8)
                                .foregroundStyle(Theme.Colors.muted)
                            MarkdownView(markdown: agent.streamingText, isStreaming: true)
                        }
                        .padding(.top, Theme.Space.xl)
                    }

                    if let agent, agent.state.isBusy, let since = model.busySince {
                        ActivityIndicator(node: agent, startedAt: since)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                        // Where the foot of the conversation currently sits, in the scroll view's
                        // own space. Compared against the viewport height, it says whether the end
                        // is on screen — which `ScrollViewProxy` alone will not tell you.
                        .background(
                            GeometryReader { anchor in
                                Color.clear.preference(
                                    key: TimelineFootKey.self,
                                    value: anchor.frame(in: .named(Self.scrollSpace)).minY)
                            })
                }
                .padding(.horizontal, Theme.Space.timelinePadding)
                .padding(.top, Theme.Space.xl)
                .padding(.bottom, Theme.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .coordinateSpace(name: Self.scrollSpace)
            .onPreferenceChange(TimelineFootKey.self) { footY in
                let reached = footY <= viewport.size.height + Self.bottomSlack
                guard reached != isAtBottom else { return }
                isAtBottom = reached
                if reached { unseenCount = 0 }
            }
            .scrollContentBackground(.hidden)
            // A conversation opens at its foot: the end is where the work is.
            .onChange(of: model.replay.count) { _, count in
                guard count > 0 else { return }
                hasSettled = false
                unseenCount = 0
                isAtBottom = true
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: model.transcriptRevision) {
                // Only follow the conversation for someone who is already at the end of it.
                // Otherwise count what has arrived and let the pill offer the trip.
                if isAtBottom {
                    scrollToBottom(proxy, animated: hasSettled)
                } else {
                    unseenCount += 1
                }
            }
            // Re-pin when the viewport itself changes size — a rail being dragged, the composer or
            // the shell pane being resized, the window growing. Every one of those re-wraps the
            // prose, so the content gets taller or shorter while the scroll offset stays exactly
            // where it was, and the conversation appears to crawl up the screen under the pointer.
            // Someone parked mid-history keeps their place; someone at the foot stays at the foot.
            .onChange(of: viewport.size) {
                guard isAtBottom else { return }
                scrollToBottom(proxy, animated: false)
            }
            .onAppear { scrollToBottom(proxy, animated: false) }
            .selectableTextTint()
        }
    }

    private static let scrollSpace = "timeline.scroll"

    /// Scrolls to the foot.
    ///
    /// The hop off this pass matters: a scroll issued in the same pass as the content change lands
    /// against the old layout, leaving the view short of the end.
    ///
    /// It is a main-actor turn rather than a `DispatchQueue.main.async`: a queued block can be
    /// drained by a nested run loop while AppKit is still laying out, and an animated `scrollTo`
    /// landing there is a state change during a view update — the abort in `AttributeGraph`.
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        Task { @MainActor in
            if animated {
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            // Guarded because this runs on every frame of a rail drag: an unconditional write to
            // `@State` re-runs the timeline's body each time, which is precisely the cost the
            // re-pin exists to avoid paying twice.
            if !hasSettled { hasSettled = true }
        }
    }

    /// Separates what was read from disk from what this process saw happen.
    private var resumeMarker: some View {
        HStack(spacing: Theme.Space.md) {
            Hairline(color: Theme.Colors.accent.opacity(0.45))
            Text("resumed here")
                .font(Theme.Typography.monoMeta)
                .foregroundStyle(Theme.Colors.accent)
                .fixedSize()
            Hairline(color: Theme.Colors.accent.opacity(0.45))
        }
        .padding(.vertical, Theme.Space.xl)
    }

}

/// Carries the foot of the timeline's position out of the scroll view.
private struct TimelineFootKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct TimelineEventView: View {
    @Bindable var model: AppModel
    let event: TimelineEvent

    var body: some View {
        switch event.kind {
        case .assistantText(_, _, let text):
            assistantMessage(text)
        case .entry(let entry):
            entryView(entry)
        }
    }

    @ViewBuilder
    private func entryView(_ entry: TranscriptEntry) -> some View {
        switch entry {
        case .steerDelivered(_, let text), .steerQueued(_, let text):
            userMessage(text, isQueued: isQueued(entry))

        case .text:
            EmptyView()  // Folded into `assistantText` upstream.

        case .thinking(_, _, let text):
            thinking(text)

        case .toolCall(let id, let use):
            if let edit = EditPreview(use: use) {
                DiffCard(preview: edit) { model.openDiffModal(path: edit.path) }
                    .padding(.top, Theme.Space.lg)
            } else {
                ToolRow(model: model, rowKey: .live(id), use: use, result: nil)
                    .padding(.top, Theme.Space.sm)
            }

        case .toolResult(let id, let result, let output):
            ToolResultRow(model: model, rowKey: .live(id), result: result, output: output)

        case .turnEnded(_, let result):
            turnSeparator(result)

        case .incident(_, let text):
            incident(text)
        }
    }

    private func isQueued(_ entry: TranscriptEntry) -> Bool {
        if case .steerQueued = entry { return true }
        return false
    }

    // MARK: Events

    /// The strongest non-semantic surface in the timeline. Full width, squared, labelled — this
    /// initiated the work; it is not casual chat.
    private func userMessage(_ text: String, isQueued: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Text("YOU")
                    .font(Theme.Typography.sectionLabel)
                    .tracking(0.8)
                    .foregroundStyle(Theme.Colors.muted)
                if isQueued {
                    Text("queued · delivered at the next turn boundary")
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.warning)
                }
                Spacer(minLength: 0)
            }

            MessageBody(text: text)
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.surface.opacity(isQueued ? 0.5 : 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Layout.radius))
        .padding(.top, Theme.Space.xxl)
        .padding(.bottom, Theme.Space.md)
    }

    /// Prose, not a card. A heavy frame around a conclusion makes it read as an artefact rather
    /// than as the answer.
    private func assistantMessage(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Text("AGENT")
                    .font(Theme.Typography.sectionLabel)
                    .tracking(0.8)
                    .foregroundStyle(Theme.Colors.muted)
                Spacer(minLength: 0)
                QuoteButton(
                    model: model, text: text, source: .reply,
                    help: "Quote this reply in your next message")
            }

            MarkdownView(markdown: text, model: model)
        }
        .padding(.top, Theme.Space.xl)
        .padding(.bottom, Theme.Space.sm)
    }

    private func thinking(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Rectangle()
                .fill(Theme.Colors.border)
                .frame(width: 2)
            Text(text)
                .font(Theme.Typography.control)
                .italic()
                .foregroundStyle(Theme.Colors.subtle)
                .textSelection(.enabled)
        }
        .padding(.vertical, Theme.Space.sm)
    }

    private func turnSeparator(_ result: TurnResult) -> some View {
        HStack(spacing: Theme.Space.md) {
            Hairline()
            Text(turnLabel(result))
                .font(Theme.Typography.monoMeta)
                .foregroundStyle(Theme.Colors.subtle)
                .fixedSize()
            Hairline()
        }
        .padding(.vertical, Theme.Space.xl)
    }

    private func turnLabel(_ result: TurnResult) -> String {
        var parts = ["turn ended"]
        if let cost = result.totalCostUSD { parts.append(String(format: "$%.3f", cost)) }
        if let duration = result.durationMS { parts.append("\(duration / 1000)s") }
        return parts.joined(separator: " · ")
    }

    private func incident(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Colors.error)
            Text(text)
                .font(Theme.Typography.control)
                .foregroundStyle(Theme.Colors.error)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.error.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Layout.radius))
        .padding(.vertical, Theme.Space.sm)
    }
}

// MARK: - Tool rows

/// Supporting evidence, not the main story: one compact row carrying name, purpose, status, and a
/// disclosure control. Closed by default once it has succeeded.
struct ToolRow: View {
    @Bindable var model: AppModel
    /// The transcript entry this row draws, and the key its open/closed state is stored under.
    let rowKey: AppModel.RowKey
    let use: ToolUse
    let result: ToolResult?

    private var isExpanded: Bool { model.isRowExpanded(rowKey) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The same header the replayed rows use, so a live call and a recorded one are the
            // same row rather than two that merely resemble each other.
            ToolDisclosureRow(
                name: use.name,
                detail: summary,
                isExpanded: model.rowExpansionBinding(rowKey))

            if isExpanded {
                Text(use.bashCommand ?? use.input.prettyPrinted())
                    .font(Theme.Typography.monoSmall)
                    .foregroundStyle(Theme.Colors.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.leading, Theme.Space.md)
                    .padding(.vertical, Theme.Space.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.Colors.border)
                .frame(width: 2)
        }
    }

    /// Human-readable purpose stays sans; the raw command stays monospace.
    private var summary: String {
        if let command = use.bashCommand { return command }
        if let path = use.input["file_path"]?.stringValue { return path }
        if let pattern = use.input["pattern"]?.stringValue { return pattern }
        return ""
    }
}

/// Results stay quiet when they succeed. Failures and blocks stay open, because they are the ones
/// that change what the operator does next.
struct ToolResultRow: View {
    @Bindable var model: AppModel
    let rowKey: AppModel.RowKey
    let result: ToolResult
    let output: ProcessOutput?

    /// Failures and blocks open themselves until the operator says otherwise.
    private var isExpanded: Bool { model.isRowExpanded(rowKey, whenUnset: result.isError) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToolDisclosureRow(
                name: result.isError ? "Blocked" : "Result",
                detail: firstLine,
                statusIcon: result.isError ? "xmark.circle" : "checkmark",
                statusTint: result.isError ? Theme.Colors.error : Theme.Colors.success,
                isExpanded: model.rowExpansionBinding(rowKey, whenUnset: result.isError))

            if isExpanded {
                QuoteOutputRow(model: model, text: quotableOutput)
                ScrollView {
                    // stdout and stderr arrive pre-separated, so stderr can be styled distinctly
                    // without parsing concatenated output.
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        if let output, !(output.stdout.isEmpty && output.stderr.isEmpty) {
                            if !output.stdout.isEmpty {
                                Text(output.stdout)
                                    .font(Theme.Typography.monoSmall)
                                    .foregroundStyle(Theme.Colors.muted)
                            }
                            if !output.stderr.isEmpty {
                                Text(output.stderr)
                                    .font(Theme.Typography.monoSmall)
                                    .foregroundStyle(Theme.Colors.error)
                            }
                        } else {
                            Text(result.text)
                                .font(Theme.Typography.monoSmall)
                                .foregroundStyle(Theme.Colors.muted)
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: Theme.Layout.toolOutputMaxHeight)
                .padding(.horizontal, Theme.Space.md)
                .padding(.leading, Theme.Space.md)
                .padding(.bottom, Theme.Space.sm)
            }
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.Colors.border)
                .frame(width: 2)
        }
    }

    private var firstLine: String {
        let source = output.map { $0.stdout.isEmpty ? $0.stderr : $0.stdout } ?? result.text
        return source.split(separator: "\n").first.map(String.init) ?? ""
    }

    private var quotableOutput: String {
        guard let output, !(output.stdout.isEmpty && output.stderr.isEmpty) else { return result.text }
        return [output.stdout, output.stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
