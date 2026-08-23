import HarnessCore
import SwiftUI

/// Pins a piece of the conversation to the next message.
///
/// The sibling of `CopyButton`, and it sits beside one wherever both make sense: copying takes text
/// out of the app, quoting keeps it here and hands it to the agent with a note saying where it came
/// from. Asking about a code block should not mean copying it, switching to the composer, pasting
/// it, and then typing an explanation of what was just pasted.
struct QuoteButton: View {
    let model: AppModel
    let text: String
    let source: QuotedSelection.Source
    var help: String = "Quote this in your next message"

    @State private var hasQuoted = false

    var body: some View {
        Button {
            model.quote(text, from: source)
            hasQuoted = true
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                hasQuoted = false
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: hasQuoted ? "checkmark" : "text.quote")
                    .font(.system(size: 9, weight: .medium))
                if hasQuoted {
                    Text("quoted")
                        .font(Theme.Typography.meta)
                }
            }
            .foregroundStyle(hasQuoted ? Theme.Colors.success : Theme.Colors.subtle)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The pinned quotes, as chips above the input.
///
/// Its own view, reading nothing but `quotes`: the composer is rebuilt on every keystroke and on
/// every streaming update behind it, and a chip row folded into that body would be rebuilt with it.
/// Empty means an empty view, so a composer with no quotes is the same height it always was.
struct QuoteChipRow: View {
    @Bindable var model: AppModel

    var body: some View {
        if !model.quotes.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(model.quotes) { quote in
                        chip(quote)
                    }
                }
                .padding(.horizontal, Theme.Space.lg)
                .padding(.vertical, Theme.Space.sm)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Hairline()
        }
    }

    private func chip(_ quote: QuotedSelection) -> some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "text.quote")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.Colors.accent)

            Text(quote.label)
                .font(Theme.Typography.monoMeta)
                .foregroundStyle(Theme.Colors.text)
                .lineLimit(1)

            // The label says what it is; the snippet says which one, for two quotes off the same
            // file or two replies of the same length.
            let snippet = quote.snippet()
            if !snippet.isEmpty {
                Text(snippet)
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.subtle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 220, alignment: .leading)
            }

            Button {
                model.removeQuote(quote.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.Colors.subtle)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove this quote")
        }
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: Theme.Layout.radius)
                .fill(Theme.Colors.accent.opacity(0.10)))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Layout.radius)
                .strokeBorder(Theme.Colors.accent.opacity(0.35), lineWidth: Theme.Layout.hairline))
        .help(quote.text.count > 600 ? String(quote.text.prefix(600)) + "…" : quote.text)
    }
}

/// The quote control over an expanded tool result.
///
/// Output is the thing most worth quoting — a stack trace, a failing test, a `git status` nobody
/// wants to retype — and it is also the thing least worth reading twice, so the control sits above
/// it rather than inside the scrolling text where it would have to be hunted for.
struct QuoteOutputRow: View {
    let model: AppModel
    let text: String

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Spacer(minLength: 0)
            QuoteButton(
                model: model, text: text, source: .toolOutput,
                help: "Quote this output in your next message")
        }
        .padding(.trailing, Theme.Space.md)
        .padding(.bottom, 2)
    }
}

/// The Edit-menu entry behind ⌘⇧'.
///
/// A menu item rather than a button on the selection: SwiftUI's selectable `Text` reports neither
/// that a selection exists nor where it is, so there is nowhere to put a floating control and
/// nothing to key its appearance on. See `AppModel.quoteSelection`.
struct QuoteCommands: View {
    @FocusedValue(\.windowModel) private var window

    var body: some View {
        Button("Quote Selection") { window?.current.quoteSelection() }
            .keyboardShortcut("'", modifiers: [.command, .shift])
            .disabled(window == nil)
    }
}
