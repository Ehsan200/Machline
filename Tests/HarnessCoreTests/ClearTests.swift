import Foundation
import Testing
@testable import HarnessCore

@Suite("Clearing the conversation")
struct ClearTests {

    static func graph(replaying fixture: Fixture) throws -> AgentGraph {
        var graph = AgentGraph()
        for frame in try fixture.frames() { graph.apply(frame: frame) }
        return graph
    }

    @Test("Every agent's transcript is emptied")
    func emptiesTranscripts() throws {
        var graph = try Self.graph(replaying: .subagent)
        #expect(graph.nodes.count > 1)
        #expect(graph.nodes.values.contains { !$0.transcript.isEmpty })

        graph.clearTranscripts()
        #expect(graph.nodes.values.allSatisfy { $0.transcript.isEmpty })
        #expect(graph.nodes.values.allSatisfy { $0.streamingText.isEmpty })
    }

    /// `/clear` resets the conversation the agent is carrying, not the session carrying it. The
    /// tree has to survive or there is nothing left to talk to.
    @Test("The agent tree survives, capabilities and all")
    func keepsTheTree() throws {
        var graph = try Self.graph(replaying: .subagent)
        let before = graph.orderedNodes().map(\.id)
        let capabilities = graph.root?.capabilities

        graph.clearTranscripts()
        #expect(graph.orderedNodes().map(\.id) == before)
        #expect(graph.root?.capabilities == capabilities)
        #expect(graph.rootID != nil)
    }

    /// Spend already billed stays billed — clearing the screen does not refund the turn.
    @Test("Spend and turn counts survive")
    func keepsSpend() throws {
        var graph = try Self.graph(replaying: .plainTurn)
        let root = try #require(graph.root)
        let billed = root.telemetry.billedTokens
        let turns = root.telemetry.turnCount
        let cost = root.telemetry.costUSD
        #expect(billed > 0)

        graph.clearTranscripts()
        let cleared = try #require(graph.root)
        #expect(cleared.telemetry.billedTokens == billed)
        #expect(cleared.telemetry.turnCount == turns)
        #expect(cleared.telemetry.costUSD == cost)
    }

    /// The occupancy figure is the exception: after a clear the window is empty, and leaving the
    /// last turn's number standing draws a full ring over an empty conversation.
    @Test("Context occupancy is dropped")
    func dropsOccupancy() throws {
        var graph = try Self.graph(replaying: .plainTurn)
        #expect(graph.root?.telemetry.contextTokens != nil)

        graph.clearTranscripts()
        #expect(graph.root?.telemetry.contextTokens == nil)
    }

    @Test("Clearing reports one structural change per agent it emptied")
    func reportsChanges() throws {
        var graph = try Self.graph(replaying: .plainTurn)
        let changes = graph.clearTranscripts()

        #expect(!changes.isEmpty)
        #expect(changes.allSatisfy {
            if case .transcriptCleared = $0 { return true }
            return false
        })
        // Never coalesced away as a streaming burst: this is the frame that empties the screen.
        #expect(changes.allSatisfy {
            if case .streamingUpdated = $0 { return false }
            return true
        })
    }

    @Test("Clearing an already-empty conversation reports nothing")
    func idempotent() throws {
        var graph = try Self.graph(replaying: .plainTurn)
        graph.clearTranscripts()
        #expect(graph.clearTranscripts().isEmpty)
    }

    @Test("Clearing an empty graph is a no-op rather than a crash")
    func emptyGraph() {
        var graph = AgentGraph()
        #expect(graph.clearTranscripts().isEmpty)
        #expect(graph.root == nil)
    }

    /// The transcript has to actually be gone, not merely hidden: the timeline folds from it, and
    /// a cleared screen over a populated transcript would come back on the next refresh.
    @Test("A cleared transcript folds to an empty timeline")
    func foldsToNothing() throws {
        var graph = try Self.graph(replaying: .plainTurn)
        let root = try #require(graph.root)
        #expect(!TimelineFold.events(in: root.transcript).isEmpty)

        graph.clearTranscripts()
        let cleared = try #require(graph.root)
        #expect(TimelineFold.events(in: cleared.transcript).isEmpty)
    }
}
