import Foundation
import Testing
@testable import HarnessCore

/// This editor is never the only writer — the agent edits the same tree from its own process — so a
/// file going stale on screen is the normal case, not the exceptional one.
@Suite("File watching")
struct FileWatcherTests {

    private func makeFile(_ text: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("file.txt")
        try text.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    /// Waits for one change, or gives up. Returns `false` on the timeout rather than hanging the
    /// suite, so a regression reads as a failure instead of a stall.
    private func awaitChange(
        _ url: URL, within seconds: Double = 3, while writing: @escaping @Sendable () -> Void
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in FileWatcher.changes(to: url) { return true }
                return false
            }
            group.addTask {
                // After the watch is armed, which happens on its own queue.
                try? await Task.sleep(for: .milliseconds(150))
                writing()
                try? await Task.sleep(for: .seconds(seconds))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    @Test("A write in place is reported")
    func reportsInPlaceWrite() async throws {
        let url = try makeFile("before")
        let changed = await awaitChange(url) {
            try? "after".write(to: url, atomically: false, encoding: .utf8)
        }
        #expect(changed)
    }

    /// The case a one-shot watch misses. Almost nothing writes in place — a temporary is renamed
    /// over the target — so the watched descriptor belongs to an inode that has lost its name.
    @Test("A replacement is reported, not just an in-place write")
    func reportsAtomicReplacement() async throws {
        let url = try makeFile("before")
        let changed = await awaitChange(url) {
            try? "after".write(to: url, atomically: true, encoding: .utf8)
        }
        #expect(changed)
    }

    @Test("A deletion is reported")
    func reportsDeletion() async throws {
        let url = try makeFile("before")
        let changed = await awaitChange(url) {
            try? FileManager.default.removeItem(at: url)
        }
        #expect(changed)
    }

    /// Re-arming is what makes the second edit visible; without it the watch sees one change and
    /// then goes quiet for the rest of the session.
    @Test("A second replacement is still reported")
    func keepsWatchingAfterAReplacement() async throws {
        let url = try makeFile("before")

        let seen = await withTaskGroup(of: Int.self) { group in
            group.addTask {
                var count = 0
                for await _ in FileWatcher.changes(to: url) {
                    count += 1
                    if count >= 2 { return count }
                }
                return count
            }
            group.addTask {
                for text in ["one", "two"] {
                    try? await Task.sleep(for: .milliseconds(250))
                    try? text.write(to: url, atomically: true, encoding: .utf8)
                }
                // Outlives the watcher's own return, so the first result out is the real one.
                try? await Task.sleep(for: .seconds(3))
                return 0
            }
            let first = await group.next() ?? 0
            group.cancelAll()
            return first
        }

        #expect(seen >= 2, "the watch stopped reporting after the first replacement")
    }
}
