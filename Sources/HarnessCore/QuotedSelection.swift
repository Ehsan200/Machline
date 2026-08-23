import Foundation

/// A piece of the conversation the operator has pinned to their next message.
///
/// Quoting exists because pointing is faster than describing: an operator who wants the agent to
/// look at one code block, one stack trace, or one hunk of a patch should not have to retype it or
/// explain where it was. The quote carries its own provenance so the agent is told what it is
/// looking at, not merely handed a wall of text.
public struct QuotedSelection: Identifiable, Hashable, Sendable {

    /// Where the text came from, which is what the label is built out of.
    ///
    /// A file quote can name its lines; nothing in the transcript can, because a reply has no line
    /// numbers to cite — so those describe themselves by kind and size instead.
    public enum Source: Hashable, Sendable {
        case file(path: String, lines: ClosedRange<Int>?)
        case patch(path: String)
        case reply
        case code(language: String?)
        case terminal
        case toolOutput
        /// Text lifted out of a selection, where the app knows the string but not the surface.
        case selection
    }

    public let id: UUID
    public let text: String
    public let source: Source

    public init(id: UUID = UUID(), text: String, source: Source) {
        self.id = id
        self.text = text
        self.source = source
    }

    /// Newline-separated, counting a trailing newline as ending its line rather than starting one.
    public var lineCount: Int {
        guard !text.isEmpty else { return 0 }
        var trimmed = Substring(text)
        while trimmed.last == "\n" { trimmed = trimmed.dropLast() }
        return trimmed.isEmpty ? 1 : trimmed.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// What the chip says, and what the agent is told the quote is.
    public var label: String {
        switch source {
        case .file(let path, let lines):
            guard let lines else { return path }
            return lines.lowerBound == lines.upperBound
                ? "\(path):\(lines.lowerBound)"
                : "\(path):\(lines.lowerBound)-\(lines.upperBound)"
        case .patch(let path):
            return "patch · \(path)"
        case .reply:
            return "reply · \(sizeLabel)"
        case .code(let language):
            guard let language, !language.isEmpty else { return "code · \(sizeLabel)" }
            return "\(language) · \(sizeLabel)"
        case .terminal:
            return "terminal · \(sizeLabel)"
        case .toolOutput:
            return "tool output · \(sizeLabel)"
        case .selection:
            return "selection · \(sizeLabel)"
        }
    }

    private var sizeLabel: String {
        lineCount == 1 ? "1 line" : "\(lineCount) lines"
    }

    /// The first non-empty line, shortened — enough to tell two quotes apart on the chip row.
    public func snippet(limit: Int = 48) -> String {
        let first = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard first.count > limit else { return first }
        return String(first.prefix(limit)) + "…"
    }
}

/// Turns pinned quotes and what was typed into the one string the agent receives.
///
/// The quotes are tagged rather than prefixed with `>`. A blockquote marker is ambiguous twice
/// over: the agent cannot tell quoted evidence from prose the operator wrote in that style, and
/// quoted Markdown that already contains `>` comes out nested and wrong. A tag says exactly where
/// the borrowed text starts, where it ends, and what it was borrowed from.
public enum QuotePrompt {

    /// Past this, a quote is written to a file and mentioned instead of being pasted in whole.
    /// A long quote inlined is a context window spent on text the agent may only need to skim.
    public static let inlineLineLimit = 40
    public static let inlineByteLimit = 4096

    static let closingTag = "</quote>"

    /// Whether this text has to go to a file rather than into the message.
    ///
    /// Size is the usual reason. Text containing the closing tag is the other one: inlining it
    /// would end the quote early and leave the remainder reading as the operator's own words.
    public static func needsSpill(_ text: String) -> Bool {
        if text.utf8.count > inlineByteLimit { return true }
        if text.contains(closingTag) { return true }
        var lines = 0
        for character in text where character == "\n" {
            lines += 1
            if lines >= inlineLineLimit { return true }
        }
        return false
    }

    /// The message to send.
    ///
    /// `spilled` maps a quote to the path its text was written to. A quote that should have been
    /// spilled but has no path — the write failed — is inlined anyway: a truncated conversation is
    /// worse than a long one, and the operator asked for this text to be sent.
    public static func compose(
        quotes: [QuotedSelection], spilled: [UUID: String] = [:], typed: String
    ) -> String {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quotes.isEmpty else { return typed }

        var blocks: [String] = []
        for quote in quotes {
            let source = escaped(quote.label)
            if let path = spilled[quote.id] {
                blocks.append("""
                    <quote source="\(source)" file="\(escaped(path))">
                    Too long to include here — the full text is at @\(path)
                    \(closingTag)
                    """)
            } else {
                blocks.append("""
                    <quote source="\(source)">
                    \(body(of: quote.text))
                    \(closingTag)
                    """)
            }
        }

        blocks.append(typed)
        return blocks.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Quoted text keeps its own shape — indentation in code is meaningful — so only the blank
    /// edges that would push the closing tag off on its own island are taken off.
    private static func body(of text: String) -> String {
        var body = Substring(text)
        while body.last == "\n" || body.last == "\r" { body = body.dropLast() }
        while body.first == "\n" || body.first == "\r" { body = body.dropFirst() }
        return String(body)
    }

    /// Attribute values are the one place a stray quote or angle bracket would change the shape of
    /// the tag rather than just appearing inside it.
    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
