import Testing

@testable import HarnessCore

struct OutputExcerptTests {

    @Test func shortOutputIsPassedThroughUntouched() {
        let excerpt = OutputExcerpt("one\ntwo\nthree")
        #expect(excerpt.text == "one\ntwo\nthree")
        #expect(excerpt.lineCount == 3)
        #expect(!excerpt.isTruncated)
        #expect(excerpt.summary == nil)
    }

    @Test func emptyOutputIsEmpty() {
        #expect(OutputExcerpt.empty.isEmpty)
        #expect(OutputExcerpt("").lineCount == 0)
        #expect(!OutputExcerpt("").isTruncated)
    }

    @Test func firstLineStopsAtTheFirstNewline() {
        #expect(OutputExcerpt("head\nrest\nmore").firstLine == "head")
        #expect(OutputExcerpt("only").firstLine == "only")
        #expect(OutputExcerpt("").firstLine == "")
    }

    /// The point of the type: the head, the tail, and a marker for what is missing — never the
    /// whole thing.
    @Test func longOutputKeepsBothEnds() {
        let lines = (1...10_000).map { "line \($0)" }
        let excerpt = OutputExcerpt(lines.joined(separator: "\n"))

        #expect(excerpt.lineCount == 10_000)
        #expect(excerpt.isTruncated)

        let kept = excerpt.text.components(separatedBy: "\n")
        // Head, tail, and one line of elision between them.
        #expect(kept.count == OutputExcerpt.headLines + OutputExcerpt.tailLines + 1)
        #expect(kept.first == "line 1")
        #expect(kept[OutputExcerpt.headLines - 1] == "line 400")
        #expect(kept[OutputExcerpt.headLines].contains("9,400 lines not shown"))
        #expect(kept[OutputExcerpt.headLines + 1] == "line 9801")
        #expect(kept.last == "line 10000")
    }

    /// Exactly the budget is not truncation, and the tail must not be reordered by the ring buffer
    /// it passes through.
    @Test func outputAtExactlyTheBudgetIsKeptWhole() {
        let total = OutputExcerpt.headLines + OutputExcerpt.tailLines
        let lines = (1...total).map { "line \($0)" }
        let excerpt = OutputExcerpt(lines.joined(separator: "\n"))

        #expect(!excerpt.isTruncated)
        #expect(excerpt.text == lines.joined(separator: "\n"))
    }

    /// One line past the budget is the case the ring buffer wraps on, so the tail's order is a real
    /// risk rather than a theoretical one.
    @Test func tailKeepsItsOrderOnceTheRingHasWrapped() {
        let total = OutputExcerpt.headLines + OutputExcerpt.tailLines + 1
        let lines = (1...total).map { "line \($0)" }
        let excerpt = OutputExcerpt(lines.joined(separator: "\n"))

        let kept = excerpt.text.components(separatedBy: "\n")
        #expect(kept[OutputExcerpt.headLines].contains("1 lines not shown"))
        #expect(kept[OutputExcerpt.headLines + 1] == "line 402")
        #expect(kept.last == "line \(total)")
    }

    /// A single minified line is as expensive to lay out unwrapped as a whole log, so length is
    /// capped as well as count.
    @Test func overlongLinesAreShortened() {
        let excerpt = OutputExcerpt(String(repeating: "x", count: 50_000))

        #expect(excerpt.lineCount == 1)
        #expect(excerpt.isTruncated)
        #expect(excerpt.text.count == OutputExcerpt.lineLength + 1)  // plus the elision mark
        #expect(excerpt.summary == "long lines shortened · 50 kB in full")
    }

    @Test func firstLineIsCappedToo() {
        let excerpt = OutputExcerpt(String(repeating: "y", count: 50_000) + "\ntail")
        #expect(excerpt.firstLine.count == OutputExcerpt.lineLength)
    }

    /// Lines are found by scanning bytes, so multi-byte scalars are the case that would break it:
    /// a split inside one would produce garbage rather than a short line.
    @Test func multiByteTextSurvivesTheByteScan() {
        let excerpt = OutputExcerpt("héllo → wörld\n日本語のテキスト\n🇬🇧 flag")
        #expect(excerpt.lineCount == 3)
        #expect(excerpt.firstLine == "héllo → wörld")
        #expect(excerpt.text == "héllo → wörld\n日本語のテキスト\n🇬🇧 flag")
        #expect(!excerpt.isTruncated)
    }

    /// The clamp counts characters, not bytes: a line of 900 three-byte scalars is well past the
    /// byte gate but is not actually a long line.
    @Test func multiByteLinesAreClampedByCharacterNotByte() {
        let line = String(repeating: "日", count: 900)
        let excerpt = OutputExcerpt(line)
        #expect(!excerpt.isTruncated)
        #expect(excerpt.text == line)
    }

    @Test func summaryCountsTheWholeOutput() {
        let lines = (1...5_000).map { "line \($0)" }
        let source = lines.joined(separator: "\n")
        let excerpt = OutputExcerpt(source)

        #expect(excerpt.byteCount == source.utf8.count)
        #expect(excerpt.summary?.hasPrefix("showing 600 of 5,000 lines") == true)
    }

    /// Trailing and blank lines are structure, not noise: output that ends in a newline has a last
    /// line, and dropping it would shift the tail by one.
    @Test func blankLinesAreCounted() {
        #expect(OutputExcerpt("a\n\nb").lineCount == 3)
        #expect(OutputExcerpt("a\n").lineCount == 1)
        #expect(OutputExcerpt("a\n").text == "a")
        #expect(OutputExcerpt("\n").lineCount == 1)
    }
}
