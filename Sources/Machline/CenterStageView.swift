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
                    // Dragging up grows the composer, so the delta is inverted.
                    let ceiling = max(
                        Theme.Layout.composerMinHeight,
                        availableHeight * Theme.Layout.composerMaxFraction)
                    draggedHeight = min(
                        ceiling,
                        max(Theme.Layout.composerMinHeight, composerHeight - translation))
                },
                onEnd: {
                    if let draggedHeight { storedComposerHeight = draggedHeight }
                    draggedHeight = nil
                })

            ComposerView(model: model)
                .frame(height: min(
                    composerHeight,
                    max(Theme.Layout.composerMinHeight,
                        availableHeight * Theme.Layout.composerMaxFraction)))
        }
        .background(Theme.Colors.canvas)
    }

    private var terminalHeight: CGFloat { draggedTerminalHeight ?? storedTerminalHeight }

    /// The login shell first, then everything `/etc/shells` lists.
    private var shellOptions: [Select<String>.Option] {
        let login = LoginShell.path()
        return [.init("", label: (login as NSString).lastPathComponent, detail: "login shell")]
            + LoginShell.available()
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
                    let ceiling = max(120, availableHeight * 0.75)
                    draggedTerminalHeight = min(ceiling, max(120, terminalHeight - translation))
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
                .frame(height: min(terminalHeight, max(120, availableHeight * 0.75)))
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.sm) {
            Spacer()
            Image(systemName: "text.alignleft")
                .font(.system(size: 24))
                .foregroundStyle(Theme.Colors.subtle)
            Text("Nothing selected")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Colors.muted)
            Text("Start a session, then pick an agent.")
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.Colors.subtle)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    var body: some View {
        ScrollViewReader { proxy in
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
                        ReplayEntryView(entry: entry)
                    }
                    if !model.replay.isEmpty {
                        resumeMarker
                    }

                    ForEach(groupedEvents) { event in
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
                            MarkdownView(markdown: agent.streamingText)
                        }
                        .padding(.top, Theme.Space.xl)
                    }

                    if let agent, agent.state.isBusy, let since = model.busySince {
                        ActivityIndicator(node: agent, startedAt: since)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .padding(.horizontal, Theme.Space.timelinePadding)
                .padding(.top, Theme.Space.xl)
                .padding(.bottom, Theme.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
            // A conversation opens at its foot: the end is where the work is.
            .onChange(of: model.replay.count) { _, count in
                guard count > 0 else { return }
                hasSettled = false
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: model.transcriptRevision) {
                scrollToBottom(proxy, animated: hasSettled)
            }
            .onAppear { scrollToBottom(proxy, animated: false) }
        }
    }

    /// Scrolls to the foot.
    ///
    /// The hop through the main queue matters: a scroll issued in the same pass as the content
    /// change lands against the old layout, leaving the view short of the end.
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            hasSettled = true
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

    /// Assistant frames arrive one content block at a time under a shared message id, so
    /// consecutive text blocks are folded into a single prose event rather than rendered as a run
    /// of separate paragraphs.
    private var groupedEvents: [TimelineEvent] {
        guard let agent else { return [] }
        var events: [TimelineEvent] = []
        for entry in agent.transcript {
            if case .text(let id, let messageID, let text) = entry {
                if case .assistantText(_, let previousID, let existing)? = events.last?.kind,
                   previousID == messageID {
                    events.removeLast()
                    events.append(TimelineEvent(
                        id: id, kind: .assistantText(id, messageID, existing + text)))
                    continue
                }
                events.append(TimelineEvent(id: id, kind: .assistantText(id, messageID, text)))
                continue
            }
            events.append(TimelineEvent(id: entry.id, kind: .entry(entry)))
        }
        return events
    }
}

struct TimelineEvent: Identifiable {
    enum Kind {
        case assistantText(UUID, String, String)
        case entry(TranscriptEntry)
    }

    let id: UUID
    let kind: Kind
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

        case .toolCall(_, let use):
            if let edit = EditPreview(use: use) {
                DiffCard(preview: edit) { model.openDiffModal(path: edit.path) }
                    .padding(.top, Theme.Space.lg)
            } else {
                ToolRow(use: use, result: nil)
                    .padding(.top, Theme.Space.sm)
            }

        case .toolResult(_, let result, let output):
            ToolResultRow(result: result, output: output)

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
            Text("AGENT")
                .font(Theme.Typography.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(Theme.Colors.muted)

            MarkdownView(markdown: text)
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
    let use: ToolUse
    let result: ToolResult?

    @State private var isExpanded = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.Colors.subtle)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))

                    Text(use.name)
                        .font(Theme.Typography.controlMedium)
                        .foregroundStyle(Theme.Colors.muted)

                    Text(summary)
                        .font(Theme.Typography.monoSmall)
                        .foregroundStyle(Theme.Colors.subtle)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: Theme.Space.sm)

                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Colors.accent)
                }
                .padding(.horizontal, Theme.Space.md)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .background(isHovering ? Theme.Colors.surface.opacity(0.5) : .clear)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }

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
    let result: ToolResult
    let output: ProcessOutput?

    @State private var isExpanded: Bool

    init(result: ToolResult, output: ProcessOutput?) {
        self.result = result
        self.output = output
        _isExpanded = State(initialValue: result.isError)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.Colors.subtle)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))

                    Image(systemName: result.isError ? "xmark.circle" : "checkmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(result.isError ? Theme.Colors.error : Theme.Colors.success)

                    Text(result.isError ? "Blocked" : "Result")
                        .font(Theme.Typography.meta)
                        .foregroundStyle(result.isError ? Theme.Colors.error : Theme.Colors.subtle)

                    Text(firstLine)
                        .font(Theme.Typography.monoMeta)
                        .foregroundStyle(Theme.Colors.subtle)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Space.md)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
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
}
