import Foundation

/// Keeps a file dropped into the composer where the agent can actually read it.
///
/// A screenshot dragged out of Preview, or off the screenshot thumbnail, is handed over inside
/// `$TMPDIR/TemporaryItems/NSIRD_…/`. That directory is not merely outside the project: macOS
/// scopes it to the process that received the drag, so every other process — including the `claude`
/// child — gets `EPERM` on it, and no amount of `--add-dir` changes that. Machline holds the
/// extension, so Machline is the only thing that can copy the bytes out; this is where they go.
///
/// The copy also outlives the original. The system reaps its temporary directories, which is why a
/// transcript from yesterday shows a missing-image notice where the screenshot used to be.
public struct AttachmentStore: Sendable {

    public enum Failure: Error, Sendable {
        case copy(String)
    }

    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }

    /// Beside the rest of the harness's state, and readable by the agent because sessions are
    /// launched with it on `--add-dir`.
    public static var defaultDirectory: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("AgentHarness/attachments", isDirectory: true)
    }

    /// Whether a file has to be copied before the agent can be pointed at it.
    ///
    /// The per-user temporary tree covers both cases worth catching: the sandbox-scoped drop
    /// directories, which cannot be read at all, and the ordinary temporary files, which can be
    /// read right up until the system removes them.
    public static func isUnreachableByAgent(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        return path.hasPrefix(temporary + "/") || path.hasPrefix("/private/var/folders/")
    }

    /// Copies a file in and returns where it landed.
    ///
    /// Each copy gets its own directory so two screenshots taken in the same second cannot collide,
    /// and the name is kept — it is what the operator will recognise in the transcript — with its
    /// whitespace folded out, because the path is about to be written into a prompt as an
    /// `@mention` and a space there ends the mention early.
    public func adopt(_ url: URL) throws -> URL {
        let manager = FileManager.default
        let slot = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try manager.createDirectory(
                at: slot, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw Failure.copy(String(describing: error))
        }

        let destination = slot.appendingPathComponent(Self.mentionable(url.lastPathComponent))
        do {
            try manager.copyItem(at: url, to: destination)
        } catch {
            try? manager.removeItem(at: slot)
            throw Failure.copy(String(describing: error))
        }
        return destination
    }

    /// `Screenshot 2026-08-22 at 9.45.42 PM.png` → `Screenshot-2026-08-22-at-9.45.42-PM.png`.
    static func mentionable(_ name: String) -> String {
        let folded = name.split(whereSeparator: \.isWhitespace).joined(separator: "-")
        return folded.isEmpty ? "attachment" : folded
    }

    /// Drops copies older than `age`. Best-effort, and called when a new one is taken in: an
    /// attachment store that only ever grows is a disk leak with a friendly name.
    public func prune(olderThan age: TimeInterval = 30 * 24 * 60 * 60, now: Date = Date()) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }

        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > age else { continue }
            try? manager.removeItem(at: entry)
        }
    }
}
