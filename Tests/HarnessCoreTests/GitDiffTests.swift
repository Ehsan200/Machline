import Foundation
import Testing
@testable import HarnessCore

@Suite("Git diff parsing and hunk staging")
struct GitDiffTests {

    /// 30 numbered lines, with edits near line 5 and line 25 — far enough apart that `-U3` yields
    /// exactly two hunks.
    static func makeTwoHunkRepository() throws -> GitTestRepository {
        let repository = try GitTestRepository()
        try repository.write(GitTestRepository.numberedLines(1...30), to: "file.txt")
        try repository.commit("initial")

        var lines = (1...30).map { "line \($0)" }
        lines[4] = "line 5 CHANGED"
        lines[24] = "line 25 CHANGED"
        try repository.write(lines.joined(separator: "\n") + "\n", to: "file.txt")
        return repository
    }

    // MARK: - Parsing

    @Test("A two-hunk diff parses with correct ranges and line numbers")
    func parsesHunks() throws {
        let repository = try Self.makeTwoHunkRepository()
        let diff = try #require(try repository.manager.unstagedDiff().first)

        #expect(diff.newPath == "file.txt")
        #expect(diff.hunks.count == 2)
        #expect(diff.additions == 2)
        #expect(diff.deletions == 2)
        #expect(!diff.isBinary && !diff.isNew && !diff.isDeleted)

        let first = diff.hunks[0]
        #expect(first.oldStart == 2, "Three lines of context precede line 5")
        #expect(first.additions == 1)
        #expect(first.deletions == 1)
        #expect(first.lines.contains { $0.kind == .addition && $0.text == "line 5 CHANGED" })
        #expect(first.lines.contains { $0.kind == .deletion && $0.text == "line 5" })

        let deletion = try #require(first.lines.first { $0.kind == .deletion })
        #expect(deletion.oldLineNumber == 5)
        #expect(deletion.newLineNumber == nil)
        let addition = try #require(first.lines.first { $0.kind == .addition })
        #expect(addition.newLineNumber == 5)
        #expect(addition.oldLineNumber == nil)

        #expect(diff.hunks[1].oldStart == 22)
    }

    @Test("Hunk headers round-trip through parsing")
    func hunkHeaderRoundTrip() throws {
        let ranges = try #require(GitDiffParser.parseHunkHeader("@@ -12,7 +12,9 @@ func example() {"))
        #expect(ranges.oldStart == 12)
        #expect(ranges.oldCount == 7)
        #expect(ranges.newStart == 12)
        #expect(ranges.newCount == 9)
        #expect(ranges.heading == "func example() {")

        // Counts are optional and default to 1.
        let single = try #require(GitDiffParser.parseHunkHeader("@@ -1 +1 @@"))
        #expect(single.oldCount == 1 && single.newCount == 1)
    }

    @Test("Empty context lines are preserved rather than dropped")
    func preservesBlankContextLines() throws {
        let repository = try GitTestRepository()
        try repository.write("alpha\n\n\nbeta\n", to: "file.txt")
        try repository.commit("initial")
        try repository.write("alpha\n\n\nbeta CHANGED\n", to: "file.txt")

        let diff = try #require(try repository.manager.unstagedDiff().first)
        let hunk = try #require(diff.hunks.first)
        let blanks = hunk.lines.filter { $0.kind == .context && $0.text.isEmpty }
        #expect(blanks.count == 2, "Blank context lines carry meaning and must survive")
    }

    /// A file without a trailing newline emits `\ No newline at end of file`, which must be carried
    /// through verbatim or re-applying the patch silently adds a newline.
    @Test("The no-newline marker is preserved")
    func preservesNoNewlineMarker() throws {
        let repository = try GitTestRepository()
        try repository.write("alpha\nbeta", to: "file.txt")
        try repository.commit("initial")
        try repository.write("alpha\ngamma", to: "file.txt")

        let diff = try #require(try repository.manager.unstagedDiff().first)
        let hunk = try #require(diff.hunks.first)
        #expect(hunk.lines.contains { $0.kind == .noNewlineMarker })
        #expect(hunk.patchText.contains("\\ No newline at end of file"))
    }

    // MARK: - Hunk staging

    /// The acceptance criterion from README, Runtime: staging one hunk must produce exactly the index that
    /// selecting that hunk in `git add -p` would.
    @Test("Staging a single hunk stages only that hunk")
    func stageOneHunk() throws {
        let repository = try Self.makeTwoHunkRepository()
        let diff = try #require(try repository.manager.unstagedDiff().first)
        try repository.manager.stage(diff: diff, hunkIDs: [1])

        var expected = (1...30).map { "line \($0)" }
        expected[24] = "line 25 CHANGED"
        #expect(try repository.stagedContents(of: "file.txt")
            == expected.joined(separator: "\n") + "\n")

        // The working tree still holds both edits.
        #expect(try repository.read("file.txt").contains("line 5 CHANGED"))

        // And the first hunk remains unstaged.
        let remaining = try #require(try repository.manager.unstagedDiff().first)
        #expect(remaining.hunks.count == 1)
        #expect(remaining.hunks[0].lines.contains { $0.text == "line 5 CHANGED" })
    }

    @Test("Staging every hunk matches staging the whole file")
    func stageAllHunksMatchesWholeFile() throws {
        let byHunk = try Self.makeTwoHunkRepository()
        let diff = try #require(try byHunk.manager.unstagedDiff().first)
        try byHunk.manager.stage(diff: diff, hunkIDs: Set(diff.hunks.map(\.id)))

        let whole = try Self.makeTwoHunkRepository()
        try whole.manager.stage(paths: ["file.txt"])

        #expect(try byHunk.stagedContents(of: "file.txt")
            == whole.stagedContents(of: "file.txt"))
        #expect(try byHunk.manager.unstagedDiff().isEmpty)
    }

    @Test("Unstaging a hunk removes only that hunk from the index")
    func unstageOneHunk() throws {
        let repository = try Self.makeTwoHunkRepository()
        try repository.manager.stage(paths: ["file.txt"])

        let staged = try #require(try repository.manager.stagedDiff().first)
        #expect(staged.hunks.count == 2)
        try repository.manager.unstage(diff: staged, hunkIDs: [0])

        var expected = (1...30).map { "line \($0)" }
        expected[24] = "line 25 CHANGED"
        #expect(try repository.stagedContents(of: "file.txt")
            == expected.joined(separator: "\n") + "\n")
        #expect(try repository.read("file.txt").contains("line 5 CHANGED"),
                "Unstaging must not touch the working tree")
    }

    @Test("Discarding a hunk reverts only that hunk in the working tree")
    func discardOneHunk() throws {
        let repository = try Self.makeTwoHunkRepository()
        let diff = try #require(try repository.manager.unstagedDiff().first)
        try repository.manager.discard(diff: diff, hunkIDs: [0])

        let contents = try repository.read("file.txt")
        #expect(!contents.contains("line 5 CHANGED"), "The discarded hunk should be gone")
        #expect(contents.contains("line 25 CHANGED"), "The other hunk should survive")
    }

    @Test("Selecting no hunks is refused rather than silently doing nothing")
    func emptySelectionIsRefused() throws {
        let repository = try Self.makeTwoHunkRepository()
        let diff = try #require(try repository.manager.unstagedDiff().first)
        #expect(throws: GitManager.Failure.self) {
            try repository.manager.stage(diff: diff, hunkIDs: [])
        }
    }

    @Test("Staging hunks works across several files independently")
    func multipleFiles() throws {
        let repository = try GitTestRepository()
        try repository.write(GitTestRepository.numberedLines(1...10), to: "a.txt")
        try repository.write(GitTestRepository.numberedLines(1...10), to: "b.txt")
        try repository.commit("initial")

        try repository.write(GitTestRepository.numberedLines(1...10) + "extra a\n", to: "a.txt")
        try repository.write(GitTestRepository.numberedLines(1...10) + "extra b\n", to: "b.txt")

        let diffs = try repository.manager.unstagedDiff()
        #expect(diffs.count == 2)
        let aDiff = try #require(diffs.first { $0.newPath == "a.txt" })
        try repository.manager.stage(diff: aDiff, hunkIDs: [0])

        #expect(try repository.stagedContents(of: "a.txt").contains("extra a"))
        #expect(try !repository.stagedContents(of: "b.txt").contains("extra b"))
    }

    /// A file git is not tracking produces no `git diff` output at all, so the workbench would show
    /// a new file as having nothing to review without this path.
    @Test("Untracked files still produce a reviewable diff")
    func untrackedDiff() throws {
        let repository = try GitTestRepository()
        try repository.write("one\n", to: "tracked.txt")
        try repository.commit("initial")
        try repository.write("brand new\ncontent\n", to: "fresh.txt")

        #expect(try repository.manager.unstagedDiff().isEmpty, "git diff ignores untracked files")

        let diff = try #require(try repository.manager.untrackedDiff(path: "fresh.txt"))
        #expect(diff.hunks.count == 1)
        #expect(diff.additions == 2)
        #expect(diff.hunks[0].lines.contains { $0.text == "brand new" })
    }

    /// `--intent-to-add` is how `git add -p` makes a new file hunk-stageable.
    @Test("Intent-to-add makes a new file hunk-stageable")
    func intentToAddEnablesHunkStaging() throws {
        let repository = try GitTestRepository()
        try repository.write("one\n", to: "tracked.txt")
        try repository.commit("initial")
        try repository.write(GitTestRepository.numberedLines(1...5), to: "fresh.txt")

        try repository.manager.markIntentToAdd(paths: ["fresh.txt"])
        let diff = try #require(try repository.manager.unstagedDiff().first { $0.newPath == "fresh.txt" })
        #expect(!diff.hunks.isEmpty)

        try repository.manager.stage(diff: diff, hunkIDs: Set(diff.hunks.map(\.id)))
        #expect(try repository.stagedContents(of: "fresh.txt")
            == GitTestRepository.numberedLines(1...5))
    }

    @Test("Binary files are flagged and carry no hunks")
    func binaryFiles() throws {
        let repository = try GitTestRepository()
        try repository.write("placeholder\n", to: "keep.txt")
        try repository.commit("initial")

        let bytes = Data((0..<256).map { UInt8($0 % 256) })
        try bytes.write(to: repository.url.appendingPathComponent("blob.bin"))
        try repository.manager.markIntentToAdd(paths: ["blob.bin"])

        let diff = try #require(try repository.manager.unstagedDiff().first { $0.newPath == "blob.bin" })
        #expect(diff.isBinary)
        #expect(diff.hunks.isEmpty)
    }
}
