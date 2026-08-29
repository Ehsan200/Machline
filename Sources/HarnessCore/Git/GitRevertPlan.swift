import Foundation

/// What undoing a set of files means, worked out from status before any of it runs.
///
/// "Undo this file" is three operations wearing one name. A tracked file goes back to what HEAD
/// holds. A file HEAD has never seen cannot be restored from anywhere, so undoing it means the file
/// stops existing — and if it was staged it has to leave the index first, because `git restore`
/// resolves nothing in a repository with no commits. A rename is only undone by naming *both* of its
/// paths: restoring the new name alone leaves the old one deleted in the index.
///
/// Split from the running of it so the classification is testable without a repository, and so the
/// destructive half is a list the caller can name in a confirmation rather than discover afterwards.
public struct GitRevertPlan: Sendable, Equatable {
    /// Restored from HEAD, in the index and the working tree both.
    public let restored: [String]
    /// Dropped from the index, the file left on disk. Files staged as new, which HEAD cannot supply.
    public let forgotten: [String]
    /// Removed from disk, because nothing committed exists to put back.
    public let removed: [String]

    public var isEmpty: Bool { restored.isEmpty && forgotten.isEmpty && removed.isEmpty }

    /// True when undoing costs a file rather than an edit — the difference a confirmation has to say
    /// out loud.
    public var deletesFiles: Bool { !removed.isEmpty }

    /// - Parameters:
    ///   - paths: Repository-relative paths, as Git reports them.
    ///   - status: The last read status. A path it does not mention is left out entirely: either it
    ///     has no changes to undo, or it belongs to some other repository, and `git restore` on the
    ///     second one fails the whole call. With no status at all, every path is taken at its word.
    public init(paths: [String], status: GitStatus?) {
        var restored: Set<String> = []
        var forgotten: Set<String> = []
        var removed: Set<String> = []

        if let status {
            let byPath = Dictionary(
                status.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            for path in paths {
                guard let file = byPath[path] else { continue }
                if file.isUntracked {
                    removed.insert(path)
                } else if file.indexChange == .added {
                    forgotten.insert(path)
                    removed.insert(path)
                } else {
                    restored.insert(path)
                    // The source half of a rename or copy, which HEAD still has and the index has
                    // marked as gone.
                    if let original = file.originalPath { restored.insert(original) }
                }
            }
        } else {
            restored.formUnion(paths)
        }

        self.restored = restored.sorted()
        self.forgotten = forgotten.sorted()
        self.removed = removed.sorted()
    }
}
