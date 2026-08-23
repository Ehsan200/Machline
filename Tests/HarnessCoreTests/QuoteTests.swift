import Foundation
import Testing
@testable import HarnessCore

@Suite("Quoting a piece of the conversation")
struct QuoteTests {

    @Test("A file quote is labelled by its lines, a transcript quote by its size")
    func labels() {
        let file = QuotedSelection(text: "let x = 1", source: .file(path: "Foo.swift", lines: 120...148))
        #expect(file.label == "Foo.swift:120-148")

        let single = QuotedSelection(text: "let x = 1", source: .file(path: "Foo.swift", lines: 12...12))
        #expect(single.label == "Foo.swift:12")

        let whole = QuotedSelection(text: "let x = 1", source: .file(path: "Foo.swift", lines: nil))
        #expect(whole.label == "Foo.swift")

        let reply = QuotedSelection(text: "one\ntwo\nthree", source: .reply)
        #expect(reply.label == "reply · 3 lines")

        let oneLine = QuotedSelection(text: "just this", source: .terminal)
        #expect(oneLine.label == "terminal · 1 line")

        let code = QuotedSelection(text: "print(1)", source: .code(language: "swift"))
        #expect(code.label == "swift · 1 line")
    }

    /// A trailing newline ends its line rather than starting an empty one, or every quote taken off
    /// a terminal would claim one more line than it shows.
    @Test("Line counting ignores trailing newlines")
    func lineCounting() {
        #expect(QuotedSelection(text: "a\nb\n", source: .reply).lineCount == 2)
        #expect(QuotedSelection(text: "a", source: .reply).lineCount == 1)
        #expect(QuotedSelection(text: "", source: .reply).lineCount == 0)
    }

    @Test("The snippet is the first line that has something on it")
    func snippets() {
        let quote = QuotedSelection(text: "\n   \n  the first real line  \nmore", source: .reply)
        #expect(quote.snippet() == "the first real line")

        let long = QuotedSelection(text: String(repeating: "x", count: 100), source: .reply)
        #expect(long.snippet(limit: 10) == "xxxxxxxxxx…")
    }

    @Test("Quotes are tagged with their source and sit above what was typed")
    func composesTaggedBlocks() {
        let quote = QuotedSelection(
            text: "let x = 1", source: .file(path: "Foo.swift", lines: 1...1))
        let composed = QuotePrompt.compose(quotes: [quote], typed: "why is this here?")

        #expect(composed == """
            <quote source="Foo.swift:1">
            let x = 1
            </quote>

            why is this here?
            """)
    }

    @Test("Nothing pinned leaves the message exactly as typed")
    func passesThroughWithoutQuotes() {
        #expect(QuotePrompt.compose(quotes: [], typed: "  hello  ") == "hello")
    }

    /// Pinning a stack trace and pressing Send with nothing typed is a message in itself.
    @Test("A quote with nothing typed is still a message")
    func quoteOnlyMessage() {
        let quote = QuotedSelection(text: "boom", source: .toolOutput)
        let composed = QuotePrompt.compose(quotes: [quote], typed: "")

        #expect(composed == """
            <quote source="tool output · 1 line">
            boom
            </quote>
            """)
    }

    @Test("Quoted text keeps its own indentation")
    func keepsIndentation() {
        let quote = QuotedSelection(text: "\nfunc f() {\n    return 1\n}\n", source: .code(language: nil))
        let composed = QuotePrompt.compose(quotes: [quote], typed: "x")
        #expect(composed.contains("func f() {\n    return 1\n}"))
    }

    @Test("An oversized quote is mentioned by path rather than pasted in")
    func spillsWhenTooLong() {
        let long = String(repeating: "line\n", count: QuotePrompt.inlineLineLimit + 1)
        let quote = QuotedSelection(text: long, source: .reply)
        #expect(QuotePrompt.needsSpill(long))

        let composed = QuotePrompt.compose(
            quotes: [quote], spilled: [quote.id: "/tmp/quoted-selection.txt"], typed: "look")
        #expect(composed.contains("file=\"/tmp/quoted-selection.txt\""))
        #expect(composed.contains("@/tmp/quoted-selection.txt"))
        #expect(!composed.contains("line\nline\nline"))
    }

    /// Inlining text that contains the closing tag would end the quote early and leave the rest
    /// reading as the operator's own words.
    @Test("Text carrying the closing tag has to go to a file")
    func spillsOnClosingTag() {
        #expect(QuotePrompt.needsSpill("a </quote> b"))
        #expect(!QuotePrompt.needsSpill("a quote about quoting"))
        #expect(QuotePrompt.needsSpill(String(repeating: "x", count: QuotePrompt.inlineByteLimit + 1)))
    }

    /// A failed write is not a reason to drop what the operator asked to send.
    @Test("A quote that should have spilled but has no file is inlined anyway")
    func inlinesWhenSpillFailed() {
        let long = String(repeating: "line\n", count: QuotePrompt.inlineLineLimit + 1)
        let quote = QuotedSelection(text: long, source: .reply)
        let composed = QuotePrompt.compose(quotes: [quote], spilled: [:], typed: "look")
        #expect(composed.contains("line\nline\nline"))
    }

    @Test("A label that could reshape the tag is escaped")
    func escapesAttributes() {
        let quote = QuotedSelection(text: "x", source: .file(path: "a\"b<c>&d.swift", lines: nil))
        let composed = QuotePrompt.compose(quotes: [quote], typed: "")
        #expect(composed.contains("source=\"a&quot;b&lt;c&gt;&amp;d.swift\""))
    }

    @Test("Several quotes keep the order they were pinned in")
    func keepsOrder() {
        let first = QuotedSelection(text: "first", source: .reply)
        let second = QuotedSelection(text: "second", source: .terminal)
        let composed = QuotePrompt.compose(quotes: [first, second], typed: "compare these")

        let firstIndex = try? #require(composed.range(of: "first")?.lowerBound)
        let secondIndex = try? #require(composed.range(of: "second")?.lowerBound)
        #expect(firstIndex != nil && secondIndex != nil && firstIndex! < secondIndex!)
        #expect(composed.hasSuffix("compare these"))
    }

    @Test("Text written to the store comes back readable at the path it reports")
    func storesText() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quote-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AttachmentStore(directory: directory)
        let url = try store.store(text: "hello\nthere", named: "quoted selection.txt")

        #expect(url.lastPathComponent == "quoted-selection.txt")
        #expect(try String(contentsOf: url, encoding: .utf8) == "hello\nthere")
    }
}
