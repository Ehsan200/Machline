import HarnessCore
import SwiftUI

/// Raw tool traffic, shown the way a terminal shows it.
///
/// Commands and their output are monospace on an inset ground, with the command on a prompt line
/// so it is distinguishable from what it printed. Nothing here is reflowed or prettified — a
/// command's own alignment is usually load-bearing, and a wrapped column of output is unreadable.
struct TerminalBlock: View {
    let command: String?
    /// Excerpts, not the whole output: this pane is a fixed height whatever it is given, so drawing
    /// the full text only buys a TextKit layout of every line — in the frame the lazy stack builds
    /// this row, which is a stall mid-scroll. See `OutputExcerpt`.
    let stdout: OutputExcerpt
    let stderr: OutputExcerpt
    var exitLabel: String?
    var isError: Bool = false
    var maxHeight: CGFloat = Theme.Layout.toolOutputMaxHeight

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let command, !command.isEmpty {
                promptLine(command)
                if hasOutput {
                    Hairline(color: Theme.Colors.border.opacity(0.6))
                }
            }

            if hasOutput {
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        if !stdout.isEmpty {
                            stream(stdout.text, tint: Theme.Colors.muted)
                        }
                        if !stderr.isEmpty {
                            stream(stderr.text, tint: Theme.Colors.error)
                        }
                    }
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.vertical, Theme.Space.sm)
                }
                .frame(maxHeight: maxHeight)
                truncationNote
            } else if command == nil {
                Text("no output")
                    .font(Theme.Typography.monoSmall)
                    .foregroundStyle(Theme.Colors.subtle)
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.vertical, Theme.Space.sm)
            }

            if let exitLabel {
                Hairline(color: Theme.Colors.border.opacity(0.6))
                Text(exitLabel)
                    .font(Theme.Typography.monoMeta)
                    .foregroundStyle(isError ? Theme.Colors.error : Theme.Colors.subtle)
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.vertical, 5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.canvas)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Layout.radius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Layout.radius)
                .strokeBorder(
                    isError ? Theme.Colors.error.opacity(0.4) : Theme.Colors.border,
                    lineWidth: Theme.Layout.hairline))
    }

    private var hasOutput: Bool { !stdout.isEmpty || !stderr.isEmpty }

    /// Says so when the pane is not showing everything. One line, present or absent for the life of
    /// the row — it never appears mid-scroll and shifts what is below it.
    @ViewBuilder
    private var truncationNote: some View {
        if let note = stdout.summary ?? stderr.summary {
            Hairline(color: Theme.Colors.border.opacity(0.6))
            Text(note)
                .font(Theme.Typography.monoMeta)
                .foregroundStyle(Theme.Colors.subtle)
                .padding(.horizontal, Theme.Space.md)
                .padding(.vertical, 5)
        }
    }

    private func promptLine(_ command: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                Text("$")
                    .font(Theme.Typography.monoStrong)
                    .foregroundStyle(Theme.Colors.accent)
                Text(command)
                    .font(Theme.Typography.monoStrong)
                    .foregroundStyle(Theme.Colors.textStrong)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
        }
    }

    /// Output is rendered as one text view, not per line: a `LazyVStack` of lines loses selection
    /// across line boundaries, which is the main thing an operator wants to do with it.
    private func stream(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(Theme.Typography.monoSmall)
            .foregroundStyle(tint)
            .textSelection(.enabled)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Replay

/// One entry from a recorded conversation. Same visual language as the live timeline, so a resumed
/// session reads as one continuous thread.
struct ReplayEntryView: View {
    @Bindable var model: AppModel
    let entry: ReplayEntry

    var body: some View {
        switch entry.kind {
        case .user(let text):
            labelled("YOU", strong: true) {
                MessageBody(text: text)
            }

        case .assistant(let text):
            labelled("AGENT", strong: false, quoting: text) {
                MarkdownView(markdown: text, model: model)
            }

        case .thinking(let text):
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                Rectangle().fill(Theme.Colors.border).frame(width: 2)
                Text(text)
                    .font(Theme.Typography.control)
                    .italic()
                    .foregroundStyle(Theme.Colors.subtle)
                    .textSelection(.enabled)
            }
            .padding(.vertical, Theme.Space.sm)

        case .toolCall(let name, let detail):
            ReplayToolView(model: model, rowKey: .replay(entry.id), name: name, detail: detail)

        case .toolResult(let text, let excerpt, let isError):
            ReplayResultView(
                model: model, rowKey: .replay(entry.id),
                text: text, excerpt: excerpt, isError: isError)
        }
    }

    /// `quoting` is what the label's quote control pins; absent where there is nothing worth
    /// quoting, like the operator's own message.
    private func labelled(
        _ label: String, strong: Bool, quoting: String? = nil,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Text(label)
                    .font(Theme.Typography.sectionLabel)
                    .tracking(0.8)
                    .foregroundStyle(Theme.Colors.muted)
                Spacer(minLength: 0)
                if let quoting {
                    QuoteButton(
                        model: model, text: quoting, source: .reply,
                        help: "Quote this reply in your next message")
                }
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(strong ? Theme.Space.lg : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(strong ? Theme.Colors.surface : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Layout.radius))
        .padding(.top, strong ? Theme.Space.xxl : Theme.Space.xl)
        .padding(.bottom, strong ? Theme.Space.md : Theme.Space.sm)
    }
}

/// A recorded tool call. Collapsed to one row; expanding shows the command as a terminal block.
struct ReplayToolView: View {
    @Bindable var model: AppModel
    /// Keys this row's open/closed state, which outlives the row itself — see `isRowExpanded`.
    let rowKey: AppModel.RowKey
    let name: String
    let detail: String

    private var isExpanded: Bool { model.isRowExpanded(rowKey) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToolDisclosureRow(
                name: name,
                detail: detail,
                statusIcon: nil,
                statusTint: Theme.Colors.subtle,
                isExpanded: model.rowExpansionBinding(rowKey))

            if isExpanded {
                TerminalBlock(command: detail, stdout: .empty, stderr: .empty)
                    .padding(.leading, Theme.Space.xl)
                    .padding(.trailing, Theme.Space.md)
                    .padding(.bottom, Theme.Space.sm)
            }
        }
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.Colors.border).frame(width: 2)
        }
    }
}

/// A recorded tool result. Errors open by default — they are the ones that changed what happened
/// next.
struct ReplayResultView: View {
    @Bindable var model: AppModel
    let rowKey: AppModel.RowKey
    /// The whole result, for quoting. Never drawn — that is what `excerpt` is for.
    let text: String
    let excerpt: OutputExcerpt
    let isError: Bool

    private var isExpanded: Bool { model.isRowExpanded(rowKey, whenUnset: isError) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToolDisclosureRow(
                name: isError ? "Blocked" : "Result",
                detail: excerpt.firstLine,
                statusIcon: isError ? "xmark.circle" : "checkmark",
                statusTint: isError ? Theme.Colors.error : Theme.Colors.success,
                isExpanded: model.rowExpansionBinding(rowKey, whenUnset: isError))

            if isExpanded, !text.isEmpty {
                QuoteOutputRow(model: model, text: text)
                TerminalBlock(
                    command: nil,
                    stdout: isError ? .empty : excerpt,
                    stderr: isError ? excerpt : .empty,
                    isError: isError)
                    .padding(.leading, Theme.Space.xl)
                    .padding(.trailing, Theme.Space.md)
                    .padding(.bottom, Theme.Space.sm)
            }
        }
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.Colors.border).frame(width: 2)
        }
    }
}

/// The one compact row every tool event collapses to: name, purpose, status, disclosure.
struct ToolDisclosureRow: View {
    let name: String
    let detail: String
    var statusIcon: String?
    var statusTint: Color = Theme.Colors.subtle
    var trailing: String?
    @Binding var isExpanded: Bool

    @State private var isHovering = false

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.Colors.subtle)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))

                if let statusIcon {
                    Image(systemName: statusIcon)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(statusTint)
                }

                Text(name)
                    .font(Theme.Typography.controlMedium)
                    .foregroundStyle(Theme.Colors.muted)

                Text(detail)
                    .font(Theme.Typography.monoSmall)
                    .foregroundStyle(Theme.Colors.subtle)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: Theme.Space.sm)

                if let trailing {
                    Text(trailing)
                        .font(Theme.Typography.monoMeta)
                        .foregroundStyle(statusTint)
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? Theme.Colors.surface.opacity(0.5) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
