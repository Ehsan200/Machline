import Foundation
import Testing
@testable import HarnessCore

/// The landing page walks every project the CLI knows about, which is a visible pause on a machine
/// with dozens of them. The cache is what makes an empty window useful the instant it opens.
struct HomeCacheTests {

    private func makeCache() -> HomeCache {
        HomeCache(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("home-cache-\(UUID().uuidString)"))
    }

    private func session(_ id: String, title: String) -> HistoricalSession {
        HistoricalSession(
            id: id, fileURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"),
            cwd: "/tmp/project", firstPrompt: title, startedAt: Date(),
            lastActivityAt: Date(), gitBranch: "main", cliVersion: "2.1.239",
            model: "claude-opus-5", byteCount: 10)
    }

    @Test("A snapshot survives a round trip intact")
    func roundTrip() throws {
        let cache = makeCache()
        let snapshot = HomeCache.Snapshot(projects: [
            HomeCache.Project(
                workspace: URL(fileURLWithPath: "/tmp/project"),
                sessions: [session("a", title: "first"), session("b", title: "second")])
        ])
        cache.write(snapshot)

        let read = try #require(cache.read())
        #expect(read.projects.count == 1)
        #expect(read.projects[0].workspace.path == "/tmp/project")
        #expect(read.projects[0].sessions.map(\.firstPrompt) == ["first", "second"])
        #expect(read.projects[0].sessions[0].gitBranch == "main")
    }

    @Test("No cache yet reads as nothing rather than failing")
    func missingCache() {
        #expect(makeCache().read() == nil)
    }

    /// A corrupt cache must degrade to a slow launch, never to a crash.
    @Test("A damaged cache is ignored")
    func corruptCache() throws {
        let cache = makeCache()
        try "not json at all".write(to: cache.fileURL, atomically: true, encoding: .utf8)
        #expect(cache.read() == nil)
    }

    @Test("Clearing removes it")
    func clearing() {
        let cache = makeCache()
        cache.write(HomeCache.Snapshot(projects: []))
        #expect(cache.read() != nil)
        cache.clear()
        #expect(cache.read() == nil)
    }
}

/// A transcript's first user entry is often a wrapper the CLI injected rather than anything the
/// operator typed, and using it as a title fills the list with rows that all read the same.
struct SyntheticTitleTests {

    private func transcript(lines: [String]) throws -> HistoricalSession {
        let cwd = "/tmp/titles-project"
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("titles-\(UUID().uuidString)")
        let directory = root.appendingPathComponent(
            SessionHistory.directoryName(for: URL(fileURLWithPath: cwd)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(
            to: directory.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        return SessionHistory(root: root)
            .sessions(forWorkspace: URL(fileURLWithPath: cwd))[0]
    }

    private func user(_ text: String, cwd: String = "/tmp/titles-project") -> String {
        """
        {"type":"user","cwd":"\(cwd)","message":{"role":"user",\
        "content":[{"type":"text","text":"\(text)"}]}}
        """
    }

    @Test("A caveat wrapper is skipped in favour of what the operator wrote")
    func skipsCaveat() throws {
        let session = try transcript(lines: [
            user("<local-command-caveat>Caveat: The messages below were generated"),
            user("actually fix the parser")
        ])
        #expect(session.title == "actually fix the parser")
    }

    @Test("A command-name wrapper is skipped too")
    func skipsCommandName() throws {
        let session = try transcript(lines: [
            user("<command-name>/compact</command-name>"),
            user("the real question")
        ])
        #expect(session.title == "the real question")
    }

    /// A transcript that is only wrappers still needs a title, and an id beats a wrapper.
    @Test("A transcript of nothing but wrappers falls back to its id")
    func onlyWrappers() throws {
        let session = try transcript(lines: [
            user("<local-command-caveat>Caveat: The messages below were generated")
        ])
        #expect(session.title.hasPrefix("Session "))
    }

    @Test("An ordinary first prompt is used as it is")
    func ordinaryPrompt() throws {
        let session = try transcript(lines: [user("add the parser")])
        #expect(session.title == "add the parser")
    }
}
