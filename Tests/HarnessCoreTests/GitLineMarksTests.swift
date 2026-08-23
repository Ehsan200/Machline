import Foundation
import Testing
@testable import HarnessCore

/// The margin answers "what is different from HEAD" while the agent is still working, which is the
/// one thing an editor outside this window cannot do.
@Suite("Gutter marks")
struct GitLineMarksTests {

    private func marks(_ patch: String) throws -> [Int: GitLineMark] {
        let diffs = GitDiffParser.parse(patch)
        let diff = try #require(diffs.first)
        return GitLineMarks.marks(in: diff)
    }

    private func header(_ path: String = "a.swift") -> String {
        """
        diff --git a/\(path) b/\(path)
        index 1111111..2222222 100644
        --- a/\(path)
        +++ b/\(path)
        """
    }

    @Test("Inserted lines are added")
    func insertions() throws {
        let found = try marks("""
            \(header())
            @@ -1,2 +1,4 @@
             one
            +two
            +three
             four
            """)
        #expect(found == [2: .added, 3: .added])
    }

    /// Git emits the removals first, so a run carrying both is a rewrite — not an insertion that
    /// happens to sit beside an unrelated deletion.
    @Test("A removal followed by a replacement is one modification")
    func replacement() throws {
        let found = try marks("""
            \(header())
            @@ -1,3 +1,3 @@
             one
            -two
            +TWO
             three
            """)
        #expect(found == [2: .modified])
    }

    @Test("A removal with nothing in its place marks the line that closed the gap")
    func pureRemoval() throws {
        let found = try marks("""
            \(header())
            @@ -1,4 +1,3 @@
             one
            -two
             three
             four
            """)
        // "three" is line 2 in the new file, and is what now sits where "two" was.
        #expect(found == [2: .removed])
    }

    /// A deletion running to the end of the file has no following line to carry it.
    @Test("A removal at the end of the file marks the last line")
    func removalAtEndOfFile() throws {
        let found = try marks("""
            \(header())
            @@ -1,3 +1,1 @@
             one
            -two
            -three
            """)
        #expect(found == [1: .removed])
    }

    @Test("Several hunks are all reported")
    func multipleHunks() throws {
        let found = try marks("""
            \(header())
            @@ -1,3 +1,3 @@
             one
            -two
            +TWO
             three
            @@ -10,3 +10,4 @@
             ten
            +eleven
             twelve
            """)
        #expect(found[2] == .modified)
        #expect(found[11] == .added)
    }

    @Test("An unchanged file has no marks")
    func noChanges() throws {
        let diffs = GitDiffParser.parse("")
        #expect(diffs.isEmpty)
    }

    /// The marker belongs to the line before it, not to a line of its own — counting it as one
    /// shifts every mark after it.
    @Test("The no-newline marker is not a line")
    func noNewlineMarker() throws {
        let found = try marks("""
            \(header())
            @@ -1,2 +1,2 @@
             one
            -two
            \\ No newline at end of file
            +TWO
            \\ No newline at end of file
            """)
        #expect(found == [2: .modified])
    }
}
