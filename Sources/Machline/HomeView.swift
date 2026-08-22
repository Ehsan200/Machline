import HarnessCore
import SwiftUI

/// What an empty window shows.
///
/// A window with no project used to say "Nothing selected", which is true and useless. The work
/// the operator might return to already exists on disk — every project the CLI has a transcript
/// for — so the empty state offers it instead of asking them to go find a folder.
struct HomeView: View {
    @Bindable var model: AppModel

    @State private var draft = ""
    @FocusState private var isComposerFocused: Bool

    @Environment(\.openWindow) private var openWindow

    /// Past this many chips the row stops being a glance and becomes a list; the rest stay one
    /// click away in the rail's project menu.
    private static let chipLimit = 20

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xxl) {
                header
                projectChips
                projects
            }
            .padding(.horizontal, Theme.Space.xxl)
            .padding(.top, 56)
            .padding(.bottom, Theme.Space.xxl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .task {
            model.loadHome()
            // The chips come from every project the CLI knows about, not only the handful with
            // recent sessions below.
            model.loadKnownProjects()
            isComposerFocused = true
        }
    }

    // MARK: - Project chips

    /// Every project as one wrapped row, above the recent-session detail.
    ///
    /// The sections below are deep — a project and its conversations — and reaching the tenth
    /// project meant scrolling past nine of those. The chips are the shallow index over the same
    /// set: one click to open, ⌘-click for a second window.
    @ViewBuilder
    private var projectChips: some View {
        let all = model.knownProjects.isEmpty ? model.recentProjects : model.knownProjects
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                SectionLabel("Projects", trailing: "\(all.count)")

                ChipFlow(spacing: Theme.Space.sm) {
                    ForEach(all.prefix(Self.chipLimit), id: \.self) { url in
                        ProjectChip(
                            workspace: url,
                            onOpen: { model.open(workspace: url) },
                            onOpenInNewWindow: {
                                openWindow(
                                    id: "session",
                                    value: WindowTarget(workspace: url, isUnique: true))
                            })
                    }
                }

                if all.count > Self.chipLimit {
                    Text("\(all.count - Self.chipLimit) more in the project menu")
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.subtle)
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text("What are we working on?")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.Colors.textStrong)

            // The composer is the page's first action, not a band at its foot: the shortest path
            // to a question should be typing, and a footer made it the last thing found.
            composer

            HStack(spacing: Theme.Space.md) {
                QuietButton(title: "Open a project…") {
                    guard let url = WorkspacePicker.choose() else { return }
                    model.open(workspace: url)
                }
                Text("⌘O")
                    .font(Theme.Typography.monoMeta)
                    .foregroundStyle(Theme.Colors.subtle)
                Spacer(minLength: 0)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft)
                    .font(Theme.Typography.prose)
                    .foregroundStyle(Theme.Colors.textStrong)
                    .scrollContentBackground(.hidden)
                    .background(.clear)
                    .focused($isComposerFocused)
                    .frame(height: 76)
                    .padding(.horizontal, Theme.Space.md - 5)
                    .padding(.top, Theme.Space.md - 4)
                    .onKeyPress(phases: .down) { press in
                        guard press.key == .return,
                              !press.modifiers.contains(.shift) else { return .ignored }
                        start()
                        return .handled
                    }

                if draft.isEmpty {
                    Text("Ask anything…")
                        .font(Theme.Typography.prose)
                        .foregroundStyle(Theme.Colors.subtle)
                        .padding(.horizontal, Theme.Space.md)
                        .padding(.top, Theme.Space.md)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: Theme.Space.sm) {
                // Says what this is without a paragraph explaining it.
                Label("no project · no tools", systemImage: "shield")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.subtle)
                    .labelStyle(.titleAndIcon)

                Spacer(minLength: Theme.Space.md)

                Text("↵")
                    .font(Theme.Typography.monoMeta)
                    .foregroundStyle(Theme.Colors.subtle)

                QuietButton(
                    title: "Send",
                    role: .primary,
                    isEnabled: !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    start()
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.bottom, Theme.Space.sm)
            .padding(.top, Theme.Space.xs)
        }
        .background(Theme.Colors.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isComposerFocused ? Theme.Colors.accent.opacity(0.55) : Theme.Colors.border,
                    lineWidth: 1))
        .animation(.easeOut(duration: 0.12), value: isComposerFocused)
    }

    private func start() {
        let text = draft
        draft = ""
        model.openScratch(startingWith: text)
    }

    // MARK: - Projects

    @ViewBuilder
    private var projects: some View {
        if model.isLoadingHome && model.homeProjects.isEmpty {
            HStack(spacing: Theme.Space.sm) {
                Spinner(size: 11, color: Theme.Colors.subtle)
                Text("Reading your projects…")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.subtle)
            }
        } else if !model.homeProjects.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                SectionLabel("Recent")

                ForEach(model.homeProjects, id: \.workspace) { project in
                    projectSection(project.workspace, sessions: project.sessions)
                }

                if model.isLoadingHome {
                    HStack(spacing: Theme.Space.sm) {
                        Spinner(size: 10, color: Theme.Colors.subtle)
                        Text("Refreshing…")
                            .font(Theme.Typography.meta)
                            .foregroundStyle(Theme.Colors.subtle)
                    }
                }
            }
        }
    }

    private func projectSection(_ workspace: URL, sessions: [HistoricalSession]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Button {
                model.open(workspace: workspace)
            } label: {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.subtle)
                    Text(workspace.lastPathComponent)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Colors.textStrong)
                    // The parent disambiguates two projects sharing a leaf name.
                    Text(workspace.deletingLastPathComponent().path)
                        .font(Theme.Typography.monoMeta)
                        .foregroundStyle(Theme.Colors.subtle)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(workspace.path)")

            VStack(alignment: .leading, spacing: 0) {
                ForEach(sessions) { session in
                    HomeSessionRow(
                        title: model.title(for: session),
                        age: session.lastActivityAt.relativeLabel,
                        branch: session.gitBranch
                    ) {
                        model.openFromHome(workspace: workspace, session: session)
                    }
                }
            }
            .background(Theme.Colors.panel)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Layout.radius))
        }
    }
}

/// One project, small enough to sit beside a dozen others.
private struct ProjectChip: View {
    let workspace: URL
    let onOpen: () -> Void
    let onOpenInNewWindow: () -> Void

    var body: some View {
        Pill(
            title: workspace.lastPathComponent,
            systemImage: "folder",
            help: "\(workspace.path) — ⌘-click opens a new window"
        ) {
            if NSEvent.isCommandHeld { onOpenInNewWindow() } else { onOpen() }
        }
        .contextMenu {
            Button("Open") { onOpen() }
            Button("Open in New Window") { onOpenInNewWindow() }
        }
    }
}

/// Lays chips out left to right, wrapping onto as many rows as they need.
///
/// Neither stack wraps, and a grid would impose one column width on labels that run from `api` to
/// `internal-tooling-service`, leaving most of the row empty.
struct ChipFlow: Layout {
    var spacing: CGFloat = Theme.Space.sm

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, maxWidth: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height }
            + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? (rows.map(\.width).max() ?? 0), height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for row in rows(for: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(for subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            // A chip wider than the whole row still gets a row of its own rather than vanishing.
            if width > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                current.indices.append(index)
                current.width = width
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

private struct HomeSessionRow: View {
    let title: String
    let age: String
    let branch: String?
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Theme.Space.md) {
                Text(title)
                    .font(Theme.Typography.control)
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)

                Spacer(minLength: Theme.Space.sm)

                if let branch, !branch.isEmpty, branch != "HEAD" {
                    Text(branch)
                        .font(Theme.Typography.monoMeta)
                        .foregroundStyle(Theme.Colors.subtle)
                }
                Text(age)
                    .font(Theme.Typography.monoMeta)
                    .foregroundStyle(Theme.Colors.subtle)
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
            .rowSurface(isSelected: false, isHovering: isHovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
