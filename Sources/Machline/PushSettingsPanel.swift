import HarnessCore
import SwiftUI

/// Where one repository pushes, decided before anything is published.
///
/// Shown on the first push in a tree with more than one remote, and again whenever the set of
/// remotes has changed since that answer was given. It is the confirmation for that push rather
/// than a step before one: an alert can say "push to three remotes", but only this can say which
/// three, at which URLs, running which commands. A remote called `upstream` is a word;
/// `vendor/product.git` is the fact that stops the mistake.
struct PushSettingsPanel: View {
    let configuration: GitPanelModel.PushConfiguration
    let onCancel: () -> Void
    let onConfirm: (PushPolicy, Bool) -> Void

    @State private var mode: Mode
    @State private var selection: Set<String>
    @State private var remembers = true

    /// The three answers, as the panel offers them. `PushPolicy.selected` carries names, which is
    /// what a segmented control cannot.
    private enum Mode: Hashable { case all, primaryOnly, custom }

    init(
        configuration: GitPanelModel.PushConfiguration,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (PushPolicy, Bool) -> Void
    ) {
        self.configuration = configuration
        self.onCancel = onCancel
        self.onConfirm = onConfirm

        let mode: Mode
        switch configuration.suggestedPolicy {
        case .all: mode = .all
        case .primaryOnly: mode = .primaryOnly
        case .selected: mode = .custom
        }
        _mode = State(initialValue: mode)
        _selection = State(initialValue: Set(
            configuration.targets(for: configuration.suggestedPolicy).map(\.name)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            header
            Hairline(color: Theme.Colors.border)

            if !configuration.unreviewed.isEmpty {
                notice
            }

            SegmentedSelect(
                selection: $mode,
                options: [
                    (.all, "All remotes"),
                    (.primaryOnly, "Primary only"),
                    (.custom, "Custom"),
                ])
            .onChange(of: mode) { _, new in
                // Custom starts from whatever the previous answer resolved to, so it is an edit
                // rather than a blank sheet.
                selection = Set(configuration.targets(for: policy(for: new)).map(\.name))
            }

            remoteList
            commands

            Spacer(minLength: 0)

            HStack(spacing: Theme.Space.md) {
                CheckBox(isOn: $remembers) {
                    Text("Remember for this repository")
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.muted)
                }
                Spacer(minLength: Theme.Space.md)
                QuietButton(title: "Cancel", action: onCancel)
                QuietButton(
                    title: configuration.isForPush ? "Push" : "Save",
                    role: .primary,
                    isEnabled: !targets.isEmpty
                ) {
                    onConfirm(policy(for: mode), remembers)
                }
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 560, height: 460)
        .background(Theme.Colors.canvas)
        .onExitCommand(perform: onCancel)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Where does this repository push?")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Colors.textStrong)
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Colors.subtle)
                Text(configuration.branch)
                    .font(Theme.Typography.monoStrong)
                    .foregroundStyle(Theme.Colors.text)
                if configuration.commitCount > 0 {
                    Text("↑\(configuration.commitCount)")
                        .font(Theme.Typography.monoMeta)
                        .foregroundStyle(Theme.Colors.accent)
                }
                Text(configuration.repository.lastPathComponent)
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.subtle)
            }
        }
    }

    /// Why a repository that already had an answer is being asked again.
    private var notice: some View {
        Text(configuration.unreviewed.count == 1
            ? "\(configuration.unreviewed[0]) was added since this was last set."
            : "\(configuration.unreviewed.joined(separator: ", ")) were added since this was "
                + "last set.")
            .font(Theme.Typography.meta)
            .foregroundStyle(Theme.Colors.warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var remoteList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(configuration.remotes) { remote in
                row(for: remote)
                if remote.id != configuration.remotes.last?.id {
                    Hairline(color: Theme.Colors.divider)
                }
            }
        }
        .background(Theme.Colors.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Layout.radius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Layout.radius)
                .strokeBorder(Theme.Colors.border, lineWidth: Theme.Layout.hairline))
    }

    private func row(for remote: GitRemote) -> some View {
        let isChecked = targets.contains { $0.name == remote.name }
        return HStack(alignment: .top, spacing: Theme.Space.sm) {
            CheckBox(
                isOn: Binding(
                    get: { isChecked },
                    set: { wanted in
                        // Ticking anything is by definition a custom answer, so the mode follows
                        // the box rather than fighting it.
                        var names = Set(targets.map(\.name))
                        if wanted { names.insert(remote.name) } else { names.remove(remote.name) }
                        selection = names
                        mode = .custom
                    }),
                isEnabled: true)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Theme.Space.sm) {
                    Text(remote.name)
                        .font(Theme.Typography.monoStrong)
                        .foregroundStyle(Theme.Colors.text)
                    if remote.name == configuration.primary {
                        Text("primary · sets upstream")
                            .font(Theme.Typography.meta)
                            .foregroundStyle(Theme.Colors.accent)
                    }
                    if isForeign(remote) {
                        Label("not your account", systemImage: "exclamationmark.triangle")
                            .font(Theme.Typography.meta)
                            .foregroundStyle(Theme.Colors.warning)
                            .labelStyle(.titleAndIcon)
                    }
                    if configuration.unreviewed.contains(remote.name) {
                        Text("new")
                            .font(Theme.Typography.meta)
                            .foregroundStyle(Theme.Colors.warning)
                    }
                }

                Text(remote.pushURL)
                    .font(Theme.Typography.monoMeta)
                    .foregroundStyle(Theme.Colors.subtle)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(divergenceLabel(for: remote))
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.subtle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .contentShape(Rectangle())
    }

    /// Exactly what will run, in order. The strongest thing the panel says.
    private var commands: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel("Will run")
            if targets.isEmpty {
                Text("Nothing selected.")
                    .font(Theme.Typography.monoMeta)
                    .foregroundStyle(Theme.Colors.subtle)
            } else {
                ForEach(targets) { remote in
                    Text(command(for: remote))
                        .font(Theme.Typography.monoMeta)
                        .foregroundStyle(Theme.Colors.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private func command(for remote: GitRemote) -> String {
        let upstream = remote.name == configuration.primary ? "-u " : ""
        return "git push \(upstream)\(remote.name) \(configuration.branch)"
    }

    /// Ahead and behind against this remote's own copy of the branch, which is not the same number
    /// for each of them — that is the whole reason a fork needs this panel.
    private func divergenceLabel(for remote: GitRemote) -> String {
        guard let divergence = configuration.divergences[remote.name] else {
            return configuration.divergences.isEmpty
                ? "reading…"
                : "no copy of this branch yet"
        }
        if divergence.ahead == 0 && divergence.behind == 0 { return "up to date" }
        var parts: [String] = []
        if divergence.ahead > 0 { parts.append("↑\(divergence.ahead)") }
        if divergence.behind > 0 { parts.append("↓\(divergence.behind)") }
        return parts.joined(separator: " ") + " · as of the last fetch"
    }

    /// A push URL owned by someone other than the primary's owner. Advisory: a shared team remote
    /// trips it too, which is why it warns rather than blocks.
    private func isForeign(_ remote: GitRemote) -> Bool {
        guard let primary = configuration.remotes.first(where: { $0.name == configuration.primary }),
              let mine = primary.owner, let theirs = remote.owner
        else { return false }
        return mine.caseInsensitiveCompare(theirs) != .orderedSame
    }

    private var targets: [GitRemote] { configuration.targets(for: policy(for: mode)) }

    private func policy(for mode: Mode) -> PushPolicy {
        switch mode {
        case .all: return .all
        case .primaryOnly: return .primaryOnly
        case .custom: return .selected(configuration.remotes.map(\.name).filter(selection.contains))
        }
    }
}

/// How one remote's answer reads in the sync bar.
enum PushResultStyle {
    static func icon(_ outcome: PushResult.Outcome) -> String {
        switch outcome {
        case .pushed: return "checkmark"
        case .upToDate: return "equal"
        case .rejected: return "xmark"
        case .failed: return "exclamationmark.triangle"
        }
    }

    static func colour(_ outcome: PushResult.Outcome) -> Color {
        switch outcome {
        case .pushed: return Theme.Colors.accent
        case .upToDate: return Theme.Colors.subtle
        case .rejected, .failed: return Theme.Colors.error
        }
    }

    /// The remote's own words for a refusal, not a paraphrase: "non-fast-forward" and "protected
    /// branch" need different fixes, and only the remote knows which it was.
    static func label(_ outcome: PushResult.Outcome) -> String {
        switch outcome {
        case .pushed(let isNew): return isNew ? "created there" : "pushed"
        case .upToDate: return "already up to date"
        case .rejected(let reason): return "rejected — \(reason)"
        case .failed(let message): return message
        }
    }
}
