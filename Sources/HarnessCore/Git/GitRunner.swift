import Foundation

/// Runs `git` as a subprocess.
///
/// Deliberately the porcelain rather than libgit2 (README, Runtime): building libgit2 for ARM64 with a
/// maintained Swift binding is ongoing cost for no capability the CLI lacks, and running both paths
/// would double the bug surface.
public struct GitRunner: Sendable {
    public struct Output: Sendable {
        public let standardOutput: Data
        public let standardError: String
        public let exitCode: Int32

        public var text: String { String(decoding: standardOutput, as: UTF8.self) }
        public var succeeded: Bool { exitCode == 0 }
    }

    public enum Failure: Error, Sendable {
        case launchFailed(String)
        case commandFailed(arguments: [String], exitCode: Int32, standardError: String)
        case notARepository(URL)
    }

    public var executable: URL
    public var workingDirectory: URL

    public init(workingDirectory: URL, executable: URL = URL(fileURLWithPath: "/usr/bin/git")) {
        self.workingDirectory = workingDirectory
        self.executable = executable
    }

    /// Runs a command, returning output even on failure so callers can inspect it.
    @discardableResult
    public func run(_ arguments: [String], input: Data? = nil) throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        var environment = ProcessInfo.processInfo.environment
        // Keep output stable and non-interactive regardless of the operator's own git config.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        environment.removeValue(forKey: "GIT_DIR")
        environment.removeValue(forKey: "GIT_WORK_TREE")
        environment.removeValue(forKey: "GIT_INDEX_FILE")
        process.environment = environment

        let stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if input != nil { process.standardInput = Pipe() }

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(String(describing: error))
        }

        if let input, let stdinPipe = process.standardInput as? Pipe {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: input)
            try? stdinPipe.fileHandleForWriting.close()
        }

        // Read both pipes before waiting: a large diff will fill a pipe buffer and deadlock
        // otherwise.
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Output(
            standardOutput: outData,
            standardError: String(decoding: errData, as: UTF8.self),
            exitCode: process.terminationStatus)
    }

    /// Runs a command, throwing if it fails.
    @discardableResult
    public func check(_ arguments: [String], input: Data? = nil) throws -> Output {
        let output = try run(arguments, input: input)
        guard output.succeeded else {
            throw Failure.commandFailed(
                arguments: arguments,
                exitCode: output.exitCode,
                standardError: output.standardError)
        }
        return output
    }

    /// The repository root, or `nil` when the working directory is not inside one.
    public func repositoryRoot() throws -> URL? {
        let output = try run(["rev-parse", "--show-toplevel"])
        guard output.succeeded else { return nil }
        let path = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }
}
