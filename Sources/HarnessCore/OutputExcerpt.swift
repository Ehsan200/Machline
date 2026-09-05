import Foundation

/// The part of a tool's output that is worth handing to a text view.
///
/// Tool output is unbounded — a build log, a `Read` of a large file, a `grep` across a monorepo.
/// The timeline shows it in a fixed-height pane, so the row is the same height whether the output
/// is thirty lines or thirty thousand; but a `Text` holding the whole thing still lays out every
/// line before anything draws, and unwrapped output has to lay out every line to find the widest.
/// That layout runs in the frame where the lazy stack builds the row, which is a stall in the
/// middle of a scroll.
///
/// So the view gets a bounded head and tail and nothing else. The full text stays where it was, for
/// copying and quoting — this only decides what is drawn.
///
/// Built once, off the main actor: live output is excerpted as the frame decodes (on the pipe's
/// queue) and replayed output as the transcript is read. Doing it in a view body instead would only
/// move the same cost into a scroll frame, which is the cost this type exists to avoid.
public struct OutputExcerpt: Sendable, Hashable {

    /// Lines kept from the start. Generous next to the ~13 the pane shows at once, so scrolling
    /// inside it still has somewhere to go, and cheap to lay out.
    public static let headLines = 400
    /// Lines kept from the end. A command's failure is usually its last line, so a head-only
    /// excerpt would cut off the one part worth reading.
    public static let tailLines = 200
    /// Characters kept per line. Output is drawn unwrapped, so a single minified line is laid out
    /// at its full width — one of those is as expensive as ten thousand ordinary lines.
    public static let lineLength = 1000

    /// What to draw.
    public let text: String
    /// The first line, for the collapsed row's summary. Precomputed because that row is built
    /// during a scroll: taking it with `split(separator:)` walks the whole output and allocates a
    /// substring per line, every time the body runs.
    public let firstLine: String
    public let lineCount: Int
    public let byteCount: Int
    /// True when anything was dropped — whole lines, or the ends of long ones.
    public let isTruncated: Bool

    public static let empty = OutputExcerpt("")

    public var isEmpty: Bool { text.isEmpty }

    /// What the pane says it is showing, when it is not showing all of it. Says the size in full so
    /// the number explains itself — "showing 600 of 84,102 lines" is why the rest is missing.
    public var summary: String? {
        guard isTruncated else { return nil }
        let kept = min(lineCount, Self.headLines + Self.tailLines)
        let size = byteCount.formatted(.byteCount(style: .file))
        guard kept < lineCount else { return "long lines shortened · \(size) in full" }
        return "showing \(kept.formatted()) of \(lineCount.formatted()) lines · \(size) in full"
    }

    /// The marker standing in for the lines that were dropped.
    private static let elision = "⋯"

    public init(_ source: String) {
        byteCount = source.utf8.count

        // One pass, bounded memory: the head is collected up to its cap, and everything past it
        // goes through a ring holding only the last `tailLines`. A transcript entry can be tens of
        // megabytes, and splitting one into an array of every line to keep six hundred of them is
        // the allocation this walk exists to avoid.
        var head: [Substring] = []
        head.reserveCapacity(Self.headLines)
        var tail: [Substring] = []
        tail.reserveCapacity(Self.tailLines)
        var tailStart = 0
        var total = 0
        var didClampALine = false

        // Scanned over the UTF-8 view rather than over `Character`s. Both find the same newlines —
        // `0x0A` cannot appear inside a multi-byte scalar — but the character view breaks graphemes
        // as it goes, which on a multi-megabyte log is most of the work. `String.UTF8View` shares
        // the string's index type, so the slices below are still ordinary substrings.
        let bytes = source.utf8
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let end = bytes[index...].firstIndex(of: UInt8(ascii: "\n")) ?? bytes.endIndex
            let line = source[index..<end]
            total += 1

            if head.count < Self.headLines {
                head.append(line)
            } else if tail.count < Self.tailLines {
                tail.append(line)
            } else {
                tail[tailStart] = line
                tailStart = (tailStart + 1) % Self.tailLines
            }

            index = end < bytes.endIndex ? bytes.index(after: end) : bytes.endIndex
        }

        lineCount = total

        // Clamped only now: a line that fell out of the ring never needed measuring. The byte count
        // is the fast gate — it is never smaller than the character count, so a line that passes it
        // is short by either measure and never has to be walked.
        func clamp(_ line: Substring) -> String {
            guard line.utf8.count > Self.lineLength, line.count > Self.lineLength else {
                return String(line)
            }
            didClampALine = true
            return String(line.prefix(Self.lineLength)) + Self.elision
        }

        let keptHead = head.map(clamp)
        // The ring is in order from `tailStart` once it has wrapped.
        let orderedTail = tail.count == Self.tailLines
            ? Array(tail[tailStart...] + tail[..<tailStart])
            : tail
        let keptTail = orderedTail.map(clamp)

        let droppedLines = total - keptHead.count - keptTail.count
        isTruncated = droppedLines > 0 || didClampALine

        var pieces = keptHead
        if droppedLines > 0 {
            pieces.append("\(Self.elision) \(droppedLines.formatted()) lines not shown \(Self.elision)")
        }
        pieces.append(contentsOf: keptTail)
        text = pieces.joined(separator: "\n")

        firstLine = String(source.prefix(while: { $0 != "\n" }).prefix(Self.lineLength))
    }
}
