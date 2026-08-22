import Foundation

/// Everything the supervisor surfaces to its owner.
public enum SupervisorEvent: Sendable {
    case frame(Frame)
    /// A line that was not valid JSON. Surfaced, never fatal — one bad line must not kill a session.
    case malformedLine(line: String, reason: String)
    /// Anything on the child's stderr. In healthy runs this stays empty; content here means the
    /// child is complaining, and it is kept off the frame stream so stdout stays pure JSONL.
    case standardError(String)
    /// A turn ended. **Not** the end of the session — the process stays alive awaiting input, and a
    /// single run can emit several of these (docs/RUNTIME.md, verified).
    case turnCompleted(TurnResult)
    /// The child exited. This, and only this, is session teardown.
    case exited(status: Int32, reason: Process.TerminationReason)
}

/// Owns one `claude` child process and turns its stdout into a stream of typed frames.
///
/// The central invariant, and the reason this type exists rather than a bare `Process` wrapper:
/// **a `result` frame is a turn boundary, not EOF.** The supervisor therefore never tears down on
/// `result`; it counts turns and waits for actual process exit.
public actor SessionSupervisor {
    public enum State: Sendable, Equatable {
        case notStarted
        case running
        case exited(status: Int32)
        case failed(String)
    }

    public private(set) var state: State = .notStarted
    /// Number of `result` frames seen. Grows past 1 whenever a background subagent finishes after
    /// its parent's turn has already ended.
    public private(set) var completedTurns = 0

    private let configuration: SessionConfiguration
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var continuation: AsyncStream<SupervisorEvent>.Continuation?

    public init(configuration: SessionConfiguration) {
        self.configuration = configuration
    }

    // MARK: - Lifecycle

    public func start() throws -> AsyncStream<SupervisorEvent> {
        guard case .notStarted = state else {
            throw SupervisorError.alreadyStarted
        }

        process.executableURL = try Self.resolve(executable: configuration.executable)
        process.arguments = configuration.arguments()
        process.currentDirectoryURL = configuration.workingDirectory
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // A steer written to an agent that has already exited must fail as an error, not as a
        // signal: the default `SIGPIPE` disposition would take the whole app down with it, from a
        // race nobody can avoid — the operator pressing Return as the session ends.
        fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.environment = configuration.resolvedEnvironment(inheriting: Self.inheritedEnvironment())

        let (stream, continuation) = AsyncStream<SupervisorEvent>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation

        // The reader owns the line buffer and the decode loop. It is a class behind a lock because
        // `readabilityHandler` fires on a private Dispatch queue, outside actor isolation.
        let reader = StreamReader(continuation: continuation)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                reader.finishStandardOutput()
                return
            }
            reader.ingestStandardOutput(data)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            reader.ingestStandardError(data)
        }

        process.terminationHandler = { process in
            reader.finish(status: process.terminationStatus, reason: process.terminationReason)
        }

        do {
            try process.run()
        } catch {
            state = .failed(String(describing: error))
            continuation.finish()
            throw SupervisorError.launchFailed(String(describing: error))
        }

        state = .running

        // Count turns without consuming the caller's stream.
        let counting = AsyncStream<SupervisorEvent>.makeStream(bufferingPolicy: .unbounded)
        Task { [weak self] in
            for await event in stream {
                if case .turnCompleted = event { await self?.noteTurnCompleted() }
                if case .exited(let status, _) = event { await self?.noteExit(status: status) }
                counting.continuation.yield(event)
            }
            counting.continuation.finish()
        }
        return counting.stream
    }

    private func noteTurnCompleted() { completedTurns += 1 }

    private func noteExit(status: Int32) { state = .exited(status: status) }

    // MARK: - Input

    /// Injects a user message — the initial prompt, or a mid-run steer.
    ///
    /// Delivery is **queued to the next turn boundary**, not immediate: a steer written while a
    /// tool call is in flight is consumed only once that call returns (docs/RUNTIME.md, verified at
    /// 4.0 s sent / 17.7 s consumed across a 12-second tool call). Callers should treat the message
    /// as pending until the `--replay-user-messages` echo arrives on the frame stream, and must not
    /// use this as a way to stop a running tool — that is `interrupt()`.
    public func send(userMessage text: String) throws {
        guard case .running = state else { throw SupervisorError.notRunning }
        let frame: JSONValue = .object([
            "type": .string("user"),
            "message": .object([
                "role": .string("user"),
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string(text)
                ])])
            ])
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = try encoder.encode(frame)
        data.append(UInt8(ascii: "\n"))
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw SupervisorError.writeFailed(String(describing: error))
        }
    }

    /// Closes stdin, letting the session finish its current work and exit.
    public func endInput() {
        try? stdinPipe.fileHandleForWriting.close()
    }

    /// Stops the child. Unlike a steer, this takes effect immediately.
    public func interrupt() {
        guard process.isRunning else { return }
        process.interrupt()
    }

    /// Hard kill, including any process group the child spawned.
    public func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    // MARK: - Helpers

    /// Locates the agent binary.
    ///
    /// A GUI process launched from Finder inherits `launchd`'s minimal `PATH`
    /// (`/usr/bin:/bin:/usr/sbin:/sbin`), not the operator's interactive one — so a Homebrew or npm
    /// install of `claude` is invisible to an inherited-`PATH` search even though it resolves fine
    /// in a terminal. The login shell is asked as a fallback, and failure is an error rather than a
    /// silent substitution: spawning something that is not the agent produces an empty session that
    /// looks like a hang.
    static func resolve(executable: String) throws -> URL {
        if executable.contains("/") {
            return URL(fileURLWithPath: executable)
        }

        let inherited = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? []
        if let found = search(executable, in: inherited.map(String.init)) { return found }

        if let shellPath = loginShellPath(), let found = search(executable, in: shellPath) {
            return found
        }

        throw SupervisorError.executableNotFound(executable)
    }

    private static func search(_ executable: String, in directories: [String]) -> URL? {
        for directory in directories where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func loginShellPath() -> [String]? {
        cachedLoginShellEnvironment?["PATH"]?.split(separator: ":").map(String.init)
    }

    /// The environment the child should inherit.
    ///
    /// The login shell's when it can be captured, because a Finder-launched app inherits
    /// `launchd`'s environment and the agent would then run every command without the operator's
    /// toolchain on `PATH`. Falls back to this process's own environment, which is correct when the
    /// app was started from a terminal.
    static func inheritedEnvironment() -> [String: String] {
        cachedLoginShellEnvironment ?? ProcessInfo.processInfo.environment
    }

    /// Captured once: it costs a process spawn and cannot change for the lifetime of the app.
    private static let cachedLoginShellEnvironment: [String: String]? = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // `-l` loads the profile that puts Homebrew, npm, and version managers on the path. `-c`
        // keeps it to one command so no interactive prompt can hang the spawn. `env -0` is
        // NUL-separated, so a variable whose value contains a newline survives intact.
        process.arguments = ["-lc", "/usr/bin/env -0"]
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

        var environment: [String: String] = [:]
        for record in data.split(separator: 0, omittingEmptySubsequences: true) {
            let entry = String(decoding: record, as: UTF8.self)
            guard let separator = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[entry.startIndex..<separator])] =
                String(entry[entry.index(after: separator)...])
        }
        return environment.isEmpty ? nil : environment
    }()
}

public enum SupervisorError: Error, Sendable {
    case alreadyStarted
    case notRunning
    case launchFailed(String)
    case writeFailed(String)
    /// The agent binary was not on the inherited `PATH` or the login shell's.
    case executableNotFound(String)
}

extension SupervisorError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .alreadyStarted: return "The session has already been started."
        case .notRunning: return "The session is not running."
        case .launchFailed(let detail): return "The agent process failed to launch: \(detail)"
        case .writeFailed(let detail): return "Writing to the agent failed: \(detail)"
        case .executableNotFound(let name):
            return """
                Could not find “\(name)”. It is not on this process's PATH, and asking the login \
                shell did not find it either. Install it, or set its full path in the session \
                configuration.
                """
        }
    }
}

// MARK: - Stream reader

/// Bridges the pipe callbacks (private Dispatch queue) to the event stream.
///
/// `@unchecked Sendable` with an explicit lock: `readabilityHandler` is not actor-isolated, and the
/// line buffer must survive across callbacks.
private final class StreamReader: @unchecked Sendable {
    private let lock = NSLock()
    private var assembler = LineAssembler()
    private let decoder = FrameDecoder()
    private let continuation: AsyncStream<SupervisorEvent>.Continuation
    private var standardOutputFinished = false
    private var processFinished = false
    private var terminationStatus: Int32 = 0
    private var terminationReason: Process.TerminationReason = .exit

    init(continuation: AsyncStream<SupervisorEvent>.Continuation) {
        self.continuation = continuation
    }

    func ingestStandardOutput(_ data: Data) {
        lock.lock()
        let lines: [String]
        do {
            lines = try assembler.append(data)
        } catch {
            lock.unlock()
            continuation.yield(.malformedLine(line: "", reason: String(describing: error)))
            return
        }
        lock.unlock()

        for line in lines {
            switch decoder.decode(line: line) {
            case .frame(let frame):
                continuation.yield(.frame(frame))
                if case .result(let result) = frame.kind {
                    continuation.yield(.turnCompleted(result))
                }
            case .malformed(let line, let reason):
                continuation.yield(.malformedLine(line: line, reason: reason))
            }
        }
    }

    func ingestStandardError(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        continuation.yield(.standardError(text))
    }

    func finishStandardOutput() {
        lock.lock()
        let trailing = assembler.flush()
        standardOutputFinished = true
        let shouldClose = processFinished
        let status = terminationStatus
        let reason = terminationReason
        lock.unlock()

        if let trailing, !trailing.isEmpty {
            switch decoder.decode(line: trailing) {
            case .frame(let frame): continuation.yield(.frame(frame))
            case .malformed(let line, let reason):
                continuation.yield(.malformedLine(line: line, reason: reason))
            }
        }
        if shouldClose { close(status: status, reason: reason) }
    }

    func finish(status: Int32, reason: Process.TerminationReason) {
        lock.lock()
        processFinished = true
        terminationStatus = status
        terminationReason = reason
        let shouldClose = standardOutputFinished
        lock.unlock()
        if shouldClose { close(status: status, reason: reason) }
    }

    private func close(status: Int32, reason: Process.TerminationReason) {
        continuation.yield(.exited(status: status, reason: reason))
        continuation.finish()
    }
}
