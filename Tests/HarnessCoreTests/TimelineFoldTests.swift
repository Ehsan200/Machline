import Foundation
import Testing
@testable import HarnessCore

@Suite("Timeline folding")
struct TimelineFoldTests {

    static func text(_ messageID: String, _ body: String) -> TranscriptEntry {
        .text(id: UUID(), messageID: messageID, text: body)
    }

    static func prose(_ event: TimelineEvent) -> String? {
        guard case .assistantText(_, _, let body) = event.kind else { return nil }
        return body
    }

    @Test("An empty transcript folds to nothing")
    func empty() {
        #expect(TimelineFold.events(in: []).isEmpty)
    }

    @Test("Blocks of one reply are joined into a single event")
    func joinsBlocksOfOneMessage() {
        let events = TimelineFold.events(in: [
            Self.text("m1", "first "),
            Self.text("m1", "second "),
            Self.text("m1", "third")
        ])
        #expect(events.count == 1)
        #expect(Self.prose(events[0]) == "first second third")
    }

    @Test("Separate replies stay separate events")
    func keepsMessagesApart() {
        let events = TimelineFold.events(in: [
            Self.text("m1", "one"),
            Self.text("m2", "two")
        ])
        #expect(events.count == 2)
        #expect(Self.prose(events[0]) == "one")
        #expect(Self.prose(events[1]) == "two")
    }

    @Test("A tool call between two blocks of one reply breaks the run")
    func nonTextInterrupts() {
        let events = TimelineFold.events(in: [
            Self.text("m1", "before"),
            .incident(id: UUID(), text: "gate failed open"),
            Self.text("m1", "after")
        ])
        // Same message id, but folding them would reorder the incident out of the conversation.
        #expect(events.count == 3)
        #expect(Self.prose(events[0]) == "before")
        #expect(Self.prose(events[2]) == "after")
    }

    @Test("Non-text entries keep their own identity")
    func passesThroughNonText() {
        let incident = TranscriptEntry.incident(id: UUID(), text: "gate failed open")
        let events = TimelineFold.events(in: [incident])
        #expect(events.count == 1)
        #expect(events[0].id == incident.id)
        #expect(events[0].kind == .entry(incident))
    }

    @Test("Thinking is not folded into the prose beside it")
    func thinkingIsNotProse() {
        let events = TimelineFold.events(in: [
            .thinking(id: UUID(), messageID: "m1", text: "considering"),
            Self.text("m1", "answer")
        ])
        #expect(events.count == 2)
        #expect(Self.prose(events[0]) == nil)
        #expect(Self.prose(events[1]) == "answer")
    }

    /// The row's identity has to survive a reply growing under it. Keying the folded event on the
    /// newest block meant the id changed on every frame of a stream, and `ForEach` answers a
    /// changed id by tearing the row down and building a new one — which drops the text selection
    /// and re-runs the layout of the longest view on screen.
    @Test("A growing reply keeps the id it started with")
    func identityIsStableWhileStreaming() {
        let first = Self.text("m1", "half ")
        let second = Self.text("m1", "done")

        let partial = TimelineFold.events(in: [first])
        let whole = TimelineFold.events(in: [first, second])

        #expect(partial.count == 1)
        #expect(whole.count == 1)
        #expect(partial[0].id == whole[0].id)
        #expect(partial[0].id == first.id)
        #expect(Self.prose(whole[0]) == "half done")
    }

    @Test("Folding is stable: the same transcript folds to the same events")
    func deterministic() {
        let transcript = [
            Self.text("m1", "a"),
            Self.text("m1", "b"),
            .incident(id: UUID(), text: "x"),
            Self.text("m2", "c")
        ]
        #expect(TimelineFold.events(in: transcript) == TimelineFold.events(in: transcript))
    }
}
