import Foundation

/// A piece of the conversation pinned to the next message.
public struct QuotedSelection: Identifiable, Hashable, Sendable {

    public enum Source: Hashable, Sendable {
        case file(path: String, lines: ClosedRange<Int>?)
        case patch(path: String)
        case reply
        case code(language: String?)
        case terminal
        case toolOutput
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

    public var lineCount: Int {
        guard !text.isEmpty else { return 0 }
        var trimmed = Substring(text)
        while trimmed.last == "\n" { trimmed = trimmed.dropLast() }
        return trimmed.isEmpty
            ? 1
            : trimmed.split(separator: "\n", omittingEmptySubsequences: false).count
    }

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
/// Tagged rather than `>`-prefixed: a blockquote cannot be told apart from prose written in that
/// style, and quoted Markdown containing `>` comes out nested.
public enum QuotePrompt {

    public static let inlineLineLimit = 40
    public static let inlineByteLimit = 4096

    static let closingTag = "</quote>"

    /// Text carrying the closing tag would end its own quote early, so it goes to a file too.
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

    /// `spilled` maps a quote to the path its text was written to. A quote that should have
    /// spilled but has no path is inlined anyway rather than dropped.
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

    /// Only the blank edges come off; indentation inside a quote is meaningful.
    private static func body(of text: String) -> String {
        var body = Substring(text)
        while body.last == "\n" || body.last == "\r" { body = body.dropLast() }
        while body.first == "\n" || body.first == "\r" { body = body.dropFirst() }
        return String(body)
    }

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
