import Foundation

extension String {
    /// Single-quoted for the shell, with embedded quotes broken out.
    ///
    /// Paths, volume names and ids all come from outside this process, so none of them is trusted
    /// to be free of quotes or spaces before it is pasted into a command line.
    public var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
