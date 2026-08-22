import Foundation
import Testing
@testable import HarnessCore

/// `$SHELL` is the obvious source for "which shell does this operator use" and the wrong one: it
/// is inherited from whatever spawned the process, so it describes the parent rather than the
/// account. On the machine this was written on it reads `/bin/zsh` while the account's login shell
/// is fish — which is exactly the bug these pin.
struct LoginShellTests {

    @Test("The resolved shell is an executable that exists")
    func resolvesToSomethingRunnable() {
        let path = LoginShell.path()
        #expect(FileManager.default.isExecutableFile(atPath: path))
    }

    /// The account record is authoritative. If it disagrees with `$SHELL`, the record wins.
    @Test("The account record is preferred over the environment")
    func prefersTheAccountRecord() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
        process.arguments = [".", "-read", "/Users/\(NSUserName())", "UserShell"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        try #require(process.terminationStatus == 0)
        let recorded = String(decoding: data, as: UTF8.self)
            .split(separator: ":").last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(recorded != nil)

        // Only meaningful when the record names something runnable; otherwise the fallback is
        // correct and there is nothing to compare.
        if FileManager.default.isExecutableFile(atPath: recorded!) {
            #expect(LoginShell.path() == recorded!)
        }
    }

    @Test("The available list contains the login shell and only runnable entries")
    func availableIsUsable() {
        let shells = LoginShell.available()
        #expect(shells.contains(LoginShell.path()))
        #expect(!shells.isEmpty)
        for shell in shells {
            #expect(FileManager.default.isExecutableFile(atPath: shell), "\(shell)")
        }
    }

    /// A Homebrew fish is usually absent from `/etc/shells`, so it has to be added rather than
    /// filtered out by it.
    @Test("A login shell missing from /etc/shells is still offered")
    func loginShellIsAlwaysOffered() throws {
        let contents = try String(contentsOfFile: "/etc/shells", encoding: .utf8)
        let listed = contents
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        let login = LoginShell.path()
        if !listed.contains(login) {
            #expect(LoginShell.available().first == login)
        }
    }

    /// `-l` loads the profile that carries the operator's aliases and PATH.
    @Test("Shells are started as login shells")
    func startsAsLoginShell() {
        #expect(LoginShell.loginArguments(for: "/opt/homebrew/bin/fish") == ["-l"])
        #expect(LoginShell.loginArguments(for: "/bin/zsh") == ["-l"])
    }
}
