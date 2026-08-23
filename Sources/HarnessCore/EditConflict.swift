import Foundation

/// What a file looked like when a buffer last agreed with it.
///
/// Two fields: a write inside one timestamp is invisible to `modified` alone, and a same-length
/// write is invisible to `size` alone.
public struct FileStamp: Sendable, Hashable {
    public let modified: Date
    public let size: Int

    public init(modified: Date, size: Int) {
        self.modified = modified
        self.size = size
    }

    /// The stamp of whatever is at `url`, or `nil` when there is nothing there.
    public static func read(at url: URL) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? Int
        else { return nil }
        return FileStamp(modified: modified, size: size)
    }
}

/// Who wrote last, and what that means for a buffer holding the same file.
///
/// Other editors can assume they are the only writer; this one cannot — the agent edits the same
/// tree, unprompted, and saves here are automatic. Decided on stamps alone, so it stays testable.
public enum EditConflict {

    /// What to do about a file that may have moved under the buffer holding it.
    public enum Decision: Sendable, Hashable {
        /// Disk still matches what the buffer last agreed with.
        case unchanged
        /// Someone else wrote, and there is nothing local to lose.
        case reload
        /// Someone else wrote and there are unsaved edits. Only the operator can settle it.
        case conflict
        /// The file is gone.
        case vanished
    }

    public static func decide(known: FileStamp, disk: FileStamp?, isDirty: Bool) -> Decision {
        guard let disk else { return .vanished }
        if disk == known { return .unchanged }
        return isDirty ? .conflict : .reload
    }

    /// Whether a save may go ahead on its own.
    public enum SaveVerdict: Sendable, Hashable {
        case proceed
        /// Already matches disk. Writing would restamp the file and report churn that never was.
        case redundant
        /// Someone else wrote first; an automatic save would overwrite it.
        case blocked
    }

    public static func verdict(known: FileStamp, disk: FileStamp?, isDirty: Bool) -> SaveVerdict {
        guard isDirty else { return .redundant }
        // A file the agent deleted is not a file to recreate without being asked.
        guard let disk else { return .blocked }
        return disk == known ? .proceed : .blocked
    }
}
