import Foundation

/// Tells you when a file changed underneath you.
///
/// Needed because this editor is never the only writer: the agent edits the same working tree from
/// a process nobody here controls. Without this, a file the agent rewrote sits stale on screen until
/// something happens to ask.
///
/// Re-arms itself after every replacement. Almost nothing writes a file in place — editors here and
/// elsewhere write a temporary and rename over the target — so the descriptor being watched belongs
/// to an inode that no longer has the name. Watching once means seeing exactly one change and then
/// going quiet forever.
public enum FileWatcher {

    /// A value per change. Coalescing is the caller's business: several arrive for one save.
    public static func changes(to url: URL) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let watch = Watch(url: url, continuation: continuation)
            watch.arm()
            continuation.onTermination = { _ in watch.cancel() }
        }
    }
}

/// Mutable state confined to one queue, which is what `@unchecked` is standing on.
private final class Watch: @unchecked Sendable {

    private let url: URL
    private let continuation: AsyncStream<Void>.Continuation
    private let queue = DispatchQueue(label: "machline.file-watcher")

    private var source: DispatchSourceFileSystemObject?
    private var isCancelled = false
    private var reopenAttempts = 0

    /// How long to keep looking for a file that is not there. A rename-over lands within a tick;
    /// beyond this the file was deleted and there is nothing to watch.
    private static let reopenLimit = 25
    private static let reopenDelay = DispatchTimeInterval.milliseconds(200)

    init(url: URL, continuation: AsyncStream<Void>.Continuation) {
        self.url = url
        self.continuation = continuation
    }

    func arm() {
        queue.async { [self] in
            guard !isCancelled else { return }
            source?.cancel()
            source = nil

            // `O_EVTONLY` asks for notification rights and nothing else, so this does not count as
            // an open file for the purposes of unmounting the volume it lives on.
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else {
                continuation.yield(())
                guard reopenAttempts < Self.reopenLimit else { return }
                reopenAttempts += 1
                queue.asyncAfter(deadline: .now() + Self.reopenDelay) { [self] in arm() }
                return
            }
            reopenAttempts = 0

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .delete, .rename, .attrib],
                queue: queue)

            source.setEventHandler { [self] in
                let events = source.data
                continuation.yield(())
                // The name now points at a different inode than the one being watched.
                if events.contains(.delete) || events.contains(.rename) { arm() }
            }
            source.setCancelHandler { close(descriptor) }

            self.source = source
            source.resume()
        }
    }

    func cancel() {
        queue.async { [self] in
            isCancelled = true
            source?.cancel()
            source = nil
        }
    }
}
