import Foundation

/// The line terminator a file uses.
public enum LineEnding: Sendable, Hashable {
    case lf
    case crlf
    case cr
    /// More than one kind in the same file.
    case mixed

    /// What `text` terminates its lines with.
    ///
    /// Swift reads `\r\n` as one `Character`, so walking characters counts a Windows terminator
    /// once. Counting scalars is the classic way to misread a CRLF file as mixed.
    public static func detect(in text: String) -> LineEnding {
        var crlf = 0, lf = 0, cr = 0
        for character in text {
            switch character {
            case "\r\n": crlf += 1
            case "\n": lf += 1
            case "\r": cr += 1
            default: continue
            }
        }

        let kinds = [crlf, lf, cr].count { $0 > 0 }
        // No terminator at all — one line, or empty. A newline typed into it will be LF.
        if kinds == 0 { return .lf }
        if kinds > 1 { return .mixed }
        if crlf > 0 { return .crlf }
        if cr > 0 { return .cr }
        return .lf
    }

    /// One terminator, so a caret offset means one thing.
    ///
    /// A mixed file is left alone: normalising it would rewrite every untouched line, turning a
    /// one-line edit into a whole-file diff.
    public func normalising(_ text: String) -> String {
        switch self {
        case .crlf: return text.replacingOccurrences(of: "\r\n", with: "\n")
        case .cr: return text.replacingOccurrences(of: "\r", with: "\n")
        case .lf, .mixed: return text
        }
    }

    /// The inverse, applied on the way back to disk.
    public func restoring(_ text: String) -> String {
        switch self {
        case .crlf: return text.replacingOccurrences(of: "\n", with: "\r\n")
        case .cr: return text.replacingOccurrences(of: "\n", with: "\r")
        case .lf, .mixed: return text
        }
    }
}

public enum TextBufferError: Error, Equatable, Sendable {
    case missing
    case unreadable
    case notUTF8
    case tooLarge(bytes: Int, limit: Int)
    /// Someone else wrote the file since this buffer last agreed with it.
    case conflicted

    /// A sentence for the operator, since that is what every one of these becomes.
    public var message: String {
        switch self {
        case .missing: return "That file is not there."
        case .unreadable: return "That file could not be read."
        case .notUTF8: return "Not a text file."
        case .tooLarge(let bytes, let limit):
            return "That file is \(bytes / 1_048_576)MB — larger than the \(limit / 1_048_576)MB "
                + "this editor opens."
        case .conflicted: return "The file changed on disk since it was opened."
        }
    }
}

/// One file, open for editing.
///
/// The job of this type is that an unedited file saves back byte for byte. Normalising line
/// endings, adding a trailing newline, or dropping a byte-order mark turns "I fixed one line" into
/// a whole-file diff — which the agent is then asked to reason about. So everything that is not the
/// text is recorded on the way in and reapplied on the way out.
///
/// Saving is synchronous: a syscall on a few tens of kilobytes stays beneath a frame.
public struct TextBuffer: Sendable {

    public let url: URL
    public private(set) var lineEnding: LineEnding
    /// Stripped for editing, or it draws as a stray glyph on line one; put back on save.
    public private(set) var hasByteOrderMark: Bool
    /// The file's mode, reapplied after every write.
    public private(set) var permissions: Int?
    public private(set) var stamp: FileStamp

    /// The text as the editor holds it: normalised, no byte-order mark.
    public private(set) var contents: String
    /// What was last written, so dirtiness is a comparison rather than a flag that drifts.
    public private(set) var savedContents: String

    private let byteLimit: Int

    public var isDirty: Bool { contents != savedContents }

    /// A ceiling on holding the file in a `String`, not on drawing it — TextKit pages the layout.
    public static let defaultByteLimit = 16 * 1_048_576

    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    public static func load(_ url: URL, byteLimit: Int = defaultByteLimit) throws -> TextBuffer {
        // Stamped before the read. Either order races a concurrent write, but this one errs toward
        // reporting a change already adopted; the other hides a real one.
        guard let stamp = FileStamp.read(at: url) else { throw TextBufferError.missing }
        guard stamp.size <= byteLimit else {
            throw TextBufferError.tooLarge(bytes: stamp.size, limit: byteLimit)
        }
        guard let data = try? Data(contentsOf: url) else { throw TextBufferError.unreadable }

        let hasMark = data.starts(with: byteOrderMark)
        let body = hasMark ? data.dropFirst(byteOrderMark.count) : data.dropFirst(0)
        // A binary file as text is a screenful of replacement characters.
        guard let raw = String(data: body, encoding: .utf8) else { throw TextBufferError.notUTF8 }

        let ending = LineEnding.detect(in: raw)
        let normalised = ending.normalising(raw)

        return TextBuffer(
            url: url,
            lineEnding: ending,
            hasByteOrderMark: hasMark,
            permissions: mode(of: url),
            stamp: stamp,
            contents: normalised,
            savedContents: normalised,
            byteLimit: byteLimit)
    }

    private static func mode(of url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }

    /// The view owns the text while focused, so this is an assignment rather than a diff.
    public mutating func replaceContents(with text: String) {
        contents = text
    }

    /// Exactly what `save` would write, so the round-trip can be asserted without a filesystem.
    public func encoded() -> Data {
        var data = Data()
        if hasByteOrderMark { data.append(contentsOf: Self.byteOrderMark) }
        data.append(Data(lineEnding.restoring(contents).utf8))
        return data
    }

    /// Where the file stands relative to this buffer, right now.
    public func conflictDecision() -> EditConflict.Decision {
        EditConflict.decide(known: stamp, disk: FileStamp.read(at: url), isDirty: isDirty)
    }

    /// Writes the buffer back unless someone else got there first.
    ///
    /// `false` means nothing to do, so an autosave tick on a clean buffer costs nothing. `force` is
    /// the operator settling a conflict, never the timer.
    @discardableResult
    public mutating func save(force: Bool = false) throws -> Bool {
        let disk = FileStamp.read(at: url)
        switch EditConflict.verdict(known: stamp, disk: disk, isDirty: isDirty) {
        case .redundant:
            return false
        case .blocked where !force:
            throw TextBufferError.conflicted
        case .blocked, .proceed:
            break
        }

        try encoded().write(to: url, options: .atomic)

        // An atomic write replaces the file, so it lands with default permissions — autosaving a
        // shell script would quietly clear its executable bit.
        if let permissions {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: url.path)
        }

        savedContents = contents
        stamp = FileStamp.read(at: url) ?? stamp
        return true
    }

    /// Adopts what is on disk, discarding unsaved edits.
    ///
    /// Everything is re-read, not just the text: the agent may have changed the endings or the mode,
    /// and keeping the old ones reintroduces the whole-file diff this type exists to avoid.
    public mutating func reload() throws {
        let fresh = try TextBuffer.load(url, byteLimit: byteLimit)
        lineEnding = fresh.lineEnding
        hasByteOrderMark = fresh.hasByteOrderMark
        permissions = fresh.permissions
        stamp = fresh.stamp
        contents = fresh.contents
        savedContents = fresh.savedContents
    }
}
