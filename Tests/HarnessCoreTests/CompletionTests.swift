import Foundation
import Testing
@testable import HarnessCore

/// The composer's `/` and `@` completions.
struct CompletionTriggerTests {

    @Test("A slash at the start of the message triggers command completion")
    func slashAtStart() throws {
        let trigger = try #require(CompletionTrigger.detect(in: "/co"))
        #expect(trigger.kind == .slashCommand)
        #expect(trigger.query == "co")
    }

    @Test("A bare slash offers the whole command list")
    func bareSlash() throws {
        let trigger = try #require(CompletionTrigger.detect(in: "/"))
        #expect(trigger.kind == .slashCommand)
        #expect(trigger.query.isEmpty)
    }

    /// Anywhere but the start, a slash is a path, a date, or a regex.
    @Test("A slash mid-message is not a command")
    func slashMidMessage() {
        #expect(CompletionTrigger.detect(in: "look at src/main") == nil)
        #expect(CompletionTrigger.detect(in: "rate is 1/2") == nil)
    }

    @Test("An at-sign triggers file completion anywhere in the message")
    func atAnywhere() throws {
        let atStart = try #require(CompletionTrigger.detect(in: "@Sess"))
        #expect(atStart.kind == .file)
        #expect(atStart.query == "Sess")

        let midway = try #require(CompletionTrigger.detect(in: "please read @Sources/App"))
        #expect(midway.kind == .file)
        #expect(midway.query == "Sources/App")
    }

    /// The trigger closes once the token is finished, so the list does not hang around.
    @Test("A completed token stops triggering")
    func trailingSpaceClosesTheList() {
        #expect(CompletionTrigger.detect(in: "@notes.txt ") == nil)
        #expect(CompletionTrigger.detect(in: "/compact ") == nil)
        #expect(CompletionTrigger.detect(in: "") == nil)
    }

    @Test("Accepting replaces from the trigger character, not the whole draft")
    func triggerStartAnchorsTheReplacement() throws {
        var draft = "please read @Sess"
        let trigger = try #require(CompletionTrigger.detect(in: draft))
        draft.replaceSubrange(trigger.start..., with: "@Sources/SessionRow.swift ")
        #expect(draft == "please read @Sources/SessionRow.swift ")
    }
}

struct CompletionMatcherTests {

    private let paths = [
        "Sources/Machline/SessionRailView.swift",
        "Sources/Machline/ComposerView.swift",
        "Sources/HarnessCore/SessionHistory.swift",
        "README.md"
    ]

    @Test("An empty query offers the head of the list")
    func emptyQueryOffersEverything() {
        #expect(CompletionMatcher.rank(paths, query: "").count == paths.count)
    }

    @Test("Matching is subsequence, not substring")
    func subsequenceMatching() {
        let ranked = CompletionMatcher.rank(paths, query: "srh")
        #expect(ranked.contains("Sources/HarnessCore/SessionHistory.swift"))
    }

    /// A filename hit must beat a longer path that merely contains the same letters.
    @Test("The filename outranks the directories above it")
    func filenameOutranksPath() {
        let ranked = CompletionMatcher.rank(paths, query: "Composer")
        #expect(ranked.first == "Sources/Machline/ComposerView.swift")
    }

    @Test("A query that does not match returns nothing")
    func noMatch() {
        #expect(CompletionMatcher.rank(paths, query: "zzzz").isEmpty)
    }

    @Test("Results are capped")
    func resultsAreCapped() {
        let many = (0..<100).map { "file\($0).swift" }
        #expect(CompletionMatcher.rank(many, query: "file").count == CompletionMatcher.limit)
    }

    @Test("Any candidate can be ranked by a string drawn from it")
    func ranksByKey() {
        let entries = [
            FileIndex.Entry(path: "Sources/App.swift", isDirectory: false),
            FileIndex.Entry(path: "Sources", isDirectory: true)
        ]
        let ranked = CompletionMatcher.rank(entries, query: "App", key: \.path)
        #expect(ranked.first?.path == "Sources/App.swift")
    }
}

struct FileIndexTests {

    private func makeTree() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("index-\(UUID().uuidString)")
        let manager = FileManager.default
        for directory in ["Sources/App", "node_modules/pkg", ".git/objects"] {
            try manager.createDirectory(
                at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        for file in [
            "README.md", "Sources/App/Main.swift",
            "node_modules/pkg/index.js", ".git/objects/abc"
        ] {
            try "x".write(
                to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test("Files are indexed relative to the project root")
    func indexesFilesRelatively() throws {
        let entries = FileIndex.build(for: try makeTree())
        let files = entries.filter { !$0.isDirectory }.map(\.path)
        #expect(files.contains("README.md"))
        #expect(files.contains("Sources/App/Main.swift"))
    }

    /// Folders are mentionable too — an agent asked to read a whole directory needs one.
    @Test("Directories are indexed and carry a trailing slash in the mention")
    func indexesDirectories() throws {
        let entries = FileIndex.build(for: try makeTree())
        let directory = try #require(entries.first { $0.path == "Sources/App" })
        #expect(directory.isDirectory)
        #expect(directory.mention == "Sources/App/")
        #expect(directory.name == "App")
    }

    /// On a real project `node_modules` alone is most of the tree, so it is skipped rather than
    /// walked and filtered.
    @Test("Heavy and hidden directories are skipped entirely")
    func skipsHeavyDirectories() throws {
        let entries = FileIndex.build(for: try makeTree())
        #expect(!entries.contains { $0.path.hasPrefix("node_modules") })
        #expect(!entries.contains { $0.path.hasPrefix(".git") })
    }

    @Test("A file mention has no trailing slash")
    func fileMentionsAreBare() throws {
        let entries = FileIndex.build(for: try makeTree())
        let file = try #require(entries.first { $0.path == "README.md" })
        #expect(file.mention == "README.md")
    }
}
