import Foundation

/// Archives and deletes recorded conversations.
///
/// The CLI's transcript store has no notion of an archive, so archiving moves the file into a
/// sibling directory this app owns. Nothing is written back into the CLI's own tree beyond moving
/// the file out of it, and an archived transcript can be restored byte-for-byte.
///
/// Deletion is permanent: there is no trash step, because the CLI would re-list a file that came
/// back. Callers must confirm first.
public struct SessionArchive: Sendable {

    public let root: URL

    /// Archived transcripts live beside the CLI's store, not inside it, so the CLI stops listing
    /// them but nothing of ours ends up in a directory it manages.
    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".machline/archived-sessions", isDirectory: true)
    }

    private func directory(for session: HistoricalSession) -> URL {
        root.appendingPathComponent(
            SessionHistory.directoryName(for: URL(fileURLWithPath: session.cwd)),
            isDirectory: true)
    }

    /// Moves a transcript out of the CLI's store. Returns where it went.
    @discardableResult
    public func archive(_ session: HistoricalSession) throws -> URL {
        let destination = directory(for: session)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = destination.appendingPathComponent(session.fileURL.lastPathComponent)

        // A same-named archive already there means the session was archived, restored, and
        // archived again; the newer transcript wins.
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: session.fileURL, to: target)
        return target
    }

    /// Moves a transcript back so the CLI lists it again.
    @discardableResult
    public func restore(_ session: HistoricalSession, to store: SessionHistory) throws -> URL {
        let destination = store.root.appendingPathComponent(
            SessionHistory.directoryName(for: URL(fileURLWithPath: session.cwd)),
            isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = destination.appendingPathComponent(session.fileURL.lastPathComponent)
        try FileManager.default.moveItem(at: session.fileURL, to: target)
        return target
    }

    /// Permanently removes a transcript. Not recoverable.
    public func delete(_ session: HistoricalSession) throws {
        try FileManager.default.removeItem(at: session.fileURL)
    }

    /// Archived conversations for a workspace, most recently active first.
    public func sessions(forWorkspace workspace: URL) -> [HistoricalSession] {
        SessionHistory(root: root).sessions(forWorkspace: workspace)
    }
}
