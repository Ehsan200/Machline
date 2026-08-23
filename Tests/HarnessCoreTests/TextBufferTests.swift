import Foundation
import Testing
@testable import HarnessCore

/// The property every one of these is really testing: a file the operator did not edit saves back
/// byte for byte. An editor that tidies line endings, appends a trailing newline, or drops a
/// byte-order mark turns a one-line fix into a whole-file diff in the Git panel — and that diff is
/// what the agent gets asked about next.
struct TextBufferTests {

    private func makeFile(_ bytes: [UInt8], name: String = "sample.txt") throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("buffer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func makeFile(_ text: String, name: String = "sample.txt") throws -> URL {
        try makeFile(Array(text.utf8), name: name)
    }

    // MARK: - Round trips

    @Test("A file nobody edited saves back byte for byte")
    func roundTripsUntouched() throws {
        for source in ["one\ntwo\n", "one\r\ntwo\r\n", "one\rtwo\r", "one\ntwo", "", "solo"] {
            let url = try makeFile(source)
            let buffer = try TextBuffer.load(url)
            #expect(buffer.encoded() == Data(source.utf8), "round trip failed for \(source.debugDescription)")
        }
    }

    @Test("Windows line endings are hidden while editing and restored on the way out")
    func crlfIsNormalisedAndRestored() throws {
        let url = try makeFile("one\r\ntwo\r\n")
        var buffer = try TextBuffer.load(url)

        #expect(buffer.lineEnding == .crlf)
        // The caret has one kind of newline to count, whatever the file uses.
        #expect(buffer.contents == "one\ntwo\n")

        buffer.replaceContents(with: "one\ntwo\nthree\n")
        #expect(buffer.encoded() == Data("one\r\ntwo\r\nthree\r\n".utf8))
    }

    @Test("Classic Mac endings survive the same way")
    func crIsNormalisedAndRestored() throws {
        let url = try makeFile("one\rtwo\r")
        let buffer = try TextBuffer.load(url)
        #expect(buffer.lineEnding == .cr)
        #expect(buffer.contents == "one\ntwo\n")
        #expect(buffer.encoded() == Data("one\rtwo\r".utf8))
    }

    /// Normalising a mixed file would rewrite every line the operator never touched, so it is left
    /// exactly as found.
    @Test("A file with mixed endings is left alone")
    func mixedEndingsAreLeftRaw() throws {
        let source = "one\r\ntwo\nthree\r\n"
        let url = try makeFile(source)
        var buffer = try TextBuffer.load(url)

        #expect(buffer.lineEnding == .mixed)
        #expect(buffer.contents == source)

        buffer.replaceContents(with: source + "four\n")
        #expect(buffer.encoded() == Data((source + "four\n").utf8))
    }

    @Test("A missing trailing newline stays missing")
    func doesNotAddATrailingNewline() throws {
        let url = try makeFile("one\ntwo")
        var buffer = try TextBuffer.load(url)
        buffer.replaceContents(with: "one\nthree")
        #expect(buffer.encoded() == Data("one\nthree".utf8))
    }

    @Test("A byte-order mark is kept out of the text and put back on save")
    func preservesByteOrderMark() throws {
        let url = try makeFile([0xEF, 0xBB, 0xBF] + Array("hello\n".utf8))
        var buffer = try TextBuffer.load(url)

        #expect(buffer.hasByteOrderMark)
        // Otherwise it draws as a stray glyph before the first character.
        #expect(buffer.contents == "hello\n")

        buffer.replaceContents(with: "goodbye\n")
        #expect(buffer.encoded() == Data([0xEF, 0xBB, 0xBF] + Array("goodbye\n".utf8)))
    }

    /// Swift reads `\r\n` as one `Character`. Counting scalars instead is the usual way a plain
    /// CRLF file gets misread as mixed and then rewritten wholesale.
    @Test("CRLF counts as one terminator, not a CR beside an LF")
    func crlfIsOneGrapheme() {
        #expect(LineEnding.detect(in: "a\r\nb\r\n") == .crlf)
        #expect(LineEnding.detect(in: "a\nb\n") == .lf)
        #expect(LineEnding.detect(in: "a\rb\r") == .cr)
        #expect(LineEnding.detect(in: "a\r\nb\n") == .mixed)
        // Nothing to preserve: a newline typed into this will be LF.
        #expect(LineEnding.detect(in: "one line") == .lf)
    }

    // MARK: - Refusals

    @Test("A file that is not there, not text, or not small enough is refused")
    func refusesWhatItCannotHold() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("absent-\(UUID().uuidString).txt")
        #expect(throws: TextBufferError.missing) { try TextBuffer.load(missing) }

        let binary = try makeFile([0xFF, 0xFE, 0x00, 0x01])
        #expect(throws: TextBufferError.notUTF8) { try TextBuffer.load(binary) }

        let big = try makeFile("well past the limit")
        #expect(throws: TextBufferError.tooLarge(bytes: 19, limit: 4)) {
            try TextBuffer.load(big, byteLimit: 4)
        }
    }

    // MARK: - Saving

    @Test("Dirtiness is the text differing from what was written, not a flag")
    func dirtinessIsAComparison() throws {
        let url = try makeFile("one\n")
        var buffer = try TextBuffer.load(url)
        #expect(!buffer.isDirty)

        buffer.replaceContents(with: "two\n")
        #expect(buffer.isDirty)

        // Typed back to what it was: no longer a change, so autosave has nothing to write.
        buffer.replaceContents(with: "one\n")
        #expect(!buffer.isDirty)
    }

    @Test("Saving writes the file and clears the dirty state")
    func saveWrites() throws {
        let url = try makeFile("one\n")
        var buffer = try TextBuffer.load(url)
        buffer.replaceContents(with: "two\n")

        #expect(try buffer.save())
        #expect(!buffer.isDirty)
        #expect(try String(contentsOf: url, encoding: .utf8) == "two\n")
    }

    /// An autosave timer fires far more often than the text changes. A write on every tick would
    /// restamp the file and make the change tracking elsewhere report churn that never happened.
    @Test("Saving an unchanged buffer does nothing")
    func saveIsFreeWhenClean() throws {
        let url = try makeFile("one\n")
        var buffer = try TextBuffer.load(url)
        let before = buffer.stamp

        #expect(try buffer.save() == false)
        #expect(buffer.stamp == before)
    }

    /// An atomic write replaces the file rather than rewriting it, so the replacement carries
    /// default permissions unless they are put back — and a script autosaved once would stop being
    /// runnable for no visible reason.
    @Test("Saving keeps the executable bit")
    func savePreservesMode() throws {
        let url = try makeFile("#!/bin/sh\necho hi\n", name: "run.sh")
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: url.path)

        var buffer = try TextBuffer.load(url)
        buffer.replaceContents(with: "#!/bin/sh\necho bye\n")
        try buffer.save()

        let mode = try #require(
            (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?
                .intValue)
        #expect(mode == 0o755)
    }

    // MARK: - The other writer

    @Test("A save is refused when the agent got there first")
    func saveBlocksOnAConcurrentWrite() throws {
        let url = try makeFile("one\n")
        var buffer = try TextBuffer.load(url)
        buffer.replaceContents(with: "mine\n")

        // The agent, from its own process, between the operator's keystrokes.
        try Data("theirs, and longer\n".utf8).write(to: url)

        #expect(throws: TextBufferError.conflicted) { try buffer.save() }
        #expect(try String(contentsOf: url, encoding: .utf8) == "theirs, and longer\n")

        // Only an explicit decision overrides it.
        #expect(try buffer.save(force: true))
        #expect(try String(contentsOf: url, encoding: .utf8) == "mine\n")
    }

    @Test("Reloading adopts what is on disk, endings and mode included")
    func reloadAdoptsEverything() throws {
        let url = try makeFile("one\n")
        var buffer = try TextBuffer.load(url)
        buffer.replaceContents(with: "unsaved\n")

        try Data("rewritten\r\nby the agent\r\n".utf8).write(to: url)
        try buffer.reload()

        #expect(!buffer.isDirty)
        #expect(buffer.lineEnding == .crlf)
        #expect(buffer.contents == "rewritten\nby the agent\n")
        // Keeping the old endings would reintroduce exactly the whole-file diff this avoids.
        #expect(buffer.encoded() == Data("rewritten\r\nby the agent\r\n".utf8))
    }

    @Test("The live state of a file is reported without saving it")
    func reportsWhereTheFileStands() throws {
        let url = try makeFile("one\n")
        var buffer = try TextBuffer.load(url)
        #expect(buffer.conflictDecision() == .unchanged)

        try Data("elsewhere\n".utf8).write(to: url)
        #expect(buffer.conflictDecision() == .reload)

        buffer.replaceContents(with: "mine\n")
        #expect(buffer.conflictDecision() == .conflict)

        try FileManager.default.removeItem(at: url)
        #expect(buffer.conflictDecision() == .vanished)
    }
}

/// The decision that keeps autosave from overwriting the agent, made on stamps alone so every
/// combination can be stated rather than staged on a filesystem.
struct EditConflictTests {

    private let known = FileStamp(modified: Date(timeIntervalSince1970: 1_000), size: 10)
    private var moved: FileStamp { FileStamp(modified: Date(timeIntervalSince1970: 2_000), size: 10) }
    private var resized: FileStamp { FileStamp(modified: Date(timeIntervalSince1970: 1_000), size: 11) }

    @Test("Nothing to do when disk still matches")
    func unchanged() {
        #expect(EditConflict.decide(known: known, disk: known, isDirty: false) == .unchanged)
        #expect(EditConflict.decide(known: known, disk: known, isDirty: true) == .unchanged)
    }

    @Test("A clean buffer follows disk; a dirty one asks")
    func followsOrAsks() {
        #expect(EditConflict.decide(known: known, disk: moved, isDirty: false) == .reload)
        #expect(EditConflict.decide(known: known, disk: moved, isDirty: true) == .conflict)
    }

    /// Same timestamp, different length: a write inside one timestamp's resolution is exactly what
    /// a single-field check misses.
    @Test("A change of size counts even when the timestamp did not move")
    func sizeAloneIsEnough() {
        #expect(EditConflict.decide(known: known, disk: resized, isDirty: false) == .reload)
    }

    @Test("A deleted file is its own answer")
    func vanished() {
        #expect(EditConflict.decide(known: known, disk: nil, isDirty: false) == .vanished)
        #expect(EditConflict.decide(known: known, disk: nil, isDirty: true) == .vanished)
    }

    @Test("Autosave proceeds only on a dirty buffer over an untouched file")
    func saveVerdicts() {
        #expect(EditConflict.verdict(known: known, disk: known, isDirty: true) == .proceed)
        #expect(EditConflict.verdict(known: known, disk: known, isDirty: false) == .redundant)
        #expect(EditConflict.verdict(known: known, disk: moved, isDirty: true) == .blocked)
        // Nothing to write beats everything else: a clean buffer is never a conflict.
        #expect(EditConflict.verdict(known: known, disk: moved, isDirty: false) == .redundant)
        // A file the agent deleted is not one to recreate unasked.
        #expect(EditConflict.verdict(known: known, disk: nil, isDirty: true) == .blocked)
    }
}
