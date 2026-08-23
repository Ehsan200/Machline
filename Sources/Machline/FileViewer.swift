import HarnessCore
import SwiftUI

/// A file, read and coloured — and now editable.
///
/// Reading a file the agent just touched should not mean leaving the window, and the system editor
/// has no idea which lines it changed. Editing is here for the same reason: the change after a diff
/// is usually three lines, and the round trip out is longer than the edit. Not a replacement for a
/// real editor — no completion, no rename, no jump to definition.
struct FileViewer: View {
    @Bindable var model: AppModel
    let path: String

    @Environment(\.dismiss) private var dismiss

    @State private var editor = EditorModel()
    @State private var gutter = EditorGutterModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline(color: Theme.Colors.border)
            if let failure = editor.saveFailure {
                saveFailureStrip(failure)
            }
            body_
        }
        .frame(width: 900, height: 660)
        .background(Theme.Colors.canvas)
        .selectableTextTint()
        .onExitCommand { dismiss() }
        .task { await load() }
        // The pending autosave dies with this view; closing must not lose half a second of edit.
        .onDisappear { editor.flush() }
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
                GutterView(model: gutter)
                CodeEditor(
                    text: buffer.contents,
                    revision: editor.revision,
                    fileName: path,
                    isEditable: true,
                    onEdit: { editor.edited($0) },
                    saveGeneration: editor.saveGeneration,
                    gutter: gutter)
            }
        }
    }

    /// A write that did not happen sits where the next keystroke cannot push it off screen.
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
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.warning.opacity(0.10))
    }

    private var header: some View {
        HStack(spacing: Theme.Space.md) {
            FileIconView(path: path, size: 12)
            Text(path)
                .font(Theme.Typography.monoStrong)
                .foregroundStyle(Theme.Colors.textStrong)
                .lineLimit(1)
                .truncationMode(.middle)

            if editor.buffer != nil, !SyntaxHighlighter.canHighlight(fileName: path) {
                // Said rather than silently shown plain, so unhighlighted does not read as broken.
                Text("no highlighting for this type")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.subtle)
            }

            Spacer(minLength: Theme.Space.md)

            if editor.buffer != nil {
                saveControls
            }

            if let contents = editor.buffer?.contents {
                QuoteButton(
                    model: model, text: contents, source: .file(path: path, lines: nil),
                    help: "Quote this file in your next message")
                CopyButton(text: contents, help: "Copy the file")
            }
            QuietButton(title: "Open externally") { model.openFile(path: path) }
            QuietButton(title: "Show in Finder") { model.revealInFinder(path: path) }
            IconButton(systemName: "xmark", help: "Close (esc)") { dismiss() }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
    }

    /// Shown even while autosave is on: "it saves itself" only reassures if you can see it happen.
    @ViewBuilder
    private var saveControls: some View {
        Text(editor.isDirty ? "Unsaved" : "Saved")
            .font(Theme.Typography.meta)
            .foregroundStyle(editor.isDirty ? Theme.Colors.warning : Theme.Colors.subtle)

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
    }

    private func load() async {
        // Resolved through the model, which knows a Git path is relative to its repository rather
        // than to the workspace.
        guard let url = model.fileURL(for: path) else {
            editor.reportMissing(path)
            return
        }
        await editor.load(url)
    }
}
