import Foundation
import Testing
@testable import HarnessCore

@Suite("The command line a commit draft is run with")
struct CommitDraftArgumentTests {

    static let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    /// The transcript is deleted by the id it was asked for, so a run that never reports one back —
    /// cancelled, killed, crashed — still leaves nothing in the operator's session list.
    @Test("Both paths name the session themselves")
    func namesTheSession() {
        let cold = CommitDraftGenerator.arguments(
            sessionID: Self.sessionID, fork: nil, model: "haiku", effort: "low")
        let forked = CommitDraftGenerator.arguments(
            sessionID: Self.sessionID,
            fork: .init(sessionID: "parent-id", workingDirectory: URL(fileURLWithPath: "/tmp")),
            model: "haiku", effort: "low")

        let expected = Self.sessionID.uuidString.lowercased()
        #expect(value(of: "--session-id", in: cold) == expected)
        #expect(value(of: "--session-id", in: forked) == expected)
    }

    /// Overriding the model on a fork throws the warm cache away and re-sends the conversation,
    /// which is slower than the cold small model rather than faster.
    @Test("A fork resumes its parent and keeps that session's model")
    func forkKeepsItsModel() {
        let forked = CommitDraftGenerator.arguments(
            sessionID: Self.sessionID,
            fork: .init(sessionID: "parent-id", workingDirectory: URL(fileURLWithPath: "/tmp")),
            model: "haiku", effort: "low")

        #expect(forked.contains("--fork-session"))
        #expect(value(of: "--resume", in: forked) == "parent-id")
        #expect(!forked.contains("--model"))
    }

    @Test("A cold run picks its own model")
    func coldRunPicksAModel() {
        let cold = CommitDraftGenerator.arguments(
            sessionID: Self.sessionID, fork: nil, model: "haiku", effort: "low")

        #expect(value(of: "--model", in: cold) == "haiku")
        #expect(!cold.contains("--fork-session"))
    }

    /// Drafting reads a diff it was handed. It has no business in the operator's settings, their
    /// MCP servers, or the working tree.
    @Test("Drafting runs sealed off from settings and tools")
    func runsSealedOff() {
        let cold = CommitDraftGenerator.arguments(
            sessionID: Self.sessionID, fork: nil, model: nil, effort: nil)

        #expect(value(of: "--setting-sources", in: cold) == "")
        #expect(value(of: "--tools", in: cold) == "")
        #expect(cold.contains("--strict-mcp-config"))
        #expect(!cold.contains("--effort"))
    }

    private func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
}
