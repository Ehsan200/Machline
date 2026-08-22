import Foundation
import Testing
@testable import HarnessCore

/// Drafting a commit message is a one-shot question, not a conversation to return to. The CLI
/// records every run as a session, so a naive run inside the repository files a transcript under
/// that project and it appears in the session list — clutter the operator never asked for.
struct CommitDraftIsolationTests {

    @Test("The scratch directory is real, empty, and not the repository")
    func scratchDirectoryIsUsable() throws {
        let scratch = try CommitDraftGenerator.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: scratch.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }

    /// The scratch directory now comes back symlink-resolved. `$TMPDIR` sits under `/var`, which
    /// links to `/private/var`, and the CLI files a transcript under the resolved path — so an
    /// unresolved one left every draft behind as a project the operator never opened.
    @Test("The scratch directory is where the CLI will actually file the run")
    func scratchDirectoryIsResolved() throws {
        let scratch = try CommitDraftGenerator.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        #expect(scratch.path == scratch.resolvingSymlinksInPath().path)
    }

    /// The generator runs the binary it resolved, not `/usr/bin/env claude`. Launched from Finder
    /// the app inherits `launchd`'s `PATH`, where a Homebrew or npm `claude` does not exist — the
    /// spawn then failed silently and Suggest span and stopped with nothing to show for it.
    @Test("The agent binary is resolved rather than left to the inherited PATH")
    func executableIsResolved() throws {
        let resolved = try SessionSupervisor.resolve(executable: "sh")
        #expect(resolved.path.hasSuffix("/sh"))
        #expect(FileManager.default.isExecutableFile(atPath: resolved.path))
        #expect(!SessionSupervisor.inheritedEnvironment().isEmpty)
    }

    @Test("Each run gets its own scratch directory")
    func scratchDirectoriesAreUnique() throws {
        let first = try CommitDraftGenerator.makeScratchDirectory()
        let second = try CommitDraftGenerator.makeScratchDirectory()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        #expect(first != second)
    }

    /// The point of the whole arrangement: after a draft, nothing is left in the transcript store.
    @Test("The transcript and the scratch directory are both removed")
    func discardRemovesEverything() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("draft-store-\(UUID().uuidString)")
        let store = SessionHistory(root: root)
        let scratch = try CommitDraftGenerator.makeScratchDirectory()
        let sessionID = UUID()

        // Stand in for what the CLI would have written.
        let projectDirectory = root.appendingPathComponent(
            SessionHistory.directoryName(for: scratch), isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectDirectory, withIntermediateDirectories: true)
        let transcript = projectDirectory
            .appendingPathComponent("\(sessionID.uuidString.lowercased()).jsonl")
        try #"{"type":"user"}"#.write(to: transcript, atomically: true, encoding: .utf8)

        CommitDraftGenerator.discardTranscript(
            sessionID: sessionID, scratch: scratch, store: store)

        #expect(!FileManager.default.fileExists(atPath: transcript.path))
        #expect(!FileManager.default.fileExists(atPath: projectDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
    }

    /// A draft that succeeded must not fail because a temporary file could not be deleted.
    @Test("Discarding what is already gone is not an error")
    func discardIsBestEffort() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("draft-store-\(UUID().uuidString)")
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("never-created-\(UUID().uuidString)")

        CommitDraftGenerator.discardTranscript(
            sessionID: UUID(), scratch: scratch, store: SessionHistory(root: root))
    }

    /// A drafting run must never be filed under the repository being committed to.
    @Test("The scratch directory maps to its own project directory, not the repository")
    func scratchIsNotTheRepository() throws {
        let repository = URL(fileURLWithPath: "/Users/someone/Projects/app")
        let scratch = try CommitDraftGenerator.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        #expect(
            SessionHistory.directoryName(for: scratch)
                != SessionHistory.directoryName(for: repository))
    }
}
