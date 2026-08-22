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
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xxl) {
                header
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
            isComposerFocused = true
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
