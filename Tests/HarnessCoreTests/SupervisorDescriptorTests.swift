import Foundation
import Testing
@testable import HarnessCore

/// What a finished session goes on holding.
///
/// A Finder-launched app starts with `launchd`'s 256-descriptor soft limit, and a supervisor keeps
/// three pipes for as long as its tab is open. Running out does not report itself as such: `Pipe()`
/// cannot fail loudly, so the next spawn anywhere in the app dies with `EBADF` instead.
@Suite("Session descriptors")
struct SupervisorDescriptorTests {

    /// Identifies what a descriptor currently points at, so a number handed straight back out to
    /// another thread is not mistaken for one that was never closed.
    private func stamp(_ descriptor: Int32) -> (device: Int32, inode: UInt64)? {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        return (info.st_dev, info.st_ino)
    }

    private func isReleased(_ descriptor: Int32, was: (device: Int32, inode: UInt64)) -> Bool {
        guard let now = stamp(descriptor) else { return true }
        return now != was
    }

    /// Waits for a descriptor to be let go.
    ///
    /// `readabilityHandler` is backed by a `DispatchSource`, and clearing it cancels that source
    /// asynchronously — so the descriptor can outlive the `close()` call by a moment. What matters
    /// is that it comes back, not that it comes back inside the same tick; a synchronous assertion
    /// here passed alone and failed under the parallel runner.
    private func waitForRelease(
        _ descriptor: Int32, was: (device: Int32, inode: UInt64)
    ) async -> Bool {
        for _ in 0..<200 {
            if isReleased(descriptor, was: was) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    @Test("A finished session gives its pipes back")
    func releasesPipesOnExit() async throws {
        // `/bin/echo` ignores the arguments a session is given and exits immediately, which is all
        // this needs: a real child, a real set of pipes, and an end to the frame stream.
        let configuration = SessionConfiguration(
            executable: "/bin/echo",
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        let supervisor = SessionSupervisor(configuration: configuration)

        let events = try await supervisor.start()
        let held = await supervisor.heldDescriptors
        let stamps = held.map { stamp($0) }
        for stamp in stamps { #expect(stamp != nil, "a running session must hold its pipes open") }

        for await _ in events {}

        await supervisor.releaseDescriptors()
        for (descriptor, was) in zip(held, stamps) {
            let released = await waitForRelease(descriptor, was: try #require(was))
            #expect(released, "descriptor \(descriptor) was never given back")
        }
    }

    @Test("Releasing twice is harmless")
    func releaseIsIdempotent() async throws {
        let configuration = SessionConfiguration(
            executable: "/bin/echo",
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        let supervisor = SessionSupervisor(configuration: configuration)
        let events = try await supervisor.start()
        for await _ in events {}

        await supervisor.releaseDescriptors()
        await supervisor.releaseDescriptors()
    }
}
