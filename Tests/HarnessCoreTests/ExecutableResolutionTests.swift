import Foundation
import Testing
@testable import HarnessCore

/// A GUI process launched from Finder inherits `launchd`'s minimal `PATH`, so an agent installed by
/// Homebrew or npm is invisible to an inherited-`PATH` search that works fine in a terminal. These
/// tests pin the two behaviours that keep that from presenting as a hang.
struct ExecutableResolutionTests {

    @Test("An absolute path is taken as given")
    func absolutePathPassesThrough() throws {
        let resolved = try SessionSupervisor.resolve(executable: "/usr/bin/true")
        #expect(resolved.path == "/usr/bin/true")
    }

    @Test("A bare name on PATH resolves to an executable file")
    func bareNameResolvesThroughPath() throws {
        let resolved = try SessionSupervisor.resolve(executable: "env")
        #expect(FileManager.default.isExecutableFile(atPath: resolved.path))
        #expect(resolved.lastPathComponent == "env")
    }

    /// The failure mode this replaces silently substituted `/usr/bin/env`, which then received the
    /// agent's flags as its own and exited — an empty session that looked like a stall.
    @Test("A missing binary throws instead of substituting something else")
    func missingBinaryThrows() {
        #expect(throws: SupervisorError.self) {
            try SessionSupervisor.resolve(executable: "machline-no-such-binary-xyzzy")
        }
    }

    @Test("The not-found error names the binary it looked for")
    func notFoundErrorNamesTheBinary() {
        let error = SupervisorError.executableNotFound("claude")
        #expect(String(describing: error).contains("claude"))
    }
}
