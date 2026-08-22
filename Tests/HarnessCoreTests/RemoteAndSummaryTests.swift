import Foundation
import Testing
@testable import HarnessCore

/// Pull is the one remote operation whose behaviour differs by repository configuration, and the
/// three outcomes differ in whether they rewrite commits or leave conflict markers behind. So what
/// the repository says, and what it means when it says nothing, are both pinned.
struct PullStrategyTests {

    private func repository(config: [String: String] = [:]) throws -> GitManager {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pull-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = GitManager(workingDirectory: root)
        try manager.runner.check(["init", "--quiet"])
        for (key, value) in config {
            try manager.runner.check(["config", key, value])
        }
        return manager
    }

    /// No preference means ask. Guessing here can rewrite the operator's commits.
    @Test("A repository with no pull preference reports none")
    func noPreferenceReportsNil() throws {
        #expect(try repository().configuredPullStrategy() == nil)
    }

    @Test("pull.rebase true means rebase")
    func rebaseConfigured() throws {
        let manager = try repository(config: ["pull.rebase": "true"])
        #expect(try manager.configuredPullStrategy() == .rebase)
    }

    @Test("pull.rebase false means merge")
    func mergeConfigured() throws {
        let manager = try repository(config: ["pull.rebase": "false"])
        #expect(try manager.configuredPullStrategy() == .merge)
    }

    /// `merges` and `interactive` are still rebases, not a third thing.
    @Test("Other pull.rebase values are still a rebase")
    func rebaseVariantsAreRebases() throws {
        for value in ["merges", "interactive"] {
            let manager = try repository(config: ["pull.rebase": value])
            #expect(try manager.configuredPullStrategy() == .rebase, "\(value)")
        }
    }

    @Test("pull.ff only means fast-forward only")
    func fastForwardOnlyConfigured() throws {
        let manager = try repository(config: ["pull.ff": "only"])
        #expect(try manager.configuredPullStrategy() == .fastForwardOnly)
    }

    @Test("Each strategy passes the flag that produces it")
    func strategyArguments() {
        #expect(GitManager.PullStrategy.fastForwardOnly.arguments == ["--ff-only"])
        #expect(GitManager.PullStrategy.rebase.arguments == ["--rebase"])
        #expect(GitManager.PullStrategy.merge.arguments == ["--no-rebase"])
    }
}

/// Nothing is hidden from the repository list — repositories needing work sort first.
struct RepositorySummaryTests {

    private func makeRepository(dirty: Bool) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("summary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = GitManager(workingDirectory: root)
        try manager.runner.check(["init", "--quiet"])
        try manager.runner.check(["config", "user.email", "test@example.com"])
        try manager.runner.check(["config", "user.name", "Test"])
        try "hello".write(
            to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try manager.runner.check(["add", "."])
        try manager.runner.check(["commit", "--quiet", "-m", "initial"])
        if dirty {
            try "changed".write(
                to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test("A clean repository reports no changes")
    func cleanRepository() throws {
        let summaries = RepositorySummary.summarise(repositories: [try makeRepository(dirty: false)])
        #expect(summaries.count == 1)
        #expect(!summaries[0].isDirty)
        #expect(!summaries[0].needsAttention)
    }

    @Test("A dirty repository reports its changed file count")
    func dirtyRepository() throws {
        let summaries = RepositorySummary.summarise(repositories: [try makeRepository(dirty: true)])
        #expect(summaries[0].isDirty)
        #expect(summaries[0].changedFileCount == 1)
        #expect(summaries[0].needsAttention)
    }

    /// Clean repositories stay in the list; they just sort below the ones with work outstanding.
    @Test("Repositories needing attention sort first, and nothing is dropped")
    func attentionSortsFirst() throws {
        let clean = try makeRepository(dirty: false)
        let dirty = try makeRepository(dirty: true)
        let summaries = RepositorySummary.summarise(repositories: [clean, dirty])

        #expect(summaries.count == 2)
        #expect(summaries[0].url == dirty)
        #expect(summaries[1].url == clean)
    }

    /// A row that shows nothing is worse than no row.
    @Test("A directory that is not a repository is dropped")
    func nonRepositoryDropped() throws {
        let plain = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        #expect(RepositorySummary.summarise(repositories: [plain]).isEmpty)
    }
}
