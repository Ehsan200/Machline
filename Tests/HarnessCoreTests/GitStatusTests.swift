import Foundation
import Testing
@testable import HarnessCore

@Suite("Git status")
struct GitStatusTests {

    @Test("A fresh repository reports an unborn branch and no files")
    func freshRepository() throws {
        let repository = try GitTestRepository()
        let status = try repository.manager.status()
        #expect(status.isClean)
        #expect(status.branch.head == "main")
        #expect(status.branch.isUnborn)
        #expect(!status.branch.hasUpstream)
    }

    @Test("Untracked, modified, and staged files are distinguished")
    func fileStates() throws {
        let repository = try GitTestRepository()
        try repository.write("one\n", to: "committed.txt")
        try repository.commit("initial")

        try repository.write("one\ntwo\n", to: "committed.txt")
        try repository.write("new\n", to: "untracked.txt")
        try repository.write("staged\n", to: "staged.txt")
        try repository.manager.stage(paths: ["staged.txt"])

        let status = try repository.manager.status()
        let byPath = Dictionary(uniqueKeysWithValues: status.files.map { ($0.path, $0) })

        let modified = try #require(byPath["committed.txt"])
        #expect(modified.worktreeChange == .modified)
        #expect(!modified.isStaged)
        #expect(modified.hasUnstagedChanges)

        let untracked = try #require(byPath["untracked.txt"])
        #expect(untracked.isUntracked)
        #expect(!untracked.supportsHunkStaging, "An untracked file has no index diff to slice")

        let staged = try #require(byPath["staged.txt"])
        #expect(staged.indexChange == .added)
        #expect(staged.isStaged)
    }

    /// Rename entries spend an extra NUL-separated record on their source path. A parser that
    /// treats every record as one entry mis-assigns every path after the first rename, so this
    /// checks the paths that *follow* a rename as much as the rename itself.
    @Test("A rename does not corrupt the entries that follow it")
    func renameParsing() throws {
        let repository = try GitTestRepository()
        try repository.write("content\n", to: "before.txt")
        try repository.write("other\n", to: "zzz-later.txt")
        try repository.commit("initial")

        try repository.manager.runner.check(["mv", "before.txt", "after.txt"])
        try repository.write("changed\n", to: "zzz-later.txt")
        try repository.manager.stage(paths: ["zzz-later.txt"])

        let status = try repository.manager.status()
        let byPath = Dictionary(uniqueKeysWithValues: status.files.map { ($0.path, $0) })

        let renamed = try #require(byPath["after.txt"])
        #expect(renamed.indexChange == .renamed)
        #expect(renamed.originalPath == "before.txt")

        let following = try #require(
            byPath["zzz-later.txt"], "The entry after a rename went missing — record misalignment")
        #expect(following.indexChange == .modified)
        #expect(following.path == "zzz-later.txt")
    }

    @Test("Deletions are reported")
    func deletion() throws {
        let repository = try GitTestRepository()
        try repository.write("content\n", to: "doomed.txt")
        try repository.commit("initial")
        try repository.delete("doomed.txt")

        let status = try repository.manager.status()
        let file = try #require(status.files.first { $0.path == "doomed.txt" })
        #expect(file.worktreeChange == .deleted)
    }

    @Test("Paths with spaces survive parsing")
    func pathsWithSpaces() throws {
        let repository = try GitTestRepository()
        try repository.write("content\n", to: "a file with spaces.txt")
        try repository.write("content\n", to: "nested dir/another file.txt")

        let paths = Set(try repository.manager.status().files.map(\.path))
        #expect(paths.contains("a file with spaces.txt"))
        #expect(paths.contains("nested dir/another file.txt"))
    }

    @Test("Ahead and behind counts are read from the branch header")
    func aheadBehind() throws {
        let upstream = try GitTestRepository()
        try upstream.write("one\n", to: "file.txt")
        try upstream.commit("initial")
        try upstream.manager.runner.check(["config", "receive.denyCurrentBranch", "ignore"])

        let clone = try GitTestRepository()
        try clone.manager.runner.check(["remote", "add", "origin", upstream.url.path])
        try clone.manager.runner.check(["fetch", "--quiet", "origin"])
        try clone.manager.runner.check(["checkout", "--quiet", "-B", "main", "origin/main"])

        #expect(try clone.manager.status().branch.ahead == 0)

        try clone.write("one\ntwo\n", to: "file.txt")
        try clone.commit("local change")

        let status = try clone.manager.status()
        #expect(status.branch.ahead == 1)
        #expect(status.branch.behind == 0)
        #expect(status.branch.upstream == "origin/main")
    }
}
