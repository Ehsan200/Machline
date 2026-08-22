import Foundation
import Testing
@testable import HarnessCore

/// The CLI's transcript store is an interface we read but do not own, so its shape is pinned here
/// the same way the frame schema is.
struct SessionHistoryTests {

    /// Builds a store that mirrors `~/.claude/projects/<mangled-cwd>/<session-id>.jsonl`.
    private func makeStore(
        cwd: String,
        sessions: [(id: String, lines: [String])],
        directoryName: String? = nil
    ) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("history-\(UUID().uuidString)")
        let name = directoryName
            ?? SessionHistory.directoryName(for: URL(fileURLWithPath: cwd))
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        for session in sessions {
            let file = directory.appendingPathComponent("\(session.id).jsonl")
            try session.lines.joined(separator: "\n").write(
                to: file, atomically: true, encoding: .utf8)
        }
        return root
    }

    private func transcript(
        id: String, cwd: String, prompt: String, branch: String = "main"
    ) -> [String] {
        [
            #"{"type":"queue-operation","operation":"enqueue","sessionId":"\#(id)"}"#,
            """
            {"type":"user","isSidechain":false,\
            "message":{"role":"user","content":[{"type":"text","text":"\(prompt)"}]},\
            "timestamp":"2026-08-22T09:40:59.717Z","cwd":"\(cwd)","sessionId":"\(id)",\
            "version":"2.1.239","gitBranch":"\(branch)"}
            """,
            """
            {"type":"assistant","message":{"role":"assistant","content":[]},\
            "cwd":"\(cwd)","sessionId":"\(id)"}
            """
        ]
    }

    @Test("A working directory maps to the CLI's project directory name")
    func directoryNameReplacesEverySeparator() {
        let name = SessionHistory.directoryName(
            for: URL(fileURLWithPath: "/Users/example/Developer/projects/Machline"))
        #expect(name == "-Users-example-Developer-projects-Machline")
    }

    @Test("Non-alphanumeric characters all collapse to dashes")
    func directoryNameHandlesDotsAndUnderscores() {
        let name = SessionHistory.directoryName(for: URL(fileURLWithPath: "/tmp/my_app.v2"))
        #expect(name == "-tmp-my-app-v2")
    }

    @Test("Sessions for a workspace are read with title, branch, and id")
    func readsSessionsForAWorkspace() throws {
        let cwd = "/tmp/demo-project"
        let root = try makeStore(cwd: cwd, sessions: [
            (id: "11111111-1111-1111-1111-111111111111",
             lines: transcript(
                id: "11111111-1111-1111-1111-111111111111",
                cwd: cwd, prompt: "add the parser", branch: "feature"))
        ])

        let found = SessionHistory(root: root)
            .sessions(forWorkspace: URL(fileURLWithPath: cwd))

        #expect(found.count == 1)
        #expect(found.first?.id == "11111111-1111-1111-1111-111111111111")
        #expect(found.first?.title == "add the parser")
        #expect(found.first?.gitBranch == "feature")
        #expect(found.first?.cliVersion == "2.1.239")
    }

    /// The directory-name mangling is inferred from the store, not documented, so a miss must fall
    /// back to the `cwd` each transcript records rather than reporting no history.
    @Test("A transcript in an unexpected directory is still matched by its recorded cwd")
    func fallsBackToRecordedWorkingDirectory() throws {
        let cwd = "/tmp/demo-fallback"
        let root = try makeStore(
            cwd: cwd,
            sessions: [
                (id: "22222222-2222-2222-2222-222222222222",
                 lines: transcript(
                    id: "22222222-2222-2222-2222-222222222222",
                    cwd: cwd, prompt: "unexpected directory"))
            ],
            directoryName: "totally-unrelated-name")

        let found = SessionHistory(root: root)
            .sessions(forWorkspace: URL(fileURLWithPath: cwd))

        #expect(found.count == 1)
        #expect(found.first?.title == "unexpected directory")
    }

    @Test("Sessions belonging to another project are not returned")
    func filtersByWorkingDirectory() throws {
        let mine = "/tmp/mine"
        let theirs = "/tmp/theirs"
        let root = try makeStore(cwd: mine, sessions: [
            (id: "33333333-3333-3333-3333-333333333333",
             lines: transcript(
                id: "33333333-3333-3333-3333-333333333333", cwd: theirs, prompt: "not mine"))
        ])

        let found = SessionHistory(root: root)
            .sessions(forWorkspace: URL(fileURLWithPath: mine))
        #expect(found.isEmpty)
    }

    /// A subagent's prompt is not the operator's, so it must not become the session's title.
    @Test("A sidechain prompt is not used as the title")
    func ignoresSidechainPrompts() throws {
        let cwd = "/tmp/demo-sidechain"
        let id = "44444444-4444-4444-4444-444444444444"
        let lines = [
            """
            {"type":"user","isSidechain":true,\
            "message":{"role":"user","content":[{"type":"text","text":"subagent brief"}]},\
            "cwd":"\(cwd)","sessionId":"\(id)"}
            """,
            """
            {"type":"user","isSidechain":false,\
            "message":{"role":"user","content":[{"type":"text","text":"the real prompt"}]},\
            "cwd":"\(cwd)","sessionId":"\(id)"}
            """
        ]
        let root = try makeStore(cwd: cwd, sessions: [(id: id, lines: lines)])

        let found = SessionHistory(root: root)
            .sessions(forWorkspace: URL(fileURLWithPath: cwd))
        #expect(found.first?.title == "the real prompt")
    }

    @Test("A transcript with no user message falls back to its id, not a fabricated title")
    func titlesUntitledSessionsByID() throws {
        let cwd = "/tmp/demo-empty"
        let id = "55555555-5555-5555-5555-555555555555"
        let root = try makeStore(cwd: cwd, sessions: [
            (id: id, lines: [#"{"type":"assistant","cwd":"\#(cwd)","sessionId":"\#(id)"}"#])
        ])

        let found = SessionHistory(root: root)
            .sessions(forWorkspace: URL(fileURLWithPath: cwd))
        #expect(found.first?.title == "Session 55555555")
    }

    @Test("Sessions come back most recently active first")
    func ordersByLastActivity() throws {
        let cwd = "/tmp/demo-order"
        let older = "66666666-6666-6666-6666-666666666666"
        let newer = "77777777-7777-7777-7777-777777777777"
        let root = try makeStore(cwd: cwd, sessions: [
            (id: older, lines: transcript(id: older, cwd: cwd, prompt: "older")),
            (id: newer, lines: transcript(id: newer, cwd: cwd, prompt: "newer"))
        ])

        let directory = root.appendingPathComponent(
            SessionHistory.directoryName(for: URL(fileURLWithPath: cwd)))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: directory.appendingPathComponent("\(older).jsonl").path)

        let found = SessionHistory(root: root)
            .sessions(forWorkspace: URL(fileURLWithPath: cwd))
        #expect(found.map(\.title) == ["newer", "older"])
    }
}

/// `--resume` and `--session-id` both name the session, so only one may be present.
struct ResumeArgumentTests {

    private func configuration(resume: SessionConfiguration.Resume?) -> SessionConfiguration {
        SessionConfiguration(
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            isolation: .sealed,
            resume: resume)
    }

    @Test("A fresh session names its own id")
    func freshSessionPassesSessionID() {
        let args = configuration(resume: nil).arguments()
        #expect(args.contains("--session-id"))
        #expect(!args.contains("--resume"))
    }

    @Test("Resuming passes --resume and drops --session-id")
    func resumeReplacesSessionID() {
        let args = configuration(
            resume: .init(sessionID: "abc-123")).arguments()
        #expect(!args.contains("--session-id"))
        let index = args.firstIndex(of: "--resume")
        #expect(index != nil)
        if let index { #expect(args[index + 1] == "abc-123") }
        #expect(!args.contains("--fork-session"))
    }

    @Test("Forking adds --fork-session alongside --resume")
    func forkAddsItsFlag() {
        let args = configuration(
            resume: .init(sessionID: "abc-123", fork: true)).arguments()
        #expect(args.contains("--resume"))
        #expect(args.contains("--fork-session"))
        #expect(!args.contains("--session-id"))
    }

    /// Resuming must not quietly change a session's isolation mode.
    @Test("Resuming keeps every isolation flag a sealed session asked for")
    func resumeKeepsIsolationFlags() {
        let args = configuration(resume: .init(sessionID: "abc-123")).arguments()
        #expect(args.contains("--verbose"))
        #expect(args.contains("--strict-mcp-config"))
        #expect(args.contains("--setting-sources"))
    }
}

/// Resuming does not replay, so the transcript is the only source for what a session already
/// contains. Its shape is pinned here.
struct ReplayTests {

    private func store(lines: [String], cwd: String) throws -> HistoricalSession {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("replay-\(UUID().uuidString)")
        let directory = root.appendingPathComponent(
            SessionHistory.directoryName(for: URL(fileURLWithPath: cwd)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = "88888888-8888-8888-8888-888888888888"
        try lines.joined(separator: "\n").write(
            to: directory.appendingPathComponent("\(id).jsonl"),
            atomically: true, encoding: .utf8)
        let found = SessionHistory(root: root)
            .sessions(forWorkspace: URL(fileURLWithPath: cwd))
        return found[0]
    }

    @Test("User text, assistant text, tool calls, and results all come back in order")
    func readsEveryEntryKind() throws {
        let cwd = "/tmp/replay-kinds"
        let session = try store(lines: [
            """
            {"type":"user","cwd":"\(cwd)","message":{"role":"user",\
            "content":[{"type":"text","text":"build it"}]}}
            """,
            """
            {"type":"assistant","cwd":"\(cwd)","message":{"role":"assistant","content":[\
            {"type":"text","text":"on it"},\
            {"type":"tool_use","name":"Bash","input":{"command":"swift build"}}]}}
            """,
            """
            {"type":"user","cwd":"\(cwd)","message":{"role":"user","content":[\
            {"type":"tool_result","content":"Compiling","is_error":false}]}}
            """
        ], cwd: cwd)

        let entries = SessionHistory().replay(of: session)
        #expect(entries.count == 4)
        #expect(entries[0].kind == .user("build it"))
        #expect(entries[1].kind == .assistant("on it"))
        #expect(entries[2].kind == .toolCall(name: "Bash", detail: "swift build"))
        #expect(entries[3].kind == .toolResult(text: "Compiling", isError: false))
    }

    /// A subagent's conversation is not this one's.
    @Test("Sidechain entries are excluded from the replay")
    func excludesSidechains() throws {
        let cwd = "/tmp/replay-sidechain"
        let session = try store(lines: [
            """
            {"type":"user","isSidechain":true,"cwd":"\(cwd)","message":{"role":"user",\
            "content":[{"type":"text","text":"subagent"}]}}
            """,
            """
            {"type":"user","cwd":"\(cwd)","message":{"role":"user",\
            "content":[{"type":"text","text":"mine"}]}}
            """
        ], cwd: cwd)

        let entries = SessionHistory().replay(of: session)
        #expect(entries.count == 1)
        #expect(entries[0].kind == .user("mine"))
    }

    /// A long transcript keeps its most recent entries, not its first ones.
    @Test("The replay limit keeps the end of the conversation")
    func limitKeepsTheTail() throws {
        let cwd = "/tmp/replay-limit"
        let lines = (0..<50).map { index in
            """
            {"type":"user","cwd":"\(cwd)","message":{"role":"user",\
            "content":[{"type":"text","text":"message \(index)"}]}}
            """
        }
        let session = try store(lines: lines, cwd: cwd)

        let entries = SessionHistory().replay(of: session, limit: 5)
        #expect(entries.count == 5)
        #expect(entries.last?.kind == .user("message 49"))
    }

    @Test("Entries the renderer has no form for are skipped, not rendered blank")
    func skipsUnknownBlocks() throws {
        let cwd = "/tmp/replay-unknown"
        let session = try store(lines: [
            """
            {"type":"assistant","cwd":"\(cwd)","message":{"role":"assistant","content":[\
            {"type":"some_future_block","payload":{}},{"type":"text","text":"kept"}]}}
            """,
            #"{"type":"attachment","cwd":"\#(cwd)","attachment":{"type":"whatever"}}"#
        ], cwd: cwd)

        let entries = SessionHistory().replay(of: session)
        #expect(entries.count == 1)
        #expect(entries[0].kind == .assistant("kept"))
    }
}
