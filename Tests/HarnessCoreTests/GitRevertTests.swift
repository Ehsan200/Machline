import Foundation
import Testing

@testable import HarnessCore

/// Undoing a file is classification first and Git second, so both halves are tested: the plan
/// against a status, and the commands against a real repository.
@Suite("Undoing a file")
struct GitRevertTests {

    // MARK: Plan

    @Test("A modified file is restored, not removed")
    func modifiedIsRestored() throws {
        let repository = try GitTestRepository()
        try repository.write("base\n", to: "a.txt")
        try repository.commit("base")
        try repository.write("edited\n", to: "a.txt")

        let plan = GitRevertPlan(paths: ["a.txt"], status: try repository.manager.status())
        #expect(plan.restored == ["a.txt"])
        #expect(plan.removed.isEmpty)
        #expect(plan.forgotten.isEmpty)
        #expect(!plan.deletesFiles)
    }

    @Test("An untracked file is removed and never handed to git restore")
    func untrackedIsRemoved() throws {
        let repository = try GitTestRepository()
        try repository.write("base\n", to: "a.txt")
        try repository.commit("base")
        try repository.write("new\n", to: "b.txt")

        let plan = GitRevertPlan(paths: ["b.txt"], status: try repository.manager.status())
        #expect(plan.removed == ["b.txt"])
        #expect(plan.restored.isEmpty)
        // Untracked means the index has no entry to drop.
        #expect(plan.forgotten.isEmpty)
        #expect(plan.deletesFiles)
    }

    @Test("A file staged as new leaves the index and then the disk")
    func stagedNewIsForgottenAndRemoved() throws {
        let repository = try GitTestRepository()
        try repository.write("base\n", to: "a.txt")
        try repository.commit("base")
        try repository.write("new\n", to: "b.txt")
        try repository.manager.stage(paths: ["b.txt"])

        let plan = GitRevertPlan(paths: ["b.txt"], status: try repository.manager.status())
        #expect(plan.forgotten == ["b.txt"])
        #expect(plan.removed == ["b.txt"])
        #expect(plan.restored.isEmpty)
    }

    @Test("A rename names both of its paths, or the source stays deleted")
    func renameRestoresBothPaths() throws {
        let repository = try GitTestRepository()
        try repository.write("base\n", to: "a.txt")
        try repository.commit("base")
        try repository.manager.runner.check(["mv", "a.txt", "b.txt"])

        let plan = GitRevertPlan(paths: ["b.txt"], status: try repository.manager.status())
        #expect(plan.restored == ["a.txt", "b.txt"])
    }

    @Test("A path status does not mention is left alone")
    func unknownPathIsSkipped() throws {
        let repository = try GitTestRepository()
        try repository.write("base\n", to: "a.txt")
        try repository.commit("base")

        let plan = GitRevertPlan(paths: ["a.txt"], status: try repository.manager.status())
        #expect(plan.isEmpty)
    }

    // MARK: Commands

    @Test("Revert takes the staged half with it, which discard does not")
    func revertBeatsDiscard() throws {
        let repository = try GitTestRepository()
        try repository.write("base\n", to: "a.txt")
        try repository.commit("base")

        try repository.write("staged\n", to: "a.txt")
        try repository.manager.stage(paths: ["a.txt"])
        try repository.write("staged and then edited again\n", to: "a.txt")

        try repository.manager.revert(paths: ["a.txt"])

        #expect(try repository.read("a.txt") == "base\n")
        #expect(try repository.stagedContents(of: "a.txt") == "base\n")
        #expect(try repository.manager.status().isClean)
    }

    @Test("A deleted file comes back")
    func revertRestoresDeletedFile() throws {
        let repository = try GitTestRepository()
        try repository.write("base\n", to: "a.txt")
        try repository.commit("base")
        try repository.delete("a.txt")

        try repository.manager.revert(paths: ["a.txt"])

        #expect(try repository.read("a.txt") == "base\n")
    }

    @Test("Undoing a rename puts the file back under its old name")
    func revertUndoesRename() throws {
        let repository = try GitTestRepository()
        try repository.write("base\n", to: "a.txt")
        try repository.commit("base")
        try repository.manager.runner.check(["mv", "a.txt", "b.txt"])

        let plan = GitRevertPlan(paths: ["b.txt"], status: try repository.manager.status())
        try repository.manager.revert(paths: plan.restored)

        #expect(try repository.read("a.txt") == "base\n")
        #expect(try repository.manager.status().isClean)
    }

    @Test("Forgetting a staged file leaves it on disk, untracked")
    func forgetUnstagesWithoutDeleting() throws {
        let repository = try GitTestRepository()
        try repository.write("base\n", to: "a.txt")
        try repository.commit("base")
        try repository.write("new\n", to: "b.txt")
        try repository.manager.stage(paths: ["b.txt"])

        try repository.manager.forget(paths: ["b.txt"])

        #expect(try repository.read("b.txt") == "new\n")
        let status = try repository.manager.status()
        #expect(status.files.first { $0.path == "b.txt" }?.isUntracked == true)
    }

    /// Before the first commit there is no HEAD to restore from, so `forget` is the only way a file
    /// staged as new gets out of the index. `revert` would fail the whole call.
    @Test("A file staged before the first commit can still be forgotten")
    func forgetWorksWithoutCommits() throws {
        let repository = try GitTestRepository()
        try repository.write("new\n", to: "a.txt")
        try repository.manager.stage(paths: ["a.txt"])

        let plan = GitRevertPlan(paths: ["a.txt"], status: try repository.manager.status())
        #expect(plan.restored.isEmpty)

        try repository.manager.forget(paths: plan.forgotten)
        #expect(try repository.manager.status().staged.isEmpty)
    }

    @Test("Empty input runs no git at all")
    func emptyIsANoOp() throws {
        let repository = try GitTestRepository()
        try repository.write("base\n", to: "a.txt")
        try repository.commit("base")

        try repository.manager.revert(paths: [])
        try repository.manager.forget(paths: [])
        #expect(try repository.manager.status().isClean)
    }
}
