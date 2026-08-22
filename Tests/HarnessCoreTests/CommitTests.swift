import Foundation
import Testing
@testable import HarnessCore

@Suite("Commit composition")
struct CommitTests {

    // MARK: - Rendering and parsing

    @Test("A commit renders in Conventional Commits form")
    func rendering() {
        let commit = ConventionalCommit(
            kind: .feat, scope: "approval", summary: "add hunk staging",
            body: "Explains why.", footers: ["Refs: #12"])
        #expect(commit.subject == "feat(approval): add hunk staging")
        #expect(commit.rendered() == "feat(approval): add hunk staging\n\nExplains why.\n\nRefs: #12")
    }

    @Test("Breaking changes are marked with a bang")
    func breakingMarker() {
        let commit = ConventionalCommit(
            kind: .refactor, scope: "core", isBreaking: true, summary: "drop libgit2")
        #expect(commit.subject == "refactor(core)!: drop libgit2")
    }

    @Test("An edited message round-trips back into the composer", arguments: [
        "feat: add thing",
        "fix(parser): handle empty input",
        "refactor(core)!: drop libgit2",
        "docs: update readme\n\nA body paragraph.",
        "chore: bump deps\n\nBody text.\n\nRefs: #9\nCo-authored-by: Someone",
    ])
    func roundTrip(message: String) throws {
        let parsed = try #require(ConventionalCommit.parse(message))
        #expect(parsed.rendered() == message)
    }

    @Test("Non-conventional messages are rejected rather than guessed at", arguments: [
        "just some text",
        "notatype: thing",
        "",
    ])
    func rejectsNonConventional(message: String) {
        #expect(ConventionalCommit.parse(message) == nil)
    }

    // MARK: - Advisories

    /// Advisory only: a long subject produces a warning, never a blocked commit (docs/RUNTIME.md).
    @Test("Style guidance is reported without blocking anything")
    func advisories() {
        let long = ConventionalCommit(
            kind: .feat, scope: "workbench",
            summary: "add an extremely long summary that runs well past the fifty character guide.")
        let kinds = Set(long.advisories().map(\.kind))
        #expect(kinds.contains(.subjectTooLong))
        #expect(kinds.contains(.subjectEndsWithPeriod))

        let clean = ConventionalCommit(kind: .fix, summary: "handle empty input")
        #expect(clean.advisories().isEmpty)
    }

    @Test("Body lines beyond the wrap guide are flagged with their line number")
    func bodyWrapAdvisory() {
        let commit = ConventionalCommit(
            kind: .docs, summary: "update guide",
            body: "short line\n" + String(repeating: "x", count: 90))
        let advisory = commit.advisories().first { $0.kind == .bodyLineTooLong }
        #expect(advisory != nil)
        #expect(advisory?.detail.contains("line 2") == true)
    }

    // MARK: - Committing

    @Test("Committing requires staged changes")
    func requiresStagedChanges() throws {
        let repository = try GitTestRepository()
        try repository.write("one\n", to: "file.txt")
        try repository.commit("initial")
        try repository.write("two\n", to: "file.txt")  // Unstaged only.

        #expect(throws: GitManager.Failure.self) {
            try repository.manager.commit(message: "fix: should not happen")
        }
    }

    @Test("Committing requires a message")
    func requiresMessage() throws {
        let repository = try GitTestRepository()
        try repository.write("one\n", to: "file.txt")
        try repository.manager.stage(paths: ["file.txt"])

        #expect(throws: GitManager.Failure.self) {
            try repository.manager.commit(message: "   \n  ")
        }
    }

    @Test("A commit records exactly the staged content")
    func commitRecordsStagedContent() throws {
        let repository = try GitTestRepository()
        try repository.write(GitTestRepository.numberedLines(1...30), to: "file.txt")
        try repository.commit("initial")

        var lines = (1...30).map { "line \($0)" }
        lines[4] = "line 5 CHANGED"
        lines[24] = "line 25 CHANGED"
        try repository.write(lines.joined(separator: "\n") + "\n", to: "file.txt")

        // Stage only the second hunk, then commit.
        let diff = try #require(try repository.manager.unstagedDiff().first)
        try repository.manager.stage(diff: diff, hunkIDs: [1])

        let commit = ConventionalCommit(kind: .fix, scope: "file", summary: "correct line 25")
        let sha = try repository.manager.commit(message: commit.rendered())
        #expect(sha.count == 40)

        let committed = try repository.manager.runner.check(["show", "HEAD:file.txt"]).text
        #expect(committed.contains("line 25 CHANGED"))
        #expect(!committed.contains("line 5 CHANGED"), "The unstaged hunk must not be committed")

        let recent = try repository.manager.recentCommits(limit: 1)
        #expect(recent.first?.subject == "fix(file): correct line 25")
        #expect(recent.first?.id == sha)

        // The unstaged edit survives the commit.
        #expect(try repository.read("file.txt").contains("line 5 CHANGED"))
    }

    @Test("Recent commits parse with fields intact, including awkward subjects")
    func recentCommitsParsing() throws {
        let repository = try GitTestRepository()
        try repository.write("one\n", to: "file.txt")
        try repository.commit("feat: first")
        try repository.write("two\n", to: "file.txt")
        try repository.commit("fix: subject with: colons, commas and \"quotes\"")

        let commits = try repository.manager.recentCommits(limit: 10)
        #expect(commits.count == 2)
        #expect(commits[0].subject == "fix: subject with: colons, commas and \"quotes\"")
        #expect(commits[1].subject == "feat: first")
        #expect(commits.allSatisfy { $0.author == "Harness Test" })
        #expect(commits.allSatisfy { !$0.date.isEmpty })
    }

    @Test("Recent commits on an unborn branch return empty rather than failing")
    func recentCommitsUnborn() throws {
        let repository = try GitTestRepository()
        #expect(try repository.manager.recentCommits().isEmpty)
    }

    // MARK: - Draft parsing

    /// The structured payload arrives as a JSON string inside the `result` field of the
    /// `--output-format json` envelope.
    @Test("A drafted commit is extracted from the CLI's JSON envelope")
    func parsesDraftEnvelope() throws {
        let envelope = #"""
        {"type":"result","subtype":"success","is_error":false,"result":"{\"kind\":\"feat\",\"scope\":\"git\",\"isBreaking\":false,\"summary\":\"add hunk staging\",\"body\":\"Why it matters.\"}"}
        """#
        let commit = try CommitDraftGenerator.parseResponse(envelope)
        #expect(commit.kind == .feat)
        #expect(commit.scope == "git")
        #expect(commit.summary == "add hunk staging")
        #expect(commit.body == "Why it matters.")
        #expect(!commit.isBreaking)
    }

    @Test("A draft payload nested directly is also accepted")
    func parsesDirectPayload() throws {
        let envelope = #"{"kind":"fix","summary":"handle empty input","isBreaking":false}"#
        let commit = try CommitDraftGenerator.parseResponse(envelope)
        #expect(commit.kind == .fix)
        #expect(commit.scope == nil)
        #expect(commit.body == nil)
    }

    @Test("An unusable draft response is an error, not a silent empty commit message")
    func rejectsUnusableDraft() {
        #expect(throws: CommitDraftGenerator.Failure.self) {
            try CommitDraftGenerator.parseResponse("not json")
        }
        #expect(throws: CommitDraftGenerator.Failure.self) {
            try CommitDraftGenerator.parseResponse(#"{"result":"{\"kind\":\"nonsense\"}"}"#)
        }
    }

    @Test("Drafting refuses when nothing is staged")
    func draftRequiresStagedChanges() async throws {
        let repository = try GitTestRepository()
        try repository.write("one\n", to: "file.txt")
        try repository.commit("initial")

        await #expect(throws: CommitDraftGenerator.Failure.self) {
            try await CommitDraftGenerator().draft(for: repository.manager)
        }
    }
}

/// Drafting spawns the real `claude` binary. Opt-in via `HARNESS_LIVE_TESTS=1`.
@Suite("Live commit drafting",
       .enabled(if: ProcessInfo.processInfo.environment["HARNESS_LIVE_TESTS"] == "1"))
struct LiveCommitDraftTests {

    @Test("A staged change yields a usable Conventional Commit draft", .timeLimit(.minutes(3)))
    func draftsFromStagedDiff() async throws {
        let repository = try GitTestRepository()
        try repository.write("""
        func parse(_ input: String) -> Int {
            return Int(input) ?? 0
        }

        """, to: "Parser.swift")
        try repository.commit("initial")

        // An unambiguous bug fix, so the model has a clear signal to classify.
        try repository.write("""
        func parse(_ input: String) -> Int? {
            guard !input.isEmpty else { return nil }
            return Int(input)
        }

        """, to: "Parser.swift")
        try repository.manager.stage(paths: ["Parser.swift"])

        let draft = try await CommitDraftGenerator(model: "haiku").draft(for: repository.manager)

        #expect(!draft.summary.isEmpty)
        #expect(ConventionalCommit.Kind.allCases.contains(draft.kind))
        // The draft must be committable as-is, whatever wording the model chose.
        let sha = try repository.manager.commit(message: draft.rendered())
        #expect(sha.count == 40)

        let recorded = try #require(try repository.manager.recentCommits(limit: 1).first)
        #expect(recorded.subject == draft.subject)
        #expect(ConventionalCommit.parse(recorded.subject) != nil,
                "A drafted subject must parse back as Conventional Commits")
    }
}
