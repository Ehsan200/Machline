import Foundation

/// Reassembles newline-delimited frames from arbitrarily chunked pipe reads.
///
/// A `Pipe` read boundary lands wherever the OS puts it, routinely mid-line and mid-UTF-8-sequence.
/// Buffering as `Data` and only decoding once a `\n` is seen keeps multi-byte characters intact.
public struct LineAssembler: Sendable {
    private var buffer = Data()

    /// Frames larger than this are treated as a runaway stream rather than a real line.
    public let maximumLineLength: Int

    public init(maximumLineLength: Int = 64 * 1024 * 1024) {
        self.maximumLineLength = maximumLineLength
    }

    public enum Overflow: Error, Sendable {
        case lineTooLong(bytes: Int)
    }

    /// Appends a chunk and returns whatever complete lines it completed. Blank lines are dropped.
    public mutating func append(_ chunk: Data) throws -> [String] {
        buffer.append(chunk)
        var lines: [String] = []

        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !lineData.isEmpty else { continue }
            // Tolerate CRLF even though the CLI emits bare LF.
            let trimmed = lineData.last == UInt8(ascii: "\r") ? lineData.dropLast() : lineData
            guard !trimmed.isEmpty else { continue }
            lines.append(String(decoding: trimmed, as: UTF8.self))
        }

        if buffer.count > maximumLineLength {
            let count = buffer.count
            buffer.removeAll(keepingCapacity: false)
            throw Overflow.lineTooLong(bytes: count)
        }
        return lines
    }

    /// Returns any trailing content left unterminated at EOF.
    public mutating func flush() -> String? {
        defer { buffer.removeAll(keepingCapacity: false) }
        guard !buffer.isEmpty else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }
}
