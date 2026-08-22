import Darwin
import Foundation

/// Minimal POSIX `AF_UNIX` stream-socket wrappers.
///
/// Deliberately raw rather than Network.framework: the approval helper is a short-lived,
/// dependency-light process whose only job is to survive long enough to print a verdict, and
/// blocking reads with explicit `SO_RCVTIMEO` deadlines are far easier to reason about — and to
/// prove fail-closed — than an async connection state machine.
public enum UnixSocket {

    /// `sockaddr_un.sun_path` is 104 bytes on Darwin, including the terminator.
    public static let maximumPathLength = 103

    public enum Error: Swift.Error, Sendable, Equatable {
        case pathTooLong(path: String, limit: Int)
        case socketFailed(errno: Int32)
        case bindFailed(errno: Int32)
        case listenFailed(errno: Int32)
        case connectFailed(errno: Int32)
        case writeFailed(errno: Int32)
        case readFailed(errno: Int32)
        case timedOut
        case closedByPeer
        case messageTooLong(bytes: Int)
    }

    static func makeAddress(path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard bytes.count <= maximumPathLength else {
            throw Error.pathTooLong(path: path, limit: maximumPathLength)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    static func withAddress<T>(_ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) rethrows -> T {
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                try body(rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    // MARK: - Framing

    /// Reads one newline-terminated message.
    ///
    /// `deadline` bounds the *total* wait, not each syscall, so a peer that dribbles bytes cannot
    /// extend it indefinitely.
    public static func readLine(
        descriptor: Int32,
        deadline: Date,
        maximumBytes: Int = 8 * 1024 * 1024
    ) throws -> String {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw Error.timedOut }
            try setReceiveTimeout(descriptor: descriptor, seconds: remaining)

            let count = read(descriptor, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    return String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                }
                guard buffer.count <= maximumBytes else { throw Error.messageTooLong(bytes: buffer.count) }
            } else if count == 0 {
                throw Error.closedByPeer
            } else {
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK { throw Error.timedOut }
                throw Error.readFailed(errno: code)
            }
        }
    }

    /// Writes one newline-terminated message, retrying partial writes.
    public static func writeLine(descriptor: Int32, message: String) throws {
        var payload = Array(message.utf8)
        payload.append(UInt8(ascii: "\n"))
        var offset = 0
        while offset < payload.count {
            let written = payload[offset...].withUnsafeBufferPointer { buffer in
                write(descriptor, buffer.baseAddress, buffer.count)
            }
            if written > 0 {
                offset += written
            } else {
                let code = errno
                if code == EINTR { continue }
                throw Error.writeFailed(errno: code)
            }
        }
    }

    /// Turns a write to a hung-up peer into an `EPIPE` error instead of a `SIGPIPE`.
    ///
    /// The default disposition of `SIGPIPE` terminates the process, and every write here is to a
    /// peer that is *expected* to vanish: a helper that hit its own deadline and exited, an app
    /// that was quit mid-approval. Without this, the broker answering a helper that has already
    /// gone kills whatever is hosting it — which is how the test bundle died with signal 13, and
    /// would just as happily have been the app.
    static func disableSIGPIPE(descriptor: Int32) {
        var enabled: Int32 = 1
        setsockopt(
            descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Runs a blocking socket call on a thread of its own.
    ///
    /// Reads and writes here park for as long as their deadline allows. Run on the cooperative
    /// pool — which is where an actor's work lands — a few concurrent approvals hold every thread
    /// the pool has, and the very tasks that would answer them never get scheduled. The pool is
    /// sized to the core count, so a small machine needs only a few in flight to wedge.
    public static func blocking<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            thread.name = "AgentHarness.UnixSocket.Blocking"
            thread.stackSize = 1 << 20
            thread.start()
        }
    }

    static func setReceiveTimeout(descriptor: Int32, seconds: TimeInterval) throws {
        var timeout = timeval(
            tv_sec: Int(seconds),
            tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        let result = setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        if result != 0 { throw Error.socketFailed(errno: errno) }
    }

    // MARK: - Client

    /// Connects, sends one message, and waits for one reply.
    ///
    /// Every failure path throws; the caller is expected to translate *any* throw into a denial.
    public static func request(socketPath: String, message: String, deadline: Date) throws -> String {
        var address = try makeAddress(path: socketPath)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Error.socketFailed(errno: errno) }
        defer { close(descriptor) }
        disableSIGPIPE(descriptor: descriptor)

        let connected = withAddress(&address) { pointer, length in
            connect(descriptor, pointer, length)
        }
        guard connected == 0 else { throw Error.connectFailed(errno: errno) }

        try writeLine(descriptor: descriptor, message: message)
        return try readLine(descriptor: descriptor, deadline: deadline)
    }

    /// A connection held open across many messages.
    ///
    /// Used by long-lived taps such as the MCP inspection proxy, where reconnecting per message
    /// would add latency to the relayed traffic.
    public final class Connection: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptor: Int32

        /// Returns `nil` when the peer is not reachable. Callers that are observability-only should
        /// treat that as "feature off", not as an error.
        public init?(socketPath: String) {
            guard var address = try? UnixSocket.makeAddress(path: socketPath) else { return nil }
            let candidate = socket(AF_UNIX, SOCK_STREAM, 0)
            guard candidate >= 0 else { return nil }
            let connected = UnixSocket.withAddress(&address) { pointer, length in
                connect(candidate, pointer, length)
            }
            guard connected == 0 else {
                Darwin.close(candidate)
                return nil
            }
            UnixSocket.disableSIGPIPE(descriptor: candidate)
            descriptor = candidate
        }

        public var isOpen: Bool {
            lock.lock(); defer { lock.unlock() }
            return descriptor >= 0
        }

        /// Sends one message. On failure the connection closes itself; callers decide whether that
        /// is fatal.
        @discardableResult
        public func send(_ message: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard descriptor >= 0 else { return false }
            do {
                try UnixSocket.writeLine(descriptor: descriptor, message: message)
                return true
            } catch {
                Darwin.close(descriptor)
                descriptor = -1
                return false
            }
        }

        public func close() {
            lock.lock()
            defer { lock.unlock() }
            guard descriptor >= 0 else { return }
            Darwin.close(descriptor)
            descriptor = -1
        }

        deinit { close() }
    }

    // MARK: - Server

    /// A bound, listening socket. Closing it unlinks the path.
    public final class Listener: @unchecked Sendable {
        public let path: String
        private let descriptor: Int32
        private var closed = false
        private let lock = NSLock()

        public init(path: String, backlog: Int32 = 64) throws {
            self.path = path
            unlink(path)
            var address = try UnixSocket.makeAddress(path: path)
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw Error.socketFailed(errno: errno) }
            self.descriptor = descriptor

            let bound = UnixSocket.withAddress(&address) { pointer, length in
                bind(descriptor, pointer, length)
            }
            guard bound == 0 else {
                let code = errno
                Darwin.close(descriptor)
                throw Error.bindFailed(errno: code)
            }
            // The socket is the approval channel; only its owner may speak on it.
            chmod(path, 0o600)

            guard listen(descriptor, backlog) == 0 else {
                let code = errno
                Darwin.close(descriptor)
                unlink(path)
                throw Error.listenFailed(errno: code)
            }
        }

        /// Blocks until a client connects. Returns `nil` once the listener is closed.
        ///
        /// A failed `accept` is not the end of the listener. `EINTR` (any signal delivered to this
        /// thread) and `ECONNABORTED` (a peer that gave up between the handshake and the accept)
        /// are ordinary events on a busy machine, and returning `nil` for one of them ended the
        /// caller's `while let` loop for good: the broker stayed bound to its socket, accepted
        /// nothing ever again, and every approval after that denied on the helper's deadline.
        public func accept() -> Int32? {
            while true {
                let client = Darwin.accept(descriptor, nil, nil)
                if client >= 0 {
                    // The peer here is a short-lived helper that may exit before we answer it.
                    UnixSocket.disableSIGPIPE(descriptor: client)
                    return client
                }
                let code = errno
                // Deliberate: a closed listener reports `EBADF`/`EINVAL`, which is not in this
                // list and ends the loop. Only genuinely transient errors are retried.
                let transient = [EINTR, ECONNABORTED, EAGAIN, EWOULDBLOCK, EMFILE, ENFILE]
                guard transient.contains(code) else { return nil }
                if isClosed { return nil }
                // Descriptor exhaustion clears only once something else lets go, and a bare
                // retry on it would spin a core. `EINTR` and `ECONNABORTED` retry immediately.
                if code != EINTR && code != ECONNABORTED { usleep(20_000) }
            }
        }

        private var isClosed: Bool {
            lock.lock(); defer { lock.unlock() }
            return closed
        }

        public func close() {
            lock.lock()
            defer { lock.unlock() }
            guard !closed else { return }
            closed = true
            shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
            unlink(path)
        }

        deinit { close() }
    }
}
