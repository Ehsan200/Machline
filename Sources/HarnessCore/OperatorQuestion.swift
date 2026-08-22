import Foundation

/// A question the agent is asking the operator, as it arrives on the approval channel.
///
/// The runtime asks by calling a tool, so the request reaches us the same way every other gated
/// call does — through the `PreToolUse` hook. That is the only channel the app has into a running
/// session's decisions, and it already carries a reply the agent receives as the tool's result,
/// which is exactly what an answer is.
public struct OperatorQuestion: Sendable, Hashable, Identifiable {

    public struct Option: Sendable, Hashable, Identifiable {
        public let label: String
        /// The longer line under the label, when the agent supplied one.
        public let detail: String?
        public var id: String { label }

        public init(label: String, detail: String? = nil) {
            self.label = label
            self.detail = detail
        }
    }

    /// A short title for the question, when the agent supplied one.
    public let header: String?
    public let question: String
    public let options: [Option]
    /// Checkboxes rather than radio buttons: the agent will accept more than one answer.
    public let allowsMultiple: Bool
    /// Position in the request, which is what makes two identically worded questions distinct.
    public let index: Int

    public var id: Int { index }

    public init(
        header: String? = nil, question: String, options: [Option],
        allowsMultiple: Bool = false, index: Int = 0
    ) {
        self.header = header
        self.question = question
        self.options = options
        self.allowsMultiple = allowsMultiple
        self.index = index
    }
}

/// Reading and answering the runtime's question tool.
public enum AskUserQuestion {

    public static let toolName = "AskUserQuestion"

    public static func isQuestion(_ payload: HookPayload) -> Bool {
        payload.toolName == toolName
    }

    /// The questions carried by a request, or an empty array if it is not one.
    ///
    /// Lenient by design, like the rest of the hook decoding: a request whose shape has drifted
    /// still produces something answerable rather than an empty sheet. A question with no options
    /// is legitimate — it is asking for typed input.
    public static func questions(in payload: HookPayload) -> [OperatorQuestion] {
        guard isQuestion(payload) else { return [] }

        let raw = payload.toolInput["questions"]?.arrayValue
            // Single-question shorthand: the fields sit directly on the input.
            ?? (payload.toolInput["question"] != nil ? [payload.toolInput] : [])

        return raw.enumerated().compactMap { index, entry in
            let text = entry["question"]?.stringValue
                ?? entry["prompt"]?.stringValue
                ?? entry["header"]?.stringValue
            guard let text, !text.isEmpty else { return nil }

            let options = (entry["options"]?.arrayValue ?? []).compactMap { option -> OperatorQuestion.Option? in
                // Options are objects with a label, but a bare string is accepted too.
                if let label = option.stringValue, !label.isEmpty {
                    return OperatorQuestion.Option(label: label)
                }
                guard let label = option["label"]?.stringValue ?? option["name"]?.stringValue,
                      !label.isEmpty
                else { return nil }
                let detail = option["description"]?.stringValue ?? option["detail"]?.stringValue
                return OperatorQuestion.Option(
                    label: label, detail: (detail?.isEmpty ?? true) ? nil : detail)
            }

            let header = entry["header"]?.stringValue
            return OperatorQuestion(
                header: (header?.isEmpty ?? true) ? nil : header,
                question: text,
                options: options,
                allowsMultiple: entry["multiSelect"]?.boolValue
                    ?? entry["multiselect"]?.boolValue
                    ?? false,
                index: index)
        }
    }

    /// One operator's answer to one question.
    public struct Answer: Sendable, Hashable {
        public let question: OperatorQuestion
        /// Options ticked, in the order the question listed them.
        public let chosen: [String]
        /// Anything typed in the free-text field, which is always offered — an agent's options are
        /// its guesses, and the operator may have a different answer entirely.
        public let note: String

        public init(question: OperatorQuestion, chosen: [String], note: String) {
            self.question = question
            self.chosen = chosen
            self.note = note
        }
    }

    /// The answer as the agent will read it.
    ///
    /// Delivered through a denial, because the call must not also run: the runtime would then ask
    /// again through an interface this app does not present. The wording is therefore explicit
    /// that this is the answer and not a refusal — a bare "denied" would have the agent re-plan
    /// around a question it did in fact get an answer to.
    public static func result(for answers: [Answer]) -> String {
        guard !answers.isEmpty else {
            return "The operator closed the question without answering. Ask again only if you "
                + "cannot proceed without it."
        }

        var lines = ["The operator answered your question(s). Treat this as their reply:"]
        for answer in answers {
            let heading = answer.question.header ?? answer.question.question
            var reply = answer.chosen.joined(separator: ", ")
            if !answer.note.isEmpty {
                reply = reply.isEmpty ? answer.note : "\(reply) — \(answer.note)"
            }
            lines.append("- \(heading): \(reply.isEmpty ? "no answer given" : reply)")
        }
        lines.append(
            "The AskUserQuestion call itself was not run; the answers above are the result. "
                + "Continue with them.")
        return lines.joined(separator: "\n")
    }
}
