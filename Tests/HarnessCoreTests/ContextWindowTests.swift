import Foundation
import Testing
@testable import HarnessCore

/// The runtime reports how many tokens a turn used but never the size of the window, so the
/// denominator is a lookup. Getting it wrong misreports how full the context is — which is the one
/// number an operator acts on.
struct ContextWindowTests {

    @Test("Current 1M models resolve to the large window")
    func largeWindowModels() {
        for name in [
            "claude-opus-5", "claude-sonnet-5", "claude-fable-5",
            "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-4-6"
        ] {
            #expect(ContextWindow.size(forModel: name) == ContextWindow.large, "\(name)")
        }
    }

    @Test("Haiku resolves to the small window")
    func haikuIsSmall() {
        #expect(ContextWindow.size(forModel: "claude-haiku-4-5") == ContextWindow.small)
        #expect(ContextWindow.size(forModel: "haiku") == ContextWindow.small)
    }

    /// The CLI takes an alias in place of an id, so the picker's value is often one of these.
    @Test("Family aliases resolve like the family's latest model")
    func aliasesResolve() {
        #expect(ContextWindow.size(forModel: "opus") == ContextWindow.large)
        #expect(ContextWindow.size(forModel: "sonnet") == ContextWindow.large)
        #expect(ContextWindow.size(forModel: "fable") == ContextWindow.large)
    }

    @Test("A dated snapshot resolves like its base id")
    func datedSnapshotsResolve() {
        #expect(ContextWindow.size(forModel: "claude-opus-4-6-20251101") == ContextWindow.large)
    }

    /// Understating the denominator shows the context fuller than it is, which fails toward
    /// caution rather than toward a surprise mid-turn.
    @Test("An unknown or absent model falls back to the small window")
    func unknownFallsBackSmall() {
        #expect(ContextWindow.size(forModel: nil) == ContextWindow.small)
        #expect(ContextWindow.size(forModel: "") == ContextWindow.small)
        #expect(ContextWindow.size(forModel: "some-future-model") == ContextWindow.small)
    }

    @Test("An explicit 1M marker wins over the family")
    func explicitMarkerWins() {
        #expect(ContextWindow.size(forModel: "claude-haiku-4-5[1m]") == ContextWindow.large)
    }
}

/// A resumed conversation already occupies its window, but no turn has completed in this process.
struct RecordedUsageTests {

    private func session(lines: [String]) throws -> HistoricalSession {
        let cwd = "/tmp/usage-project"
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("usage-\(UUID().uuidString)")
        let directory = root.appendingPathComponent(
            SessionHistory.directoryName(for: URL(fileURLWithPath: cwd)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        try lines.joined(separator: "\n").write(
            to: directory.appendingPathComponent("\(id).jsonl"),
            atomically: true, encoding: .utf8)
        return SessionHistory(root: root)
            .sessions(forWorkspace: URL(fileURLWithPath: cwd))[0]
    }

    private func assistant(cwd: String, input: Int, cacheRead: Int, output: Int) -> String {
        """
        {"type":"assistant","cwd":"\(cwd)","message":{"role":"assistant","model":"claude-opus-5",\
        "content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":\(input),\
        "cache_creation_input_tokens":100,"cache_read_input_tokens":\(cacheRead),\
        "output_tokens":\(output)}}}
        """
    }

    @Test("Context is the prompt, the cache, and the reply together")
    func sumsEveryComponent() throws {
        let cwd = "/tmp/usage-project"
        let recorded = try #require(SessionHistory().lastUsage(of: session(lines: [
            #"{"type":"user","cwd":"\#(cwd)","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}"#,
            assistant(cwd: cwd, input: 2, cacheRead: 595_907, output: 4_408)
        ])))
        #expect(recorded.contextTokens == 2 + 100 + 595_907 + 4_408)
        #expect(recorded.model == "claude-opus-5")
    }

    /// The newest turn is what occupies the window, not the first.
    @Test("The last recorded turn wins")
    func lastTurnWins() throws {
        let cwd = "/tmp/usage-project"
        let recorded = try #require(SessionHistory().lastUsage(of: session(lines: [
            assistant(cwd: cwd, input: 1, cacheRead: 1_000, output: 10),
            assistant(cwd: cwd, input: 2, cacheRead: 9_000, output: 20)
        ])))
        #expect(recorded.cacheReadTokens == 9_000)
    }

    @Test("A transcript with no assistant turn reports no usage")
    func noAssistantTurn() throws {
        let cwd = "/tmp/usage-project"
        let recorded = try SessionHistory().lastUsage(of: session(lines: [
            #"{"type":"user","cwd":"\#(cwd)","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}"#
        ]))
        #expect(recorded == nil)
    }

    /// A subagent's turn is not the root conversation's occupancy.
    @Test("Sidechain turns are ignored")
    func ignoresSidechains() throws {
        let cwd = "/tmp/usage-project"
        let lines = [
            assistant(cwd: cwd, input: 2, cacheRead: 500, output: 20),
            """
            {"type":"assistant","isSidechain":true,"cwd":"\(cwd)","message":{"role":"assistant",\
            "model":"claude-haiku-4-5","content":[],"usage":{"input_tokens":9,\
            "cache_creation_input_tokens":0,"cache_read_input_tokens":99999,"output_tokens":9}}}
            """
        ]
        let recorded = try #require(SessionHistory().lastUsage(of: session(lines: lines)))
        #expect(recorded.cacheReadTokens == 500)
    }
}
