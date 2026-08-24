import Foundation

/// One line inside a hunk.
public struct GitDiffLine: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case context
        case addition
        case deletion
        /// `\ No newline at end of file`. Belongs to the preceding line and must be carried through
        /// verbatim, or a re-emitted patch changes the file's trailing newline.
        case noNewlineMarker
    }

    public let kind: Kind
    /// Content without the leading diff marker.
    public let text: String
    /// Line number in the pre-image, when applicable.
    public let oldLineNumber: Int?
    /// Line number in the post-image, when applicable.
    public let newLineNumber: Int?

    /// The line exactly as it appears in a patch, marker included.
    public var patchLine: String {
        switch kind {
        case .context: return " " + text
        case .addition: return "+" + text
        case .deletion: return "-" + text
        case .noNewlineMarker: return "\\ No newline at end of file"
        }
    }
}

/// A contiguous change region.
public struct GitHunk: Sendable, Hashable, Identifiable {
    public let id: Int
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    /// Text after the `@@` markers, which git uses for the enclosing function.
    public let sectionHeading: String
    public let lines: [GitDiffLine]

    public var header: String {
        let heading = sectionHeading.isEmpty ? "" : " \(sectionHeading)"
        return "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\(heading)"
    }

    public var additions: Int { lines.filter { $0.kind == .addition }.count }
    public var deletions: Int { lines.filter { $0.kind == .deletion }.count }

    /// The hunk rendered as patch text.
    public var patchText: String {
        ([header] + lines.map(\.patchLine)).joined(separator: "\n")
    }
}

/// A single file's diff.
public struct GitFileDiff: Sendable, Hashable, Identifiable {
    /// The file's name, for showing and for identifying it.
    ///
    /// A deletion's post-image is `/dev/null` — not a name, and the *same* non-name for every
    /// deleted file, so keying on `newPath` also collapses two deletions into one.
    public var displayPath: String { newPath == "/dev/null" ? oldPath : newPath }

    public var id: String { displayPath }
    public let oldPath: String
    public let newPath: String
    /// The `diff --git` / `index` / `---` / `+++` preamble, reproduced verbatim when building a
    /// patch so git can locate and validate the target.
    public let headerLines: [String]
    public let hunks: [GitHunk]
    public let isBinary: Bool
    public let isNew: Bool
    public let isDeleted: Bool

    public var additions: Int { hunks.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.deletions } }

    /// Builds an appliable patch containing only the selected hunks.
    ///
    /// Hunk offsets are left untouched: they are already expressed against the pre-image the diff
    /// was taken from, which is exactly what the patch will be applied to. Rewriting them is how
    /// hunk staging usually goes wrong.
    public func patch(includingHunks selected: Set<Int>) -> String? {
        let chosen = hunks.filter { selected.contains($0.id) }
        guard !chosen.isEmpty else { return nil }
        let body = chosen.map(\.patchText).joined(separator: "\n")
        return (headerLines + [body]).joined(separator: "\n") + "\n"
    }

    public var fullPatch: String? {
        patch(includingHunks: Set(hunks.map(\.id)))
    }
}

public enum GitDiffParser {

    /// Parses `git diff -U3 --no-color` output into per-file diffs.
    public static func parse(_ text: String) -> [GitFileDiff] {
        var diffs: [GitFileDiff] = []
        // `omittingEmptySubsequences: false` keeps blank context lines, which are meaningful.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var index = 0
        while index < lines.count {
            guard lines[index].hasPrefix("diff --git ") else {
                index += 1
                continue
            }
            let (diff, next) = parseFile(lines: lines, from: index)
            if let diff { diffs.append(diff) }
            index = next
        }
        return diffs
    }

    private static func parseFile(lines: [String], from start: Int) -> (GitFileDiff?, Int) {
        var index = start
        var headerLines: [String] = [lines[index]]
        var (oldPath, newPath) = parsePaths(fromGitHeader: lines[index])
        index += 1

        var isBinary = false, isNew = false, isDeleted = false

        // Preamble: everything up to the first hunk or the next file.
        while index < lines.count,
              !lines[index].hasPrefix("@@"),
              !lines[index].hasPrefix("diff --git ") {
            let line = lines[index]
            headerLines.append(line)
            if line.hasPrefix("new file mode") { isNew = true }
            if line.hasPrefix("deleted file mode") { isDeleted = true }
            if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") { isBinary = true }
            if line.hasPrefix("--- ") { oldPath = stripPathPrefix(String(line.dropFirst(4))) ?? oldPath }
            if line.hasPrefix("+++ ") { newPath = stripPathPrefix(String(line.dropFirst(4))) ?? newPath }
            index += 1
        }

        var hunks: [GitHunk] = []
        while index < lines.count, lines[index].hasPrefix("@@") {
            let (hunk, next) = parseHunk(lines: lines, from: index, id: hunks.count)
            if let hunk { hunks.append(hunk) }
            index = next
        }

        let diff = GitFileDiff(
            oldPath: oldPath, newPath: newPath, headerLines: headerLines,
            hunks: hunks, isBinary: isBinary, isNew: isNew, isDeleted: isDeleted)
        return (diff, index)
    }

    private static func parseHunk(lines: [String], from start: Int, id: Int) -> (GitHunk?, Int) {
        guard let ranges = parseHunkHeader(lines[start]) else { return (nil, start + 1) }

        var index = start + 1
        var body: [GitDiffLine] = []
        var oldLine = ranges.oldStart
        var newLine = ranges.newStart

        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("@@") || line.hasPrefix("diff --git ") { break }

            // A trailing empty element from the final split is not a diff line.
            if line.isEmpty, index == lines.count - 1 { break }

            switch line.first {
            case " ":
                body.append(GitDiffLine(
                    kind: .context, text: String(line.dropFirst()),
                    oldLineNumber: oldLine, newLineNumber: newLine))
                oldLine += 1; newLine += 1
            case "+":
                body.append(GitDiffLine(
                    kind: .addition, text: String(line.dropFirst()),
                    oldLineNumber: nil, newLineNumber: newLine))
                newLine += 1
            case "-":
                body.append(GitDiffLine(
                    kind: .deletion, text: String(line.dropFirst()),
                    oldLineNumber: oldLine, newLineNumber: nil))
                oldLine += 1
            case "\\":
                body.append(GitDiffLine(
                    kind: .noNewlineMarker, text: "", oldLineNumber: nil, newLineNumber: nil))
            case nil:
                // git emits a bare empty line for an empty context line.
                body.append(GitDiffLine(
                    kind: .context, text: "", oldLineNumber: oldLine, newLineNumber: newLine))
                oldLine += 1; newLine += 1
            default:
                return (makeHunk(id: id, ranges: ranges, body: body), index)
            }
            index += 1
        }

        return (makeHunk(id: id, ranges: ranges, body: body), index)
    }

    private static func makeHunk(
        id: Int, ranges: HunkRanges, body: [GitDiffLine]
    ) -> GitHunk {
        GitHunk(
            id: id,
            oldStart: ranges.oldStart, oldCount: ranges.oldCount,
            newStart: ranges.newStart, newCount: ranges.newCount,
            sectionHeading: ranges.heading, lines: body)
    }

    struct HunkRanges {
        let oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, heading: String
    }

    /// Parses `@@ -a,b +c,d @@ heading`. Counts are optional and default to 1.
    static func parseHunkHeader(_ line: String) -> HunkRanges? {
        guard line.hasPrefix("@@") else { return nil }
        let afterMarker = line.dropFirst(2)
        guard let closing = afterMarker.range(of: "@@") else { return nil }
        let ranges = afterMarker[afterMarker.startIndex..<closing.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        let heading = String(afterMarker[closing.upperBound...])
            .trimmingCharacters(in: .whitespaces)

        let parts = ranges.split(separator: " ")
        guard parts.count == 2,
              let old = parseRange(parts[0], expecting: "-"),
              let new = parseRange(parts[1], expecting: "+")
        else { return nil }

        return HunkRanges(
            oldStart: old.start, oldCount: old.count,
            newStart: new.start, newCount: new.count, heading: heading)
    }

    private static func parseRange(
        _ text: Substring, expecting sign: Character
    ) -> (start: Int, count: Int)? {
        guard text.first == sign else { return nil }
        let numbers = text.dropFirst().split(separator: ",")
        guard let start = Int(numbers[0]) else { return nil }
        let count = numbers.count > 1 ? (Int(numbers[1]) ?? 1) : 1
        return (start, count)
    }

    private static func parsePaths(fromGitHeader line: String) -> (String, String) {
        // `diff --git a/x b/x`. Paths containing spaces are handled by the `---`/`+++` lines that
        // follow, which overwrite these.
        let rest = line.dropFirst("diff --git ".count)
        let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return ("", "") }
        return (stripPathPrefix(parts[0]) ?? parts[0], stripPathPrefix(parts[1]) ?? parts[1])
    }

    private static func stripPathPrefix(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed == "/dev/null" { return trimmed }
        if trimmed.hasPrefix("a/") || trimmed.hasPrefix("b/") { return String(trimmed.dropFirst(2)) }
        return trimmed.isEmpty ? nil : trimmed
    }
}
