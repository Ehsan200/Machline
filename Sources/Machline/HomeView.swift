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
    @State private var projectSearch = ""
    @FocusState private var isComposerFocused: Bool
    @FocusState private var isProjectSearchFocused: Bool

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
            // Opening a window is nearly always about getting back into a project, so the caret
            // starts in the project filter. The composer is one Tab or one click away.
            isProjectSearchFocused = true
        }
        // The projects arrive after the first frame; the field only exists once they do, so the
        // focus has to be asked for again when it appears.
        .onChange(of: allProjects.isEmpty) { _, isEmpty in
            if isEmpty { isComposerFocused = true } else { isProjectSearchFocused = true }
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
        let all = allProjects
        if !all.isEmpty {
            let matches = Self.matching(all, query: projectSearch)
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                SectionLabel(
                    "Projects",
                    trailing: matches.count == all.count
                        ? "\(all.count)" : "\(matches.count)/\(all.count)")

                projectSearchField(matches: matches)

                let shown = Array(matches.prefix(Self.chipLimit))
                let ambiguous = Self.ambiguousNames(in: shown)

                ChipFlow(spacing: Theme.Space.sm) {
                    ForEach(shown, id: \.self) { url in
                        ProjectChip(
                            workspace: url,
                            // Only where it earns its width: `IOP` says nothing when three
                            // clients each have one, and everything once it is `IOP · Kavish`.
                            detail: ambiguous.contains(url.lastPathComponent)
                                ? url.deletingLastPathComponent().lastPathComponent
                                : nil,
                            onOpen: { model.open(workspace: url) },
                            onOpenInNewWindow: {
                                openWindow(
                                    id: "session",
                                    value: WindowTarget(workspace: url, isUnique: true))
                            },
                            onRemove: { model.removeProject(url) })
                    }
                }

                if matches.count > Self.chipLimit {
                    Text("\(matches.count - Self.chipLimit) more — narrow the filter to reach them")
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.subtle)
                }

                if matches.isEmpty {
                    Text("No project matches “\(projectSearch)”")
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.subtle)
                }

                // Only shown when there is something to undo, and it says how much.
                if model.removedProjectCount > 0 {
                    QuietButton(
                        title: "Show \(model.removedProjectCount) removed"
                    ) {
                        model.restoreRemovedProjects()
                    }
                }
            }
        }
    }

    /// Every project the CLI knows about, falling back to the recent handful before that list
    /// lands.
    private var allProjects: [URL] {
        model.knownProjects.isEmpty ? model.recentProjects : model.knownProjects
    }

    /// The filter over the chips, and the window's first responder.
    ///
    /// Twenty chips is a lot to read; typing three letters is faster than finding the right one by
    /// eye, and Return opens the top match without ever reaching for the mouse.
    private func projectSearchField(matches: [URL]) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Colors.subtle)

            TextField("Filter projects", text: $projectSearch)
                .textFieldStyle(.plain)
                .font(Theme.Typography.control)
                .foregroundStyle(Theme.Colors.text)
                .focused($isProjectSearchFocused)
                .onKeyPress(phases: .down) { press in
                    switch press.key {
                    case .return:
                        guard let first = matches.first else { return .ignored }
                        if press.modifiers.contains(.command) {
                            openWindow(
                                id: "session",
                                value: WindowTarget(workspace: first, isUnique: true))
                        } else {
                            model.open(workspace: first)
                        }
                        return .handled
                    case .escape:
                        guard !projectSearch.isEmpty else { return .ignored }
                        projectSearch = ""
                        return .handled
                    default:
                        return .ignored
                    }
                }

            if !projectSearch.isEmpty {
                IconButton(systemName: "xmark.circle.fill", help: "Clear filter") {
                    projectSearch = ""
                }
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(Theme.Colors.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Layout.radius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Layout.radius)
                .strokeBorder(
                    isProjectSearchFocused
                        ? Theme.Colors.accent.opacity(0.55) : Theme.Colors.border,
                    lineWidth: 1))
        .animation(.easeOut(duration: 0.12), value: isProjectSearchFocused)
    }

    /// Matches the project's own name and the path above it, so `iop/api` finds the one `api` that
    /// belongs to that client.
    static func matching(_ workspaces: [URL], query: String) -> [URL] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return workspaces }
        return workspaces.filter { $0.path.lowercased().contains(query) }
    }

    /// Leaf names carried by more than one of these projects.
    static func ambiguousNames(in workspaces: [URL]) -> Set<String> {
        var counts: [String: Int] = [:]
        for url in workspaces { counts[url.lastPathComponent, default: 0] += 1 }
        return Set(counts.filter { $0.value > 1 }.keys)
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
                Label("no project · scratch folder", systemImage: "tray")
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

    /// The one filter narrows the detail below the chips too — a page half-filtered would read as
    /// a bug.
    private var recentMatches: [(workspace: URL, sessions: [HistoricalSession])] {
        let query = projectSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return model.homeProjects }
        return model.homeProjects.filter { $0.workspace.path.lowercased().contains(query) }
    }

    @ViewBuilder
    private var projects: some View {
        if model.isLoadingHome && model.homeProjects.isEmpty {
            HStack(spacing: Theme.Space.sm) {
                Spinner(size: 11, color: Theme.Colors.subtle)
                Text("Reading your projects…")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.subtle)
            }
        } else if !recentMatches.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                SectionLabel("Recent")

                ForEach(recentMatches, id: \.workspace) { project in
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
            .contextMenu {
                Button("Open") { model.open(workspace: workspace) }
                Divider()
                Button("Remove from Machline", role: .destructive) {
                    model.removeProject(workspace)
                }
            }

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
    /// The parent's name, when the project's own name is shared with another chip.
    var detail: String?
    let onOpen: () -> Void
    let onOpenInNewWindow: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Pill(
            title: workspace.lastPathComponent,
            detail: detail,
            systemImage: "folder",
            help: "\(workspace.path) — ⌘-click opens a new window"
        ) {
            if NSEvent.isCommandHeld { onOpenInNewWindow() } else { onOpen() }
        }
        .contextMenu {
            Button("Open") { onOpen() }
            Button("Open in New Window") { onOpenInNewWindow() }
            Divider()
            // Removes it from this app's lists only. Nothing on disk is touched.
            Button("Remove from Machline", role: .destructive) { onRemove() }
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
