import Foundation
import Testing
@testable import HarnessCore

/// The scanner exists because regular expressions cannot agree about nesting: one for strings
/// cannot tell it is inside a comment, and one for comments cannot tell it is inside a string.
/// These pin the cases where that difference shows.
struct SyntaxHighlighterTests {

    private func kinds(_ source: String, _ rules: SyntaxRules = .swift) -> [(SyntaxSpan.Kind, String)] {
        SyntaxHighlighter.spans(in: source, rules: rules).map { ($0.kind, String(source[$0.range])) }
    }

    @Test("Keywords, strings, numbers, and comments are found")
    func findsEachKind() {
        let found = kinds("""
            let count = 42 // how many
            """)
        #expect(found.contains { $0.0 == .keyword && $0.1 == "let" })
        #expect(found.contains { $0.0 == .number && $0.1 == "42" })
        #expect(found.contains { $0.0 == .comment && $0.1 == "// how many" })
    }

    /// The case a regex pair gets wrong: the comment marker is inside a string.
    @Test("A comment marker inside a string is part of the string")
    func commentMarkerInsideString() {
        let found = kinds(#"let url = "https://example.com" // real comment"#)
        #expect(found.contains { $0.0 == .string && $0.1 == #""https://example.com""# })
        #expect(found.filter { $0.0 == .comment }.count == 1)
    }

    /// And the mirror image: a quote inside a comment starts nothing.
    @Test("A quote inside a comment does not open a string")
    func quoteInsideComment() {
        let found = kinds("""
            // it's fine
            let x = 1
            """)
        #expect(!found.contains { $0.0 == .string })
        #expect(found.contains { $0.0 == .keyword && $0.1 == "let" })
    }

    @Test("Escaped quotes do not end a string early")
    func escapedQuotes() {
        let source = #"let s = "a \" b" + tail"#
        let strings = kinds(source).filter { $0.0 == .string }
        #expect(strings.count == 1)
        #expect(strings[0].1 == #""a \" b""#)
    }

    /// An unterminated literal must not swallow the rest of the file.
    @Test("An unterminated string stops at the end of its line")
    func unterminatedString() {
        let source = "let a = \"oops\nlet b = 2"
        let found = kinds(source)
        #expect(found.contains { $0.0 == .keyword && $0.1 == "let" })
        #expect(found.filter { $0.0 == .keyword }.count == 2)
    }

    @Test("Block comments run to their closing delimiter")
    func blockComments() {
        let found = kinds("/* let a = 1 */ let b = 2")
        #expect(found.contains { $0.0 == .comment && $0.1 == "/* let a = 1 */" })
        #expect(found.filter { $0.0 == .keyword }.count == 1)
    }

    /// A digit inside an identifier is not a number literal.
    @Test("Digits inside identifiers are not numbers")
    func digitsInIdentifiers() {
        #expect(!kinds("let base64 = 1").contains { $0.0 == .number && $0.1 == "64" })
    }

    @Test("A keyword is not matched inside a longer identifier")
    func keywordPrefixes() {
        let found = kinds("let letter = 1")
        #expect(found.filter { $0.0 == .keyword }.count == 1)
    }

    @Test("Capitalised identifiers are types where the language says so")
    func capitalisedTypes() {
        #expect(kinds("let x: Foo").contains { $0.0 == .type && $0.1 == "Foo" })
        // Shell has no such convention, so an uppercase word there is just a word.
        #expect(!kinds("echo Foo", .shell).contains { $0.0 == .type })
    }

    @Test("A file type resolves to its language, and an unknown one to nothing")
    func languageLookup() {
        #expect(SyntaxHighlighter.rules(forFile: "App.swift") != nil)
        #expect(SyntaxHighlighter.rules(forFile: "index.tsx") != nil)
        #expect(SyntaxHighlighter.rules(forFile: "Dockerfile") != nil)
        #expect(SyntaxHighlighter.rules(forFile: "notes.unknownext") == nil)
    }

    /// Spans must be usable as ranges into the original string, in order and non-overlapping.
    @Test("Spans are ordered and do not overlap")
    func spansAreWellFormed() {
        let source = """
            // header
            let name = "value" // trailing
            let count = 10
            """
        let spans = SyntaxHighlighter.spans(in: source, rules: .swift)
        for (previous, next) in zip(spans, spans.dropFirst()) {
            #expect(previous.range.upperBound <= next.range.lowerBound)
        }
    }

    @Test("A hash comment language treats # as a comment, not a keyword")
    func hashComments() {
        let found = kinds("# a note\nx = 1", .python)
        #expect(found.contains { $0.0 == .comment && $0.1 == "# a note" })
    }
}

/// A single-file component holds three languages. Highlighting it with one ruleset is wrong
/// whichever is chosen: the script block's `//` comments would read as text, or the template's
/// `<!-- -->` would go uncoloured.
struct CompositeHighlightingTests {

    private let vue = """
        <template>
          <!-- a note -->
          <div :class="wrapper">{{ label }}</div>
        </template>

        <script setup lang="ts">
        // pick a name
        const label = "hello"
        </script>

        <style scoped>
        /* spacing */
        .wrapper { color: red; }
        </style>
        """

    private func spans(_ source: String, _ file: String) -> [(SyntaxSpan.Kind, String)] {
        SyntaxHighlighter.spans(in: source, fileName: file)
            .map { ($0.kind, String(source[$0.range])) }
    }

    @Test("Vue is highlightable")
    func vueIsSupported() {
        #expect(SyntaxHighlighter.canHighlight(fileName: "App.vue"))
        #expect(SyntaxHighlighter.canHighlight(fileName: "page.html"))
        #expect(!SyntaxHighlighter.canHighlight(fileName: "notes.unknownext"))
    }

    @Test("The script block is scanned as JavaScript")
    func scriptBlockUsesJavaScript() {
        let found = spans(vue, "App.vue")
        #expect(found.contains { $0.0 == .keyword && $0.1 == "const" })
        #expect(found.contains { $0.0 == .comment && $0.1 == "// pick a name" })
        #expect(found.contains { $0.0 == .string && $0.1 == #""hello""# })
    }

    /// The `//` in a template URL is not a comment, and the script block's `//` is.
    @Test("Template markup uses markup comments, not script ones")
    func templateUsesMarkupRules() {
        let found = spans(vue, "App.vue")
        #expect(found.contains { $0.0 == .comment && $0.1 == "<!-- a note -->" })
        #expect(found.contains { $0.0 == .comment && $0.1 == "/* spacing */" })
    }

    /// A component tag is not a keyword, and colouring it as one is worse than leaving it plain.
    @Test("Tag names are not treated as keywords")
    func tagsAreNotKeywords() {
        let found = spans("<template><MyThing /></template>", "App.vue")
        #expect(!found.contains { $0.0 == .keyword })
    }

    @Test("A component with no script or style block still highlights its markup")
    func markupOnly() {
        let source = "<template><!-- only markup --></template>"
        #expect(spans(source, "App.vue").contains { $0.0 == .comment })
    }

    /// Ranges come from substrings of the original, so they must index the whole file correctly.
    @Test("Spans index the whole file, not the region they came from")
    func spansIndexTheWholeFile() {
        let source = vue
        for span in SyntaxHighlighter.spans(in: source, fileName: "App.vue") {
            #expect(span.range.lowerBound >= source.startIndex)
            #expect(span.range.upperBound <= source.endIndex)
        }
        // The style comment is near the end; finding it proves later regions are not offset wrong.
        let found = spans(source, "App.vue")
        #expect(found.contains { $0.1 == "/* spacing */" })
    }

    @Test("An unclosed script block does not swallow the file")
    func unclosedScriptBlock() {
        let source = "<template><!-- x --></template>\n<script>\nconst a = 1"
        // No closing tag means no region is claimed; the markup before it must still be scanned.
        #expect(spans(source, "App.vue").contains { $0.0 == .comment && $0.1 == "<!-- x -->" })
    }
}
