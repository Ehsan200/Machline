import Foundation
import Testing
@testable import HarnessCore

/// A throwaway repository on disk. Git behaviour is too full of edge cases to mock convincingly, so
/// these tests drive the real binary.
final class GitTestRepository {
    let url: URL
    let manager: GitManager

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("harness-git-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        manager = GitManager(workingDirectory: url)

        try manager.runner.check(["init", "--initial-branch=main"])
        try manager.runner.check(["config", "user.name", "Harness Test"])
        try manager.runner.check(["config", "user.email", "test@example.invalid"])
        try manager.runner.check(["config", "commit.gpgsign", "false"])
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func write(_ contents: String, to path: String) throws {
        let fileURL = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
    }

    func delete(_ path: String) throws {
        try FileManager.default.removeItem(at: url.appendingPathComponent(path))
    }

    @discardableResult
    func commit(_ message: String) throws -> String {
        try manager.runner.check(["add", "-A"])
        try manager.runner.check(["commit", "-m", message])
        return try manager.runner.check(["rev-parse", "HEAD"]).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The staged content of a path — what a commit would record right now.
    func stagedContents(of path: String) throws -> String {
        try manager.runner.check(["show", ":\(path)"]).text
    }

    /// Numbered lines, so a fixture has predictable hunk boundaries.
    static func numberedLines(_ range: ClosedRange<Int>) -> String {
        range.map { "line \($0)" }.joined(separator: "\n") + "\n"
    }
}
