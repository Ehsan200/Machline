import Foundation
import Testing
@testable import HarnessCore

/// Every session needs a working directory, which makes "just ask it something" awkward: opening a
/// real project files the answer in that project's history and points a tool-using agent at code
/// it has no business touching.
struct ScratchWorkspaceTests {

    private func makeScratch() -> ScratchWorkspace {
        ScratchWorkspace(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scratch-\(UUID().uuidString)"))
    }

    @Test("Preparing creates the directory and a note explaining it")
    func prepareCreatesEverything() throws {
        let scratch = makeScratch()
        #expect(!scratch.exists)

        let url = try scratch.prepare()
        #expect(scratch.exists)
        #expect(url == scratch.url)

        let note = url.appendingPathComponent("README.md")
        let contents = try String(contentsOf: note, encoding: .utf8)
        #expect(contents.contains("Scratch"))
    }

    @Test("Preparing twice is harmless")
    func prepareIsIdempotent() throws {
        let scratch = makeScratch()
        try scratch.prepare()
        try "work in progress".write(
            to: scratch.url.appendingPathComponent("draft.txt"),
            atomically: true, encoding: .utf8)

        try scratch.prepare()
        #expect(FileManager.default.fileExists(
            atPath: scratch.url.appendingPathComponent("draft.txt").path))
    }

    /// Emptying clears working files but keeps the directory, because the conversations live in
    /// the CLI's own store rather than here.
    @Test("Emptying clears the contents and keeps the directory")
    func emptyingKeepsTheDirectory() throws {
        let scratch = makeScratch()
        try scratch.prepare()
        try "junk".write(
            to: scratch.url.appendingPathComponent("junk.txt"),
            atomically: true, encoding: .utf8)

        try scratch.empty()

        #expect(scratch.exists)
        #expect(!FileManager.default.fileExists(
            atPath: scratch.url.appendingPathComponent("junk.txt").path))
        // The note is restored, so the directory never becomes unexplained.
        #expect(FileManager.default.fileExists(
            atPath: scratch.url.appendingPathComponent("README.md").path))
    }

    @Test("Emptying a scratch that was never created is not an error")
    func emptyingNothing() throws {
        try makeScratch().empty()
    }

    /// It must be its own project in the transcript store, not shared with anything else.
    @Test("Scratch maps to its own project directory")
    func hasItsOwnProjectDirectory() throws {
        let scratch = makeScratch()
        try scratch.prepare()
        #expect(
            SessionHistory.directoryName(for: scratch.url)
                != SessionHistory.directoryName(for: URL(fileURLWithPath: "/Users/x/Projects/app")))
    }
}
