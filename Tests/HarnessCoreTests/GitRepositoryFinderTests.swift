import Foundation
import Testing
@testable import HarnessCore

/// A project folder is often a container of repositories rather than one itself.
struct GitRepositoryFinderTests {

    private func makeTree(_ repositories: [String], extras: [String] = []) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("repos-\(UUID().uuidString)")
        let manager = FileManager.default
        for path in repositories {
            try manager.createDirectory(
                at: root.appendingPathComponent(path).appendingPathComponent(".git"),
                withIntermediateDirectories: true)
        }
        for path in extras {
            try manager.createDirectory(
                at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        return root
    }

    @Test("A workspace that is itself a repository is the only result")
    func workspaceIsTheRepository() throws {
        let root = try makeTree([""])
        let found = GitRepositoryFinder.repositories(under: root)
        #expect(found.map(\.lastPathComponent) == [root.lastPathComponent])
    }

    @Test("Repositories in subfolders are found")
    func findsNestedRepositories() throws {
        let root = try makeTree(["api", "web", "team/service"])
        let found = GitRepositoryFinder.repositories(under: root)
            .map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }
        #expect(Set(found) == ["api", "web", "team/service"])
    }

    /// Shallowest first, so the nearest repository is the one selected by default.
    @Test("Results are ordered nearest first")
    func nearestFirst() throws {
        let root = try makeTree(["deep/deeper/repo", "top"])
        let found = GitRepositoryFinder.repositories(under: root)
            .map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }
        #expect(found.first == "top")
    }

    @Test("The search stops at the depth limit")
    func respectsDepthLimit() throws {
        let root = try makeTree(["a/b/c/d/too-deep"])
        #expect(GitRepositoryFinder.repositories(under: root, maxDepth: 3).isEmpty)
        #expect(!GitRepositoryFinder.repositories(under: root, maxDepth: 5).isEmpty)
    }

    /// A repository inside a working tree is a submodule or a vendored copy — it belongs to its
    /// parent, not beside it in the list.
    @Test("A repository inside a repository is not listed separately")
    func doesNotDescendIntoRepositories() throws {
        let root = try makeTree(["outer", "outer/vendor/inner"])
        let found = GitRepositoryFinder.repositories(under: root)
            .map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }
        #expect(found == ["outer"])
    }

    @Test("Heavy directories are not walked")
    func skipsHeavyDirectories() throws {
        let root = try makeTree(["node_modules/pkg", "real"])
        let found = GitRepositoryFinder.repositories(under: root)
            .map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }
        #expect(found == ["real"])
    }

    @Test("A folder with no repositories returns nothing")
    func noRepositories() throws {
        let root = try makeTree([], extras: ["docs", "assets"])
        #expect(GitRepositoryFinder.repositories(under: root).isEmpty)
    }

    /// A `.git` file rather than a directory is a worktree or submodule pointer, and `git` treats
    /// it as a repository.
    @Test("A .git file counts as a repository")
    func gitFileCounts() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worktree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("linked"), withIntermediateDirectories: true)
        try "gitdir: /elsewhere".write(
            to: root.appendingPathComponent("linked/.git"), atomically: true, encoding: .utf8)

        let found = GitRepositoryFinder.repositories(under: root)
        #expect(found.map(\.lastPathComponent) == ["linked"])
    }
}
