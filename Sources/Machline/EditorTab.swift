import HarnessCore
import Observation
import SwiftUI

/// One file open in the lower pane.
///
/// A class, and held by `AppModel` rather than by the view, because a tab that is not showing must
/// keep its buffer, its unsaved edits and its undo stack. Rebuilding it on every switch would make
/// changing tabs a way to lose work.
@MainActor
@Observable
final class EditorTab: @MainActor Identifiable {
    let path: String
    let editor = EditorModel()
    let gutter = EditorGutterModel()

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }

    init(path: String) {
        self.path = path
    }
}

/// One tab in the lower pane's strip.
struct PaneTab: View {
    let title: String
    let systemImage: String?
    let isSelected: Bool
    /// Shown as a dot rather than a word: the strip is narrow and the state is binary.
    let isDirty: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9))
                    .foregroundStyle(isSelected ? Theme.Colors.text : Theme.Colors.subtle)
            }
            Text(title)
                .font(Theme.Typography.monoMeta)
                .foregroundStyle(isSelected ? Theme.Colors.textStrong : Theme.Colors.subtle)
                .lineLimit(1)

            // The close control replaces the dot under the pointer, so the tab never changes width.
            if isHovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.Colors.muted)
                        .frame(width: 10, height: 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Circle()
                    .fill(isDirty ? Theme.Colors.warning : Color.clear)
                    .frame(width: 5, height: 5)
                    .frame(width: 10, height: 10)
            }
        }
        .padding(.horizontal, Theme.Space.sm)
        .frame(height: 22)
        .background(isSelected ? Theme.Colors.surface : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .help(title)
    }
}

/// A file, read and coloured, open for editing beside the conversation.
///
/// In the pane rather than in a sheet because the reason to edit here at all is that the agent's
/// output is still on screen. A modal over the timeline gives up exactly what the round trip to
/// another editor was giving up.
struct EditorTabView: View {
    @Bindable var model: AppModel
    let tab: EditorTab

    private var editor: EditorModel { tab.editor }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Hairline(color: Theme.Colors.divider)
            if let conflict = editor.conflict {
                conflictStrip(conflict)
            } else if let failure = editor.saveFailure {
                saveFailureStrip(failure)
            }
            body_
        }
        .background(Theme.Colors.canvas)
        .selectableTextTint()
        .task { await load() }
        // The agent edits while this is open, so the margin follows the Git panel's own refresh.
        .onChange(of: model.git?.revision ?? 0, initial: true) { refreshMarks() }
        // The margin asks Git about this one file and lands in tens of milliseconds; the Changes
        // list needs the whole repository and can take its time.
        .onChange(of: editor.saveGeneration) {
            Task { await refreshMarksFromGit() }
            model.git?.refresh()
        }
    }

    @ViewBuilder
    private var body_: some View {
        if editor.isLoading {
            HStack(spacing: Theme.Space.sm) {
                Spinner(size: 11, color: Theme.Colors.subtle)
                Text("Reading…")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.subtle)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let failure = editor.failure {
            Text(failure)
                .font(Theme.Typography.control)
                .foregroundStyle(Theme.Colors.subtle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let buffer = editor.buffer {
            HStack(spacing: 0) {
                GutterView(model: tab.gutter)
                CodeEditor(
                    text: buffer.contents,
                    revision: editor.revision,
                    fileName: tab.path,
                    isEditable: true,
                    onEdit: { editor.edited($0) },
                    saveGeneration: editor.saveGeneration,
                    gutter: tab.gutter)
            }
        }
    }

    /// The other writer got here first. Autosave stops while this is up, and neither answer is
    /// taken on the operator's behalf — both lose something.
    @ViewBuilder
    private func conflictStrip(_ conflict: EditConflict.Decision) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: conflict == .vanished ? "trash" : "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Colors.warning)
            Text(conflict == .vanished
                ? "This file was deleted while you were editing it."
                : "The agent changed this file while you were editing it. Autosave is paused.")
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.Colors.warning)

            Spacer(minLength: Theme.Space.md)

            if conflict != .vanished {
                QuietButton(title: "Use theirs") { editor.reloadFromDisk() }
            }
            QuietButton(title: "Keep mine") { editor.overwriteDisk() }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.warning.opacity(0.12))
    }

    private func saveFailureStrip(_ text: String) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Colors.warning)
            Text(text)
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.Colors.warning)
            Spacer(minLength: Theme.Space.md)
            QuietButton(title: "Save anyway") { editor.save(force: true) }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.warning.opacity(0.10))
    }

    /// The file's own controls. The path and the close button live on the tab, so this carries only
    /// what belongs to the buffer.
    private var toolbar: some View {
        HStack(spacing: Theme.Space.md) {
            if editor.buffer != nil, !SyntaxHighlighter.canHighlight(fileName: tab.path) {
                Text("no highlighting for this type")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.subtle)
            }

            Text(editor.isDirty ? "Unsaved" : "Saved")
                .font(Theme.Typography.meta)
                .foregroundStyle(editor.isDirty ? Theme.Colors.warning : Theme.Colors.subtle)
                .fixedSize()

            CheckBox(isOn: Binding(
                get: { editor.isAutosaveEnabled },
                set: { editor.isAutosaveEnabled = $0 })
            ) {
                Text("Autosave")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.muted)
            }

            // Kept with autosave on: a hand that presses it from habit should not meet nothing.
            Button("Save") { editor.save() }
                .buttonStyle(.plain)
                .font(Theme.Typography.meta)
                .foregroundStyle(editor.isDirty ? Theme.Colors.link : Theme.Colors.subtle)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!editor.isDirty)

            Spacer(minLength: Theme.Space.sm)

            if let contents = editor.buffer?.contents {
                QuoteButton(
                    model: model, text: contents, source: .file(path: tab.path, lines: nil),
                    help: "Quote this file in your next message")
                CopyButton(text: contents, help: "Copy the file")
            }

            // Three full-width buttons overflowed a pane this narrow, and an overflowing `HStack`
            // collapses its own spacing and clips its leading edge before it gives up any room —
            // which is what ran the controls together and ate the first word of "Saved".
            Menu {
                Button("Show diff") { model.openDiffModal(path: tab.path) }
                Button("Open externally") { model.openFile(path: tab.path) }
                Button("Show in Finder") { model.revealInFinder(path: tab.path) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Colors.muted)
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions for this file")
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: 30)
    }

    private func refreshMarks() {
        tab.gutter.marks = model.workingTreeDiff(for: tab.path).map(GitLineMarks.marks(in:)) ?? [:]
    }

    /// Asks Git about this file alone, rather than waiting for the panel's whole-repository pass.
    private func refreshMarksFromGit() async {
        guard let git = model.git else { return }
        let diff = await git.fileDiff(model.repositoryRelativePath(tab.path))
        tab.gutter.marks = diff.map(GitLineMarks.marks(in:)) ?? [:]
    }

    private func load() async {
        guard editor.buffer == nil, editor.failure == nil else { return }
        // Resolved through the model, which knows a Git path is relative to its repository rather
        // than to the workspace.
        guard let url = model.fileURL(for: tab.path) else {
            editor.reportMissing(tab.path)
            return
        }
        await editor.load(url)
    }
}
