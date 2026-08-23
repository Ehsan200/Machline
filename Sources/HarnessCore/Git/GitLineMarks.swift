import Foundation

/// What happened to one line, as the margin should show it.
public enum GitLineMark: Sendable, Hashable {
    case added
    case modified
    /// Lines were removed here. Nothing remains to mark, so it belongs to the line that closed over
    /// the gap.
    case removed
}

/// Turns a file's diff into a mark per line, for the editor's margin.
///
/// The editor is next to a working agent, so "what is different from HEAD" is the question being
/// asked constantly — and it is the one thing an editor outside this window cannot answer.
///
/// Keyed by line number in the *new* file, because that is what is on screen. Deletions have no new
/// line of their own and are folded onto their neighbour rather than dropped: a removal that leaves
/// no trace in the margin reads as nothing having happened.
public enum GitLineMarks {

    public static func marks(in diff: GitFileDiff) -> [Int: GitLineMark] {
        var marks: [Int: GitLineMark] = [:]

        for hunk in diff.hunks {
            // The no-newline marker belongs to the line before it and is not a line of its own.
            let lines = hunk.lines.filter { $0.kind != .noNewlineMarker }
            var index = 0
            var lastNewLine = hunk.newStart

            while index < lines.count {
                if lines[index].kind == .context {
                    lastNewLine = lines[index].newLineNumber ?? lastNewLine
                    index += 1
                    continue
                }

                // One run of changed lines. Git emits removals before the replacements that follow
                // them, so a run carrying both is a rewrite rather than an insertion and a deletion.
                var removals = 0
                var insertions: [Int] = []
                while index < lines.count, lines[index].kind != .context {
                    switch lines[index].kind {
                    case .deletion:
                        removals += 1
                    case .addition:
                        if let line = lines[index].newLineNumber {
                            insertions.append(line)
                            lastNewLine = line
                        }
                    case .context, .noNewlineMarker:
                        break
                    }
                    index += 1
                }

                if !insertions.isEmpty {
                    let kind: GitLineMark = removals > 0 ? .modified : .added
                    for line in insertions { marks[line] = kind }
                } else if removals > 0 {
                    // Nothing replaced them, so the mark goes on whatever now sits at the seam —
                    // the following line, or the preceding one at the end of a file.
                    let following = index < lines.count ? lines[index].newLineNumber : nil
                    let seam = following ?? lastNewLine
                    if marks[seam] == nil { marks[seam] = .removed }
                }
            }
        }
        return marks
    }
}


