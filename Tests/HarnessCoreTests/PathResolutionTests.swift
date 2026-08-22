import Foundation
import Testing
@testable import HarnessCore

/// Git reports paths relative to the repository, and repositories are discovered up to three
/// levels below the workspace — so the two are often different directories. Resolving against the
/// wrong one produces a path that does not exist, and the system open call fails silently on it.
struct PathResolutionTests {

    /// Mirrors `AppModel.fileURL(for:)`, which cannot be reached from here: the app target is not
    /// a test dependency. The rule under test is the ordering, not the SwiftUI wiring.
    private func resolve(_ path: String, bases: [URL]) -> URL? {
        if path.hasPrefix("/") {
            let absolute = URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: absolute.path) ? absolute : nil
        }
        for base in bases {
            let candidate = base.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func makeTree() throws -> (workspace: URL, repository: URL) {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("paths-\(UUID().uuidString)")
        let repository = workspace.appendingPathComponent("services/api")
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try "x".write(
            to: repository.appendingPathComponent("Sources/main.swift"),
            atomically: true, encoding: .utf8)
        try "y".write(
            to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        return (workspace, repository)
    }

    /// The bug: a Git path is relative to the repository, which is not the workspace.
    @Test("A repository-relative path resolves against the repository")
    func repositoryRelative() throws {
        let (workspace, repository) = try makeTree()
        let resolved = resolve("Sources/main.swift", bases: [repository, workspace])
        #expect(resolved?.path.hasSuffix("services/api/Sources/main.swift") == true)
    }

    @Test("A workspace-relative path still resolves")
    func workspaceRelative() throws {
        let (workspace, repository) = try makeTree()
        #expect(resolve("README.md", bases: [repository, workspace]) != nil)
    }

    @Test("An absolute path is used as given")
    func absolutePath() throws {
        let (workspace, repository) = try makeTree()
        let absolute = repository.appendingPathComponent("Sources/main.swift").path
        #expect(resolve(absolute, bases: [workspace])?.path == absolute)
    }

    /// Returning a URL for a file that is not there is what made the buttons look dead: the system
    /// open call takes it and does nothing.
    @Test("A path that exists nowhere resolves to nothing")
    func missingPath() throws {
        let (workspace, repository) = try makeTree()
        #expect(resolve("nope/missing.swift", bases: [repository, workspace]) == nil)
        #expect(resolve("/definitely/not/here.swift", bases: [workspace]) == nil)
    }
}
