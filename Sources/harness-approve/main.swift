import Darwin
import Foundation
import HarnessCore

// AgentHarness PreToolUse approval helper.
//
// Registered as a `PreToolUse` hook. Reads the hook payload on stdin, asks the broker over a Unix
// domain socket, and prints the runtime's decision JSON on stdout.
//
// The entire program is built around one obligation: **always print exactly one decision, and
// always print it before the runtime's hook timeout fires.** The runtime's own timeout fails open —
// it cancels the hook and runs the command (Finding 1) — so silence here is not a stall,
// it is an unapproved execution. Every error path therefore prints `deny` and exits 0.

// The runtime can close this helper's stdout the moment it stops caring about the answer, and a
// `SIGPIPE` on the way out would look to the runtime like a hook that failed rather than one that
// decided. Errors are handled below; signals are not.
signal(SIGPIPE, SIG_IGN)

let environment = ProcessInfo.processInfo.environment

/// Must stay strictly below the `timeout` configured on the hook itself, so that *we* end the wait
/// rather than the runtime cancelling us.
let deadlineSeconds = environment["HARNESS_APPROVAL_DEADLINE_SECONDS"]
    .flatMap(Double.init) ?? 540
let startedAt = Date()
let deadline = startedAt.addingTimeInterval(deadlineSeconds)

// MARK: - Single-shot output

final class Emitter: @unchecked Sendable {
    private let lock = NSLock()
    private var emitted = false

    /// Writes the decision and exits. Safe to call from any thread; only the first call wins.
    func emit(_ decision: ApprovalDecision) -> Never {
        lock.lock()
        if emitted {
            lock.unlock()
            // Another thread is already exiting; park rather than racing it.
            while true { Darwin.pause() }
        }
        emitted = true
        lock.unlock()

        let output = HookDecisionOutput(decision: decision, hookEventName: hookEventName)
        var bytes = Array(output.encoded().utf8)
        bytes.append(UInt8(ascii: "\n"))
        bytes.withUnsafeBufferPointer { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(STDOUT_FILENO, buffer.baseAddress! + offset, buffer.count - offset)
                if written > 0 { offset += written } else if errno != EINTR { break }
            }
        }
        // Exit 0 deliberately: a non-zero exit is an *error*, not a verdict, and the runtime may
        // treat it as a hook that failed to decide.
        exit(0)
    }
}

// Defaults to PreToolUse; corrected once the payload is parsed.
nonisolated(unsafe) var hookEventName = "PreToolUse"
let emitter = Emitter()

// MARK: - Watchdog

// Backstop for any blocking call that outlives its own timeout — a stalled stdin read, a wedged
// syscall, an unforeseen hang. Without this, an unexpected block is an unapproved execution.
let watchdog = Thread {
    let remaining = deadline.timeIntervalSinceNow
    if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
    emitter.emit(.failClosed(
        .helperTimeout,
        detail: "no approval was received within \(Int(deadlineSeconds))s"))
}
watchdog.name = "AgentHarness.ApprovalHelper.Watchdog"
watchdog.start()

// MARK: - Read the hook payload

let inputData = FileHandle.standardInput.readDataToEndOfFile()
guard !inputData.isEmpty else {
    emitter.emit(.failClosed(.malformedPayload, detail: "the hook payload was empty"))
}

let payload: HookPayload
do {
    payload = try JSONDecoder().decode(HookPayload.self, from: inputData)
    hookEventName = payload.hookEventName
} catch {
    emitter.emit(.failClosed(.malformedPayload, detail: "the hook payload could not be parsed"))
}

// MARK: - Ask the broker

guard let socketPath = environment["HARNESS_APPROVAL_SOCKET"], !socketPath.isEmpty else {
    emitter.emit(.failClosed(
        .brokerUnreachable, detail: "no approval socket was configured for this session"))
}

let request = ApprovalRequest(
    payload: payload,
    helperPID: getpid(),
    helperDeadline: deadline)

do {
    let reply = try UnixSocket.request(
        socketPath: socketPath,
        message: try request.encoded(),
        // Leave a margin so we still own the ending, even if the broker is exactly on time.
        deadline: deadline.addingTimeInterval(-2))
    emitter.emit(try ApprovalDecision.decode(from: reply))
} catch UnixSocket.Error.connectFailed {
    emitter.emit(.failClosed(
        .brokerUnreachable, detail: "the AgentHarness approval service is not running"))
} catch UnixSocket.Error.timedOut {
    emitter.emit(.failClosed(
        .helperTimeout, detail: "the approval service did not respond in time"))
} catch UnixSocket.Error.closedByPeer {
    emitter.emit(.failClosed(
        .brokerUnreachable, detail: "the approval service closed the connection without deciding"))
} catch {
    emitter.emit(.failClosed(
        .internalError, detail: "the approval request failed (\(error))"))
}
