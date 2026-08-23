import Foundation

/// One row of the conversation timeline.
///
/// Lives here rather than beside the view because folding a transcript into these is pure — it is
/// the one piece of the timeline that can be tested without a window.
public struct TimelineEvent: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A whole assistant reply: the id of its first block, the message id the blocks shared,
        /// and their prose joined together.
        case assistantText(UUID, String, String)
        case entry(TranscriptEntry)
    }

    public let id: UUID
    public let kind: Kind

    public init(id: UUID, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

public enum TimelineFold {

    /// Folds a transcript into what the timeline draws.
    ///
    /// Assistant frames arrive one content block at a time under a shared message id
    /// (docs/RUNTIME.md), so consecutive text blocks are joined into a single prose event rather
    /// than rendered as a run of separate paragraphs.
    ///
    /// Called from a memoised accessor, never from a view body. It walks the whole transcript and
    /// concatenates the prose of every multi-block reply, so running it per body pass re-folded the
    /// entire conversation on every frame of a stream — and on every scroll, which SwiftUI answers
    /// with a body pass of its own. The markdown and prose caches sit underneath this one and were
    /// already doing their job; this was the pass above them that nothing cached.
    public static func events(in transcript: [TranscriptEntry]) -> [TimelineEvent] {
        var events: [TimelineEvent] = []
        events.reserveCapacity(transcript.count)

        for entry in transcript {
            guard case .text(let id, let messageID, let text) = entry else {
                events.append(TimelineEvent(id: entry.id, kind: .entry(entry)))
                continue
            }
            if case .assistantText(let firstID, let previousID, let existing)? = events.last?.kind,
               previousID == messageID {
                // Keyed on the id of the *first* block of the reply, not the latest. The last block
                // changes on every frame while a reply streams, and an id that changes underneath
                // `ForEach` costs the row its identity — and with it its scroll position.
                events[events.count - 1] = TimelineEvent(
                    id: firstID, kind: .assistantText(firstID, messageID, existing + text))
                continue
            }
            events.append(TimelineEvent(id: id, kind: .assistantText(id, messageID, text)))
        }
        return events
    }
}
