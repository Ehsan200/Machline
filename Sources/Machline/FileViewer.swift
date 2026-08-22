import HarnessCore
import SwiftUI

/// A file, read and coloured.
///
/// Exists because "open" used to mean handing the path to another application. Reading a file the
/// agent just touched should not require leaving the window — and the system editor has no idea
/// which lines the agent changed.
struct FileViewer: View {
    @Bindable var model: AppModel
    let path: String

    @Environment(\.dismiss) private var dismiss

    @State private var contents: String?
    @State private var failure: String?
    @State private var isLoading = true

    /// Files above this are shown from the top only. Colouring a megabyte in one pass, on the main
    /// actor, during a sheet animation, is not something to do eagerly.
    private nonisolated static let byteLimit = 512 * 1024

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline(color: Theme.Colors.border)
            body_
        }
        .frame(width: 900, height: 660)
        .background(Theme.Colors.canvas)
        .onExitCommand { dismiss() }
        .task { await load() }
    }

    @ViewBuilder
    private var body_: some View {
        if isLoading {
            HStack(spacing: Theme.Space.sm) {
                Spinner(size: 11, color: Theme.Colors.subtle)
                Text("Reading…")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.subtle)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let failure {
            Text(failure)
                .font(Theme.Typography.control)
                .foregroundStyle(Theme.Colors.subtle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let contents {
            ScrollView([.vertical, .horizontal]) {
                HStack(alignment: .top, spacing: 0) {
                    lineNumbers(for: contents)
                    // One `Text` for the whole file: selection cannot cross separate views, so a
                    // per-line stack could only ever be copied one line at a time.
                    Text(highlighted(contents))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, Theme.Space.md)
                }
                .padding(.vertical, Theme.Space.md)
            }
        }
    }

    private func lineNumbers(for contents: String) -> some View {
        let count = contents.reduce(into: 1) { total, character in
            if character == "\n" { total += 1 }
        }
        var gutter = AttributedString(
            (1...max(count, 1)).map(String.init).joined(separator: "\n"))
        gutter.font = Theme.Typography.monoSmall
        gutter.foregroundColor = Theme.Colors.subtle

        return Text(gutter)
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, Theme.Space.sm)
            .frame(minWidth: 44, alignment: .trailing)
    }

    /// Applies the scanner's spans to the source.
    private func highlighted(_ source: String) -> AttributedString {
        var output = AttributedString(source)
        output.font = Theme.Typography.monoSmall
        output.foregroundColor = Theme.Colors.text

        // Routed through the filename so a single-file component gets each of its regions scanned
        // with the language that region actually holds.
        for span in SyntaxHighlighter.spans(in: source, fileName: path) {
            guard let lower = AttributedString.Index(span.range.lowerBound, within: output),
                  let upper = AttributedString.Index(span.range.upperBound, within: output)
            else { continue }
            output[lower..<upper].foregroundColor = colour(for: span.kind)
        }
        return output
    }

    private func colour(for kind: SyntaxSpan.Kind) -> Color {
        switch kind {
        case .comment: return Theme.Colors.subtle
        case .string: return Theme.Colors.success
        case .keyword: return Theme.Colors.accent
        case .number: return Theme.Colors.code
        case .type: return Theme.Colors.link
        case .plain: return Theme.Colors.text
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.md) {
            FileIconView(path: path, size: 12)
            Text(path)
                .font(Theme.Typography.monoStrong)
                .foregroundStyle(Theme.Colors.textStrong)
                .lineLimit(1)
                .truncationMode(.middle)

            if !SyntaxHighlighter.canHighlight(fileName: path) {
                // Said rather than silently shown plain, so unhighlighted does not read as broken.
                Text("no highlighting for this type")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.subtle)
            }

            Spacer(minLength: Theme.Space.md)

            if let contents { CopyButton(text: contents, help: "Copy the file") }
            QuietButton(title: "Open externally") { model.openFile(path: path) }
            QuietButton(title: "Show in Finder") { model.revealInFinder(path: path) }
            IconButton(systemName: "xmark", help: "Close (esc)") { dismiss() }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
    }

    private func load() async {
        // Resolved through the model, which knows a Git path is relative to its repository rather
        // than to the workspace.
        guard let url = model.fileURL(for: path) else {
            failure = "Could not find \(path) on disk."
            isLoading = false
            return
        }

        // A tuple rather than `Result`: the failure here is a sentence for the operator, not an
        // error to be thrown or matched on.
        let outcome = await Task.detached(
            priority: .userInitiated
        ) { () -> (text: String?, message: String?) in
            guard let data = try? Data(contentsOf: url) else {
                return (nil, "Could not read \(url.lastPathComponent).")
            }
            // A binary file rendered as text is a screenful of replacement characters.
            guard let text = String(data: data, encoding: .utf8) else {
                return (nil, "Not a text file.")
            }
            guard data.count <= Self.byteLimit else {
                let prefix = String(text.prefix(Self.byteLimit / 2))
                return (prefix + "\n\n… truncated — open externally for the whole file.", nil)
            }
            return (text, nil)
        }.value

        contents = outcome.text
        failure = outcome.message
        isLoading = false
    }
}
