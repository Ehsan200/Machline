import Foundation

/// Runs blocking work on a thread of its own and awaits the result.
///
/// The gate's tests drive real processes and real sockets, so they block: a socket round trip, a
/// `readDataToEndOfFile` on a spawned helper. Called straight from a test, that block sits on a
/// cooperative-pool thread — and the broker those tests are talking to answers from a `Task` on
/// that same pool. On a developer machine with a dozen cores nobody notices; on a two- or
/// four-core CI runner the blocked tests occupy every thread, the broker never gets one, and the
/// helper denies on its own deadline. The failure reads as a broken gate and is really a starved
/// scheduler.
///
/// Blocking a *plain* thread cannot starve the pool, so the round trip goes here.
func offCooperativePool<T: Sendable>(
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
        thread.name = "HarnessTests.BlockingWork"
        thread.stackSize = 1 << 20
        thread.start()
    }
}
