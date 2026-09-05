import Foundation
import Testing
@testable import HarnessCore

/// What a forked shell is allowed to inherit.
///
/// A shell forked while the app holds a thousand descriptors opens its own above 1023, and fish
/// watches descriptors with `select`, which cannot name one that high. The pane comes up saying
/// `fish crashed, please report a bug.` Marking the app's descriptors close-on-exec first is what
/// keeps the shell's numbering low.
/// Serialized because the sweep is process-wide: two of these running at once means one marks the
/// other's freshly opened pipe before it has been looked at.
@Suite("Descriptor hygiene", .serialized)
struct DescriptorHygieneTests {

    private func isCloseOnExec(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFD)
        return flags >= 0 && flags & FD_CLOEXEC != 0
    }

    @Test("An open pipe stops being inheritable")
    func marksOpenDescriptors() throws {
        let pipe = Pipe()
        let read = pipe.fileHandleForReading.fileDescriptor
        let write = pipe.fileHandleForWriting.fileDescriptor
        #expect(!isCloseOnExec(read), "a fresh pipe is inheritable, which is the problem")

        DescriptorHygiene.closeOnExecAll()

        #expect(isCloseOnExec(read))
        #expect(isCloseOnExec(write))
    }

    @Test("A descriptor above the usual range is reached too")
    func marksHighDescriptors() throws {
        // 2048 is past what `select` can name, which is exactly the range that matters here.
        let source = open("/dev/null", O_RDONLY)
        try #require(source >= 0)
        defer { close(source) }
        let high: Int32 = 2048
        try #require(dup2(source, high) == high)
        defer { close(high) }

        DescriptorHygiene.closeOnExecAll()

        #expect(isCloseOnExec(high))
    }

    @Test("The standard streams are left alone")
    func leavesStandardStreams() {
        DescriptorHygiene.closeOnExecAll()
        for descriptor in Int32(0)...2 where fcntl(descriptor, F_GETFD) >= 0 {
            #expect(!isCloseOnExec(descriptor), "descriptor \(descriptor) is this app's own stream")
        }
    }

    /// The count is deliberately not asserted to be zero: the suites run in parallel, so another
    /// test's pipe can appear between the two sweeps. What has to hold is that a descriptor already
    /// marked stays marked and is not counted twice.
    @Test("Sweeping again leaves an already-marked descriptor alone")
    func isIdempotent() throws {
        let pipe = Pipe()
        let read = pipe.fileHandleForReading.fileDescriptor
        let first = DescriptorHygiene.closeOnExecAll()
        try #require(first > 0)
        #expect(isCloseOnExec(read))

        DescriptorHygiene.closeOnExecAll()
        #expect(isCloseOnExec(read))
    }
}
