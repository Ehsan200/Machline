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

    var body: some View {
        VStack(spacing: 0) {
            content
            Hairline()
            scratchComposer
        }
    }

    /// Ask something without choosing a project first.
    ///
    /// The homepage used to be a list and nothing else, so the shortest path to a question was
    /// open a project, wait, then type — for a question that had nothing to do with that project.
    /// Typing here starts a scratch chat instead, which runs with no tools at all.
    private var scratchComposer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.subtle)
                    .padding(.top, 3)

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $draft)
                        .font(Theme.Typography.prose)
                        .foregroundStyle(Theme.Colors.textStrong)
                        .scrollContentBackground(.hidden)
                        .background(.clear)
                        .focused($isComposerFocused)
                        .frame(height: 52)
                        .onKeyPress(phases: .down) { press in
                            guard press.key == .return,
                                  !press.modifiers.contains(.shift) else { return .ignored }
                            start()
                            return .handled
                        }

                    if draft.isEmpty {
                        Text("Ask anything — no project, no tools")
                            .font(Theme.Typography.prose)
                            .foregroundStyle(Theme.Colors.subtle)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }

                QuietButton(
                    title: "Send",
                    role: .primary,
                    isEnabled: !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    start()
                }
            }

            Text("Scratch chats have no tools: nothing is read, written, or run.")
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.Colors.subtle)
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(Theme.Colors.panel)
    }

    private func start() {
        let text = draft
        draft = ""
        model.openScratch(startingWith: text)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                header

                if model.isLoadingHome && model.homeProjects.isEmpty {
                    HStack(spacing: Theme.Space.sm) {
                        Spinner(size: 11, color: Theme.Colors.subtle)
                        Text("Reading your projects…")
                            .font(Theme.Typography.meta)
                            .foregroundStyle(Theme.Colors.subtle)
                    }
                } else if model.homeProjects.isEmpty && !model.isLoadingHome {
                    Text("No conversations on this machine yet. Open a project to start one.")
                        .font(Theme.Typography.control)
                        .foregroundStyle(Theme.Colors.subtle)
                } else {
                    ForEach(model.homeProjects, id: \.workspace) { project in
                        projectSection(project.workspace, sessions: project.sessions)
                    }

                    // Says so rather than leaving the operator wondering whether this is all of it.
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
            .padding(Theme.Space.xxl)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .task {
            model.loadHome()
            isComposerFocused = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Machline")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.Colors.textStrong)
            Text("Pick up where you left off, or open a project.")
                .font(Theme.Typography.prose)
                .foregroundStyle(Theme.Colors.muted)

            HStack(spacing: Theme.Space.md) {
                QuietButton(title: "Open Project…", role: .primary) {
                    guard let url = WorkspacePicker.choose() else { return }
                    model.open(workspace: url)
                }
                Text("⌘O")
                    .font(Theme.Typography.monoMeta)
                    .foregroundStyle(Theme.Colors.subtle)

                // Not every question belongs to a repository, and opening one to ask an unrelated
                // question files the answer in that repository's history.
                QuietButton(title: "Scratch chat") { model.openScratch() }
                    .help("A chat with no project and no tools")
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
            .background(isHovering ? Theme.Colors.hover.opacity(0.6) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
