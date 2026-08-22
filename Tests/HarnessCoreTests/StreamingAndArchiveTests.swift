import Foundation
import Testing
@testable import HarnessCore

/// Partial-message frames are a preview of a reply, not a second copy of it. These pin the moment
/// the preview is discarded — getting that wrong shows the same text twice.
struct StreamingTests {

    private func frame(_ json: String) throws -> Frame {
        guard case .frame(let frame) = FrameDecoder().decode(line: json) else {
            throw DecodeFailure.notAFrame(json)
        }
        return frame
    }

    enum DecodeFailure: Error { case notAFrame(String) }

    private func delta(_ text: String) -> String {
        """
        {"type":"stream_event","session_id":"s","uuid":"u",\
        "event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"\(text)"}}}
        """
    }

    @Test("Text deltas accumulate into the streaming buffer")
    func deltasAccumulate() throws {
        var graph = AgentGraph()
        _ = graph.apply(frame: try frame(delta("Hel")))
        _ = graph.apply(frame: try frame(delta("lo")))
        #expect(graph.root?.streamingText == "Hello")
    }

    @Test("A delta reports a streaming change, not a transcript append")
    func deltaReportsStreaming() throws {
        var graph = AgentGraph()
        let changes = graph.apply(frame: try frame(delta("hi")))
        #expect(changes.contains { if case .streamingUpdated = $0 { return true } else { return false } })
        #expect(!changes.contains { if case .transcriptAppended = $0 { return true } else { return false } })
    }

    /// The assembled block is the record; leaving the preview up beside it duplicates the reply.
    @Test("The assembled assistant message clears the preview")
    func assembledMessageClearsBuffer() throws {
        var graph = AgentGraph()
        _ = graph.apply(frame: try frame(delta("partial")))
        #expect(graph.root?.streamingText == "partial")

        _ = graph.apply(frame: try frame("""
            {"type":"assistant","session_id":"s","uuid":"u","message":{"id":"m1","role":"assistant",\
            "content":[{"type":"text","text":"partial and complete"}]}}
            """))

        #expect(graph.root?.streamingText.isEmpty == true)
        #expect(graph.root?.transcript.count == 1)
    }

    @Test("A new content block starts its preview from empty")
    func newBlockResetsBuffer() throws {
        var graph = AgentGraph()
        _ = graph.apply(frame: try frame(delta("first")))
        _ = graph.apply(frame: try frame("""
            {"type":"stream_event","session_id":"s","uuid":"u",\
            "event":{"type":"content_block_start","index":1}}
            """))
        #expect(graph.root?.streamingText.isEmpty == true)
    }

    @Test("Deltas that are not text are ignored")
    func nonTextDeltasIgnored() throws {
        var graph = AgentGraph()
        _ = graph.apply(frame: try frame("""
            {"type":"stream_event","session_id":"s","uuid":"u",\
            "event":{"type":"content_block_delta","delta":{"type":"input_json_delta",\
            "partial_json":"{\\"a\\":"}}}
            """))
        #expect(graph.root?.streamingText.isEmpty == true)
    }
}

/// Archiving must be reversible and deletion must not be. Both act on the CLI's own store, so the
/// boundary between them is pinned.
struct SessionArchiveTests {

    private func makeStore() throws -> (store: SessionHistory, archive: SessionArchive, cwd: String) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("archive-\(UUID().uuidString)")
        let cwd = "/tmp/archive-project"
        let directory = base
            .appendingPathComponent("projects")
            .appendingPathComponent(SessionHistory.directoryName(for: URL(fileURLWithPath: cwd)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let id = "99999999-9999-9999-9999-999999999999"
        let line = """
            {"type":"user","cwd":"\(cwd)","sessionId":"\(id)","message":{"role":"user",\
            "content":[{"type":"text","text":"archive me"}]}}
            """
        try line.write(
            to: directory.appendingPathComponent("\(id).jsonl"),
            atomically: true, encoding: .utf8)

        return (
            SessionHistory(root: base.appendingPathComponent("projects")),
            SessionArchive(root: base.appendingPathComponent("archived")),
            cwd)
    }

    @Test("Archiving removes a session from the live list and lists it as archived")
    func archiveMovesTheTranscript() throws {
        let (store, archive, cwd) = try makeStore()
        let workspace = URL(fileURLWithPath: cwd)

        let session = try #require(store.sessions(forWorkspace: workspace).first)
        try archive.archive(session)

        #expect(store.sessions(forWorkspace: workspace).isEmpty)
        #expect(archive.sessions(forWorkspace: workspace).count == 1)
    }

    @Test("Restoring puts it back where the CLI looks")
    func restoreReturnsTheTranscript() throws {
        let (store, archive, cwd) = try makeStore()
        let workspace = URL(fileURLWithPath: cwd)

        let session = try #require(store.sessions(forWorkspace: workspace).first)
        try archive.archive(session)
        let archived = try #require(archive.sessions(forWorkspace: workspace).first)
        try archive.restore(archived, to: store)

        #expect(store.sessions(forWorkspace: workspace).count == 1)
        #expect(archive.sessions(forWorkspace: workspace).isEmpty)
    }

    @Test("An archived transcript keeps its content byte for byte")
    func archivePreservesContent() throws {
        let (store, archive, cwd) = try makeStore()
        let workspace = URL(fileURLWithPath: cwd)

        let session = try #require(store.sessions(forWorkspace: workspace).first)
        let before = try Data(contentsOf: session.fileURL)
        let moved = try archive.archive(session)

        #expect(try Data(contentsOf: moved) == before)
    }

    @Test("Deleting removes the transcript from disk")
    func deleteRemovesTheFile() throws {
        let (store, _, cwd) = try makeStore()
        let workspace = URL(fileURLWithPath: cwd)

        let session = try #require(store.sessions(forWorkspace: workspace).first)
        try SessionArchive().delete(session)

        #expect(!FileManager.default.fileExists(atPath: session.fileURL.path))
        #expect(store.sessions(forWorkspace: workspace).isEmpty)
    }
}
