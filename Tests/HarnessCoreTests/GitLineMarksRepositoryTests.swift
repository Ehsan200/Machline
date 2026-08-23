import Foundation
import Testing
@testable import HarnessCore

/// The same marks, but derived from what `git` actually emits rather than from a hand-written
/// patch. The margin sits beside real line numbers, so this is the assertion that matters.
@Suite("Gutter marks against a repository")
struct GitLineMarksRepositoryTests {

    private func marks(
        _ repository: GitTestRepository, _ path: String
    ) throws -> [Int: GitLineMark] {
        let status = try repository.manager.status()
        let diffs = try repository.manager.workingTreeDiff(status: status)
        guard let diff = diffs.first(where: { $0.newPath == path }) else { return [:] }
        return GitLineMarks.marks(in: diff)
    }

    private func edited(_ range: ClosedRange<Int>, _ changes: [Int: String]) -> String {
        var lines = GitTestRepository.numberedLines(range)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (index, text) in changes { lines[index] = text }
        return lines.joined(separator: "\n")
    }

    @Test("One edited line in the middle is marked, and only it")
    func singleEdit() throws {
        let repository = try GitTestRepository()
        try repository.write(GitTestRepository.numberedLines(1...20), to: "a.txt")
        try repository.commit("base")

        var lines = GitTestRepository.numberedLines(1...20)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines[9] = "line 10 EDITED"
        try repository.write(lines.joined(separator: "\n"), to: "a.txt")

        #expect(try marks(repository, "a.txt") == [10: .modified])
    }

    @Test("An inserted line marks itself and shifts nothing else")
    func insertion() throws {
        let repository = try GitTestRepository()
        try repository.write(GitTestRepository.numberedLines(1...20), to: "a.txt")
        try repository.commit("base")

        var lines = GitTestRepository.numberedLines(1...20)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.insert("inserted", at: 5)
        try repository.write(lines.joined(separator: "\n"), to: "a.txt")

        #expect(try marks(repository, "a.txt") == [6: .added])
    }

    @Test("Edits far apart land in their own hunks and keep their own numbers")
    func twoDistantEdits() throws {
        let repository = try GitTestRepository()
        try repository.write(GitTestRepository.numberedLines(1...60), to: "a.txt")
        try repository.commit("base")

        var lines = GitTestRepository.numberedLines(1...60)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines[4] = "line 5 EDITED"
        lines[49] = "line 50 EDITED"
        try repository.write(lines.joined(separator: "\n"), to: "a.txt")

        #expect(try marks(repository, "a.txt") == [5: .modified, 50: .modified])
    }

    /// An insertion earlier in the file renumbers everything after it. A mark taken against the old
    /// numbering would sit above where the change actually is, by exactly the number inserted.
    @Test("An edit below an insertion is marked at its new number")
    func editBelowAnInsertion() throws {
        let repository = try GitTestRepository()
        try repository.write(GitTestRepository.numberedLines(1...40), to: "a.txt")
        try repository.commit("base")

        var lines = GitTestRepository.numberedLines(1...40)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines[29] = "line 30 EDITED"
        lines.insert("inserted", at: 2)
        try repository.write(lines.joined(separator: "\n"), to: "a.txt")

        // "inserted" is line 3; the edited line was 30 and is now 31.
        #expect(try marks(repository, "a.txt") == [3: .added, 31: .modified])
    }

    /// The bug this was written for. Staging one edit and then making another used to mark lines
    /// that had not changed: the unstaged diff stops at the index, so it cannot see the staged edit,
    /// and the staged diff numbers its lines against the index rather than against the file on
    /// screen. Only a diff against HEAD answers for the file as it is.
    @Test("A staged edit and a later one are both marked, at their real numbers")
    func stagedAndUnstagedTogether() throws {
        let repository = try GitTestRepository()
        try repository.write(GitTestRepository.numberedLines(1...30), to: "a.txt")
        try repository.commit("base")

        try repository.write(edited(1...30, [4: "line 5 STAGED"]), to: "a.txt")
        try repository.manager.stage(paths: ["a.txt"])
        try repository.write(
            edited(1...30, [4: "line 5 STAGED", 19: "line 20 UNSTAGED"]), to: "a.txt")

        #expect(try marks(repository, "a.txt") == [5: .modified, 20: .modified])
    }

    @Test("Every line of an untracked file is an addition")
    func untrackedFile() throws {
        let repository = try GitTestRepository()
        try repository.write(GitTestRepository.numberedLines(1...20), to: "seed.txt")
        try repository.commit("base")
        try repository.write(GitTestRepository.numberedLines(1...3), to: "new.txt")

        #expect(try marks(repository, "new.txt") == [1: .added, 2: .added, 3: .added])
    }
}
