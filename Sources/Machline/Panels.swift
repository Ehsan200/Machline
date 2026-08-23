import HarnessCore
import SwiftUI

// MARK: - Git workbench

/// Hunk-level staging, unstaging, and discarding, plus commit composition.
///
/// It lives inside a collapsed rail section because it is a workbench, not a status readout — the
/// glanceable form of the same information is the Changes list above.
struct GitWorkbenchView: View {
    @Bindable var git: GitPanelModel
    @Bindable var model: AppModel
    @State private var confirmingDiscard: (GitHunk, GitFileDiff)?
    @FocusState private var isFileListFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            // A folder that merely contains repositories is the common case for a projects
            // directory, so the picker appears whenever more than one was found.
            if git.repositories.count > 1 {
                repositoryPicker
            }

            if !git.isRepository {
                Text(git.repositories.isEmpty
                    ? "No Git repository here, or in the three levels below it."
                    : "Not a Git repository.")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.subtle)
                    .fixedSize(horizontal: false, vertical: true)
                Text(git.activeRepository.path)
                    .font(Theme.Typography.monoMeta)
                    .foregroundStyle(Theme.Colors.subtle)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                syncBar
                sideSelector
                fileList
                hunks
                commitComposer
                if let error = git.errorMessage {
                    Text(error)
                        .font(Theme.Typography.monoMeta)
                        .foregroundStyle(Theme.Colors.error)
                        .lineLimit(3)
                }
            }
        }
        .padding(.horizontal, Theme.Space.railPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Publishing is outward-facing, so it is never the click that asks for it.
        .alert(
            "Push to the remote?",
            isPresented: Binding(
                get: { git.pendingPush != nil },
                set: { if !$0 { git.pendingPush = nil } })
        ) {
            Button("Push") { git.confirmPush() }
            Button("Cancel", role: .cancel) { git.pendingPush = nil }
        } message: {
            if let push = git.pendingPush {
                Text(push.upstream == nil
                    ? "\(push.commitCount) commit(s) on \(push.branch). This branch has no "
                        + "upstream yet, so it will be published to origin and start tracking it."
                    : "\(push.commitCount) commit(s) from \(push.branch) to \(push.upstream!).")
            }
        }
        // The three strategies differ in whether they rewrite commits or leave conflict markers,
        // so a repository with no preference of its own gets asked rather than guessed at.
        .confirmationDialog(
            "How should this pull reconcile?",
            isPresented: $git.pullStrategyChoiceNeeded,
            titleVisibility: .visible
        ) {
            Button("Fast-forward only") { git.pull(strategy: .fastForwardOnly) }
            Button("Rebase") { git.pull(strategy: .rebase) }
            Button("Merge") { git.pull(strategy: .merge) }
            Button("Cancel", role: .cancel) { git.pullStrategyChoiceNeeded = false }
        } message: {
            Text("This repository sets neither pull.rebase nor pull.ff, so there is no configured "
                + "answer. Fast-forward only refuses rather than inventing history.")
        }
        .alert(
            "Discard this hunk?",
            isPresented: Binding(
                get: { confirmingDiscard != nil },
                set: { if !$0 { confirmingDiscard = nil } })
        ) {
            Button("Discard", role: .destructive) {
                if let (hunk, diff) = confirmingDiscard { git.discard(hunk: hunk, in: diff) }
                confirmingDiscard = nil
            }
            Button("Cancel", role: .cancel) { confirmingDiscard = nil }
        } message: {
            Text("This throws the change away. It cannot be undone.")
        }
    }

    /// Branch, divergence, and the three remote actions.
    ///
    /// Fetch and pull run on the click: fetch only moves remote-tracking refs, and pull is
    /// constrained by the repository's own strategy. Push asks first — it publishes to somewhere
    /// other people see, and that is not a mis-click away.
    private var syncBar: some View {
        let summary = git.activeSummary
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Colors.subtle)
                Text(summary?.branch ?? "—")
                    .font(Theme.Typography.monoStrong)
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)

                if let summary, summary.ahead > 0 {
                    Text("↑\(summary.ahead)")
                        .font(Theme.Typography.monoMeta)
                        .foregroundStyle(Theme.Colors.accent)
                }
                if let summary, summary.behind > 0 {
                    Text("↓\(summary.behind)")
                        .font(Theme.Typography.monoMeta)
                        .foregroundStyle(Theme.Colors.warning)
                }
                if summary?.upstream == nil {
                    Text("no upstream")
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.subtle)
                }

                Spacer(minLength: Theme.Space.sm)

                if git.isFetching {
                    Spinner(size: 10, color: Theme.Colors.subtle)
                }
            }

            HStack(spacing: Theme.Space.sm) {
                QuietButton(title: "Fetch", isEnabled: !git.isFetching) {
                    Task { await git.fetchAll() }
                }
                QuietButton(title: "Pull", isEnabled: !git.isFetching) { git.pull() }
                QuietButton(
                    title: "Push",
                    role: .primary,
                    isEnabled: !git.isFetching && (summary?.ahead ?? 0) > 0
                ) {
                    git.requestPush()
                }
                Spacer(minLength: 0)
                Text(fetchLabel)
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.subtle)
            }

            if let error = git.remoteError {
                Text(error)
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.error)
                    .lineLimit(2)
            }
        }
    }

    private var fetchLabel: String {
        guard let fetched = git.lastFetchedAt else { return "not fetched yet" }
        return "fetched \(fetched.relativeLabel) ago"
    }

    private var canDraft: Bool {
        !git.isDrafting && !(git.status?.staged.isEmpty ?? true)
    }

    private var draftButtonHelp: String {
        if git.isDrafting {
            return "Stop writing. The run is killed and the session it made is removed."
        }
        return git.status?.staged.isEmpty ?? true
            ? "Stage something first — the message is written from the staged diff"
            : "Write a Conventional Commits message from the staged diff"
    }

    private var repositoryPicker: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "shippingbox")
                .font(.system(size: 10))
                .foregroundStyle(Theme.Colors.subtle)
            Select(
                selection: Binding(
                    get: { git.activeRepository },
                    set: { git.select(repository: $0) }),
                options: git.repositories.map { url in
                    .init(url, label: git.label(for: url), detail: git.summaryLine(for: url))
                })
            Spacer(minLength: 0)
            Text("\(git.repositories.count) repos")
                .font(Theme.Typography.monoMeta)
                .foregroundStyle(Theme.Colors.subtle)
        }
    }

    private var sideSelector: some View {
        SegmentedSelect(
            selection: $git.showStagedSide,
            options: [
                (false, "Unstaged \(git.unstaged.count)"),
                (true, "Staged \(git.staged.count)")
            ])
    }

    private var visibleDiffs: [GitFileDiff] {
        git.showStagedSide ? git.staged : git.unstaged
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 2) {
            bulkBar
            ForEach(visibleDiffs) { diff in
                HStack(spacing: Theme.Space.sm) {
                    CheckBox(isOn: Binding(
                        get: { git.checkedPaths.contains(diff.newPath) },
                        set: { _ in git.toggleChecked(diff.newPath) }))

                    Button { git.selectedPath = diff.newPath } label: {
                        HStack(spacing: Theme.Space.sm) {
                            FileIconView(path: diff.newPath)
                            Text(diff.newPath)
                                .font(Theme.Typography.monoMeta)
                                .foregroundStyle(git.selectedDiff?.newPath == diff.newPath
                                    ? Theme.Colors.textStrong
                                    : Theme.Colors.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: Theme.Space.sm)
                            DiffCounts(additions: diff.additions, deletions: diff.deletions)
                        }
                        .padding(.horizontal, Theme.Space.sm)
                        .padding(.vertical, 3)
                        .background(git.selectedDiff?.newPath == diff.newPath
                            ? Theme.Colors.selection
                            : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        // The list takes the keyboard as a whole: ↑↓ move the selection, space ticks the box for
        // staging, and Return opens the diff. Without `focusable` nothing here holds focus and the
        // key presses reach no one.
        .focusable()
        .focused($isFileListFocused)
        // The list needs focus, not the system's ring. AppKit draws that ring around the first
        // focusable descendant it finds — here the bulk bar — which reads as a stray highlight on
        // a row the operator never aimed at. The selected row's own background already says where
        // the keyboard is pointing.
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            switch press.key {
            case .upArrow:
                moveSelection(by: -1)
                return .handled
            case .downArrow:
                moveSelection(by: 1)
                return .handled
            case .space:
                guard let path = git.selectedDiff?.newPath else { return .ignored }
                git.toggleChecked(path)
                return .handled
            case .return:
                guard let path = git.selectedDiff?.newPath else { return .ignored }
                model.openDiffModal(path: path)
                return .handled
            default:
                return .ignored
            }
        }
    }

    /// Moves through whichever side is showing, stopping at the ends rather than wrapping — a file
    /// list is a list, not a carousel, and wrapping loses the operator's place.
    private func moveSelection(by offset: Int) {
        let paths = visibleDiffs.map(\.newPath)
        guard !paths.isEmpty else { return }
        // `String.flatMap` iterates characters, so the index lookup is done explicitly.
        let selected = git.selectedDiff?.newPath
        let current = selected.flatMap { paths.firstIndex(of: $0) } ?? 0
        git.selectedPath = paths[min(max(current + offset, 0), paths.count - 1)]
    }

    /// Select-all and the bulk action for whichever side is showing.
    private var bulkBar: some View {
        let paths = visibleDiffs.map(\.newPath)
        let checked = git.checkedPathsOnCurrentSide()
        return HStack(spacing: Theme.Space.sm) {
            CheckBox(
                isOn: Binding(
                    get: { !paths.isEmpty && checked.count == paths.count },
                    set: { git.setChecked(paths, to: $0) }),
                isEnabled: !paths.isEmpty
            ) {
                Text(checked.isEmpty ? "Select all" : "\(checked.count) selected")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.subtle)
            }

            Spacer(minLength: 0)

            if !checked.isEmpty {
                QuietButton(title: git.showStagedSide
                    ? "Unstage \(checked.count)"
                    : "Stage \(checked.count)") {
                    git.showStagedSide ? git.unstageChecked() : git.stageChecked()
                }
            }
        }
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var hunks: some View {
        if let diff = git.selectedDiff {
            if diff.isBinary {
                Text("Binary file — no line-level diff available.")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.subtle)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        ForEach(diff.hunks) { hunk in
                            HunkView(
                                hunk: hunk,
                                isStagedSide: git.showStagedSide,
                                onStage: { git.stage(hunk: hunk, in: diff) },
                                onUnstage: { git.unstage(hunk: hunk, in: diff) },
                                onDiscard: { confirmingDiscard = (hunk, diff) })
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
    }

    private var commitComposer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Select(
                    selection: $git.commitDraft.kind,
                    options: ConventionalCommit.Kind.allCases.map { .init($0, label: $0.rawValue) })

                TextField("scope", text: Binding(
                    get: { git.commitDraft.scope ?? "" },
                    set: { git.commitDraft.scope = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.monoMeta)
                    .frame(width: 74)

                CheckBox(isOn: $git.commitDraft.isBreaking) {
                    Text("breaking")
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.muted)
                }
                .help("Marks a breaking change")

                Spacer(minLength: 0)

                // Reads the staged diff and writes a Conventional Commits message for it.
                // Disabled with nothing staged, because there would be nothing to describe.
                // Writing is the one state the button does not repeat itself in: it stops the run
                // instead. A draft that turns out to be unwanted — the wrong files staged, the
                // wrong session forked — should not have to be waited out.
                Button {
                    if git.isDrafting {
                        git.cancelDraft()
                    } else {
                        git.generateDraft(fork: model.commitDraftFork)
                    }
                } label: {
                    HStack(spacing: Theme.Space.xs) {
                        if git.isDrafting {
                            Spinner(size: 10, color: Theme.Colors.accent)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10))
                        }
                        Text(git.isDrafting ? "Stop" : "Suggest")
                            .font(Theme.Typography.meta)
                    }
                    .foregroundStyle(git.isDrafting || canDraft
                        ? Theme.Colors.accent
                        : Theme.Colors.subtle)
                    .padding(.horizontal, Theme.Space.sm)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(
                                git.isDrafting || canDraft
                                    ? Theme.Colors.accent.opacity(0.5)
                                    : Theme.Colors.border,
                                lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!git.isDrafting && !canDraft)
                .help(draftButtonHelp)
            }

            if let draftError = git.draftError {
                HStack(alignment: .top, spacing: Theme.Space.xs) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Colors.error)
                    Text(draftError)
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.error)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    IconButton(systemName: "xmark", help: "Dismiss") { git.dismissDraftError() }
                }
                .padding(.bottom, Theme.Space.xs)
            }

            TextField("Summary", text: $git.commitDraft.summary, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .font(Theme.Typography.control)
                .foregroundStyle(Theme.Colors.text)
                .padding(Theme.Space.sm)
                .background(Theme.Colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            // A suggestion often explains *why*; hiding the body would throw that away.
            if !(git.commitDraft.body ?? "").isEmpty {
                TextField("Body", text: Binding(
                    get: { git.commitDraft.body ?? "" },
                    set: { git.commitDraft.body = $0.isEmpty ? nil : $0 }),
                    axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...8)
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.muted)
                    .padding(Theme.Space.sm)
                    .background(Theme.Colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            // Style guidance is advisory: it never blocks the commit.
            ForEach(git.advisories) { advisory in
                Text(advisory.detail)
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.subtle)
            }

            HStack(spacing: Theme.Space.sm) {
                Text(git.commitDraft.subject)
                    .font(Theme.Typography.monoMeta)
                    .foregroundStyle(Theme.Colors.subtle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Space.sm)
                QuietButton(title: "Commit", role: .primary, isEnabled: git.canCommit) {
                    git.commit()
                }
            }
        }
    }
}

struct HunkView: View {
    let hunk: GitHunk
    let isStagedSide: Bool
    let onStage: () -> Void
    let onUnstage: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.sm) {
                Text(hunk.header)
                    .font(Theme.Typography.monoMeta)
                    .foregroundStyle(Theme.Colors.subtle)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.sm)
                if isStagedSide {
                    miniButton("Unstage", action: onUnstage)
                } else {
                    miniButton("Stage", action: onStage)
                    IconButton(systemName: "trash", help: "Discard this hunk",
                               tint: Theme.Colors.error, action: onDiscard)
                }
            }
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, 3)
            .background(Theme.Colors.surface)

            // One `Text` for the whole hunk: selection cannot cross separate views, and a stack
            // of a few hundred of them is also what made this scroll badly.
            ScrollView(.horizontal, showsIndicators: false) {
                Text(rendered(hunk))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, Theme.Space.sm)
                    .padding(.vertical, 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Theme.Colors.border, lineWidth: Theme.Layout.hairline))
    }

    private func rendered(_ hunk: GitHunk) -> AttributedString {
        var output = AttributedString()
        for line in hunk.lines {
            var piece = AttributedString(
                (line.patchLine.isEmpty ? " " : line.patchLine) + "\n")
            piece.font = Theme.Typography.monoMeta
            switch line.kind {
            case .addition:
                piece.foregroundColor = Theme.Colors.diffAddedText
                piece.backgroundColor = Theme.Colors.diffAdded
            case .deletion:
                piece.foregroundColor = Theme.Colors.diffDeletedText
                piece.backgroundColor = Theme.Colors.diffDeleted
            case .context, .noNewlineMarker:
                piece.foregroundColor = Theme.Colors.muted
            }
            output.append(piece)
        }
        return output
    }

    private func miniButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(Theme.Typography.meta)
            .foregroundStyle(Theme.Colors.link)
    }

    private func background(for kind: GitDiffLine.Kind) -> Color {
        switch kind {
        case .addition: return Theme.Colors.diffAdded
        case .deletion: return Theme.Colors.diffDeleted
        case .context, .noNewlineMarker: return .clear
        }
    }
}

// MARK: - Full-file diff modal

/// The complete diff for one file, without transcript truncation. Escape closes it.
///
/// Rendered as a single `Text` rather than one per line: SwiftUI selection lives inside a `Text`,
/// so a per-line stack can only ever be copied one line at a time — and a few thousand of them is
/// also what made scrolling stutter.
struct FileDiffModal: View {
    @Bindable var model: AppModel
    let path: String

    @Environment(\.dismiss) private var dismiss

    /// Above this many lines the diff is rendered in a first slice, with the rest on request. One
    /// attributed string of a 400k-line patch is not something to build during a sheet animation.
    private static let initialLineLimit = 4_000
    @State private var showsEverything = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline(color: Theme.Colors.border)

            if let diff = model.diff(for: path) {
                if diff.isBinary {
                    note("Binary file — no line-level diff available.")
                } else if diff.hunks.isEmpty {
                    note("No differences to show.")
                } else {
                    ScrollView([.vertical, .horizontal]) {
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            Text(rendered(diff))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, Theme.Space.lg)
                                .padding(.vertical, Theme.Space.md)

                            if truncatedLineCount(diff) > 0 {
                                QuietButton(
                                    title: "Show \(truncatedLineCount(diff)) more lines"
                                ) {
                                    showsEverything = true
                                }
                                .padding(.horizontal, Theme.Space.lg)
                                .padding(.bottom, Theme.Space.lg)
                            }
                        }
                    }
                }
            } else {
                note("This file is no longer in the working tree diff.")
            }
        }
        .frame(width: 900, height: 640)
        .background(Theme.Colors.canvas)
        .onExitCommand { dismiss() }
    }

    /// The diff as one attributed string: hunk headers muted, additions and deletions tinted, and
    /// every line prefixed by its marker so a copied selection is still a valid patch fragment.
    private func rendered(_ diff: GitFileDiff) -> AttributedString {
        var output = AttributedString()
        var emitted = 0

        for hunk in diff.hunks {
            if !output.characters.isEmpty { output.append(AttributedString("\n")) }

            var header = AttributedString(hunk.header + "\n")
            header.font = Theme.Typography.monoSmall
            header.foregroundColor = Theme.Colors.subtle
            output.append(header)

            for line in hunk.lines {
                if !showsEverything, emitted >= Self.initialLineLimit { return output }
                var piece = AttributedString(line.patchLine + "\n")
                piece.font = Theme.Typography.monoSmall
                piece.foregroundColor = colour(for: line.kind)
                if let background = background(for: line.kind) {
                    piece.backgroundColor = background
                }
                output.append(piece)
                emitted += 1
            }
        }
        return output
    }

    private func truncatedLineCount(_ diff: GitFileDiff) -> Int {
        guard !showsEverything else { return 0 }
        let total = diff.hunks.reduce(0) { $0 + $1.lines.count }
        return max(0, total - Self.initialLineLimit)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.md) {
            FileIconView(path: path, size: 12)
            Text(path)
                .font(Theme.Typography.monoStrong)
                .foregroundStyle(Theme.Colors.textStrong)
                .lineLimit(1)
                .truncationMode(.middle)

            if let diff = model.diff(for: path) {
                DiffCounts(additions: diff.additions, deletions: diff.deletions)
            }

            Spacer(minLength: Theme.Space.md)

            if let diff = model.diff(for: path), let patch = diff.fullPatch {
                QuoteButton(
                    model: model, text: patch, source: .patch(path: path),
                    help: "Quote this patch in your next message")
                CopyButton(text: patch, help: "Copy the patch")
            }
            QuietButton(title: "View file") {
                // Presenting while a dismissal is still in flight is dropped on the floor, so the
                // model is asked to make the swap once this sheet has actually gone.
                model.replaceDiffModalWithViewer(path: path)
            }
            QuietButton(title: "Open externally") { model.openFile(path: path) }
            QuietButton(title: "Show in Finder") { model.revealInFinder(path: path) }
            IconButton(systemName: "xmark", help: "Close (esc)") { dismiss() }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.control)
            .foregroundStyle(Theme.Colors.subtle)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func colour(for kind: GitDiffLine.Kind) -> Color {
        switch kind {
        case .addition: return Theme.Colors.diffAddedText
        case .deletion: return Theme.Colors.diffDeletedText
        case .context, .noNewlineMarker: return Theme.Colors.muted
        }
    }

    private func background(for kind: GitDiffLine.Kind) -> Color? {
        switch kind {
        case .addition: return Theme.Colors.diffAdded
        case .deletion: return Theme.Colors.diffDeleted
        case .context, .noNewlineMarker: return nil
        }
    }
}
