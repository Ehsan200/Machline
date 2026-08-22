import HarnessCore
import SwiftUI

/// The agent asking the operator something.
///
/// Presented in place of the approval sheet when the gated call is `AskUserQuestion`, because it
/// is not an approval: nothing is being permitted or refused, a question is being answered. One
/// radio group per single-answer question, checkboxes when the agent will take several, and a
/// free-text field on every one — the options are the agent's guesses, and the operator may have
/// an answer it did not think of.
struct QuestionSheet: View {
    @Bindable var model: AppModel
    let pending: PendingApproval

    /// Chosen option labels, by question. A set even for single-answer questions, so one code path
    /// serves both and the radio group simply replaces rather than inserts.
    @State private var chosen: [Int: Set<String>] = [:]
    @State private var notes: [Int: String] = [:]

    private var questions: [OperatorQuestion] {
        AskUserQuestion.questions(in: pending.payload)
    }

    /// Every question needs something — a tick or some typing — before this can be sent.
    private var canSend: Bool {
        questions.allSatisfy { question in
            !(chosen[question.index]?.isEmpty ?? true)
                || !(notes[question.index] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    ForEach(questions) { question in
                        questionBlock(question)
                    }
                }
                .padding(Theme.Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 420)

            Divider()
            footer
        }
        .frame(width: 620)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: "questionmark.bubble")
                .font(.title)
                .foregroundStyle(Theme.Colors.accent)

            VStack(alignment: .leading, spacing: 3) {
                Text(questions.count > 1 ? "The agent has some questions" : "The agent has a question")
                    .font(.title3.weight(.semibold))
                Text("Your answer goes back as the result of the call it is waiting on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Countdown(deadline: pending.deadline, outcome: "until it gives up")
        }
        .padding(Theme.Space.lg)
    }

    @ViewBuilder
    private func questionBlock(_ question: OperatorQuestion) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if let heading = question.header {
                Text(heading.uppercased())
                    .font(Theme.Typography.sectionLabel)
                    .tracking(0.6)
                    .foregroundStyle(Theme.Colors.subtle)
            }

            Text(question.question)
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.Colors.textStrong)
                .fixedSize(horizontal: false, vertical: true)

            if question.allowsMultiple, !question.options.isEmpty {
                Text("Pick as many as apply.")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.subtle)
            }

            ForEach(question.options) { option in
                ChoiceRow(
                    label: option.label,
                    detail: option.detail,
                    isMultiple: question.allowsMultiple,
                    isSelected: chosen[question.index]?.contains(option.label) ?? false
                ) {
                    select(option.label, in: question)
                }
            }

            TextField(
                question.options.isEmpty ? "Your answer" : "Something else…",
                text: Binding(
                    get: { notes[question.index] ?? "" },
                    set: { notes[question.index] = $0 }),
                axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
        }
    }

    private func select(_ label: String, in question: OperatorQuestion) {
        var current = chosen[question.index] ?? []
        if question.allowsMultiple {
            if current.contains(label) { current.remove(label) } else { current.insert(label) }
        } else {
            // A radio group: picking again clears, so a mistaken tick is undoable without a
            // separate control.
            current = current.contains(label) ? [] : [label]
        }
        chosen[question.index] = current
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.md) {
            Button("Skip") { model.answer(pending, with: []) }
                .help("Sends no answer. The agent is told it was not answered.")

            Spacer(minLength: 0)

            Button("Send answer") { send() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSend)
        }
        .padding(Theme.Space.lg)
    }

    private func send() {
        let answers = questions.map { question in
            AskUserQuestion.Answer(
                question: question,
                // Back into the question's own order, so the agent reads them as it listed them.
                chosen: question.options
                    .map(\.label)
                    .filter { chosen[question.index]?.contains($0) ?? false },
                note: (notes[question.index] ?? "").trimmingCharacters(in: .whitespaces))
        }
        model.answer(pending, with: answers)
    }
}

/// One option: a radio button when the question takes one answer, a checkbox when it takes several.
private struct ChoiceRow: View {
    let label: String
    let detail: String?
    let isMultiple: Bool
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Theme.Colors.accent : Theme.Colors.subtle)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(Theme.Typography.control)
                        .foregroundStyle(Theme.Colors.textStrong)
                        .multilineTextAlignment(.leading)
                    if let detail {
                        Text(detail)
                            .font(Theme.Typography.meta)
                            .foregroundStyle(Theme.Colors.subtle)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Layout.radius)
                    .fill(isSelected
                        ? Theme.Colors.selection
                        : (isHovering ? Theme.Colors.hover.opacity(0.6) : Theme.Colors.panel)))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Layout.radius)
                    .strokeBorder(
                        isSelected ? Theme.Colors.accent.opacity(0.6) : Theme.Colors.border,
                        lineWidth: Theme.Layout.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var symbol: String {
        if isMultiple { return isSelected ? "checkmark.square.fill" : "square" }
        return isSelected ? "largecircle.fill.circle" : "circle"
    }
}
