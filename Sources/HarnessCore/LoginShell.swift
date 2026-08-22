import Foundation

/// Which shell the operator actually uses.
///
/// `$SHELL` is the obvious answer and the wrong one: it is inherited from whatever spawned the
/// process, so it reports the shell of the parent rather than the operator's own. On this machine
/// it reads `/bin/zsh` while the account's login shell is fish. The user record is authoritative,
/// and `$SHELL` is only a fallback for when it cannot be read.
public enum LoginShell {

    /// Answers computed once per launch.
    ///
    /// `path()` shells out to `dscl`, and `waitUntilExit()` spins a runloop while it waits. Called
    /// from a SwiftUI view body — as the shell picker's option list did — that nested runloop
    /// drains a Core Animation commit, SwiftUI re-enters its own update, and AttributeGraph aborts
    /// the process. Answering from the cache after the first call keeps a stray call cheap; the
    /// real fix is that no view body should ask at all, which is why `prewarm()` exists.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedPath: String?
    nonisolated(unsafe) private static var cachedAvailable: [String]?

    /// Works the answers out ahead of the interface needing them. Call off the main actor.
    public static func prewarm() {
        _ = path()
        _ = available()
    }

    /// The account's login shell, preferring the directory record over the environment.
    public static func path() -> String {
        lock.lock()
        let cached = cachedPath
        lock.unlock()
        if let cached { return cached }

        let resolved = resolvePath()
        lock.lock()
        cachedPath = resolved
        lock.unlock()
        return resolved
    }

    private static func resolvePath() -> String {
        if let record = fromUserRecord(), FileManager.default.isExecutableFile(atPath: record) {
            return record
        }
        if let environment = ProcessInfo.processInfo.environment["SHELL"],
           FileManager.default.isExecutableFile(atPath: environment) {
            return environment
        }
        return "/bin/zsh"
    }

    /// Reads `UserShell` from the local directory service.
    private static func fromUserRecord() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
        process.arguments = [".", "-read", "/Users/\(NSUserName())", "UserShell"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        // `UserShell: /opt/homebrew/bin/fish`
        let text = String(decoding: data, as: UTF8.self)
        guard let value = text.split(separator: ":").last else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Shells the operator could pick, from `/etc/shells` plus the login shell itself.
    ///
    /// `/etc/shells` is the system's own list of legitimate login shells, so it needs no
    /// hard-coded set. The login shell is added because a Homebrew fish is often absent from it.
    public static func available() -> [String] {
        lock.lock()
        let cached = cachedAvailable
        lock.unlock()
        if let cached { return cached }

        let resolved = resolveAvailable()
        lock.lock()
        cachedAvailable = resolved
        lock.unlock()
        return resolved
    }

    private static func resolveAvailable() -> [String] {
        var shells: [String] = []
        if let contents = try? String(contentsOfFile: "/etc/shells", encoding: .utf8) {
            shells = contents
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        let login = path()
        if !shells.contains(login) { shells.insert(login, at: 0) }
        return shells.filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The arguments that start an interactive login shell.
    ///
    /// `-l` is understood by every shell in `/etc/shells` and by fish, and is what loads the
    /// operator's profile — the aliases and `PATH` they expect to have.
    public static func loginArguments(for shell: String) -> [String] { ["-l"] }
}
