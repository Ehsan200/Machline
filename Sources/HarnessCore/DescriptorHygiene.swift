import Foundation

/// Keeps this app's descriptors out of the shell it forks.
///
/// `forkpty` gives the child a copy of every descriptor the app has open. This app is a process
/// farm — every session tab holds three pipes and an approval socket, every `git` call takes four
/// more — and it raises its own descriptor ceiling to 10 240 so that farm fits. A shell forked at a
/// busy moment therefore starts life with a thousand of the app's descriptors already open, and the
/// first descriptor it opens for itself is numbered 1024 or above.
///
/// That number is where it stops being the app's problem and starts being the shell's. `select`
/// addresses descriptors through an `fd_set`, which on Darwin is 1024 bits wide and cannot name a
/// descriptor above 1023. fish watches its descriptors with `select`, so its monitor thread panics
/// on the first one it allocates — `index out of bounds: the len is 32 but the index is 108` — and
/// the pane the operator opened shows `fish crashed, please report a bug.` instead of a prompt.
///
/// Marking everything close-on-exec first is what stops the inheritance. Nothing this app spawns
/// wants it: Foundation's `Process` spawns with `POSIX_SPAWN_CLOEXEC_DEFAULT` and redirects what
/// the child needs by hand, and `forkpty` dups the terminal onto 0, 1, and 2 in the child, which
/// clears the flag on the copies. So the shell keeps its terminal and gets nothing else.
public enum DescriptorHygiene {

    /// Marks every descriptor this process holds close-on-exec. Call immediately before forking.
    ///
    /// Returns how many it had to mark, which is the size of the inheritance that was about to
    /// happen. Descriptors 0, 1, and 2 are left alone: they are this app's own standard streams,
    /// and a child that inherits them is the normal arrangement, not a leak.
    ///
    /// Not a promise, only a sweep. A descriptor opened by another thread between this call and the
    /// fork is still inherited; there is no way to hold the whole table still from here. It takes
    /// the count from a thousand to nearly none, which is what the shell actually needs.
    @discardableResult
    public static func closeOnExecAll() -> Int {
        var marked = 0
        for descriptor in 3..<ceiling() {
            let flags = fcntl(descriptor, F_GETFD)
            // `EBADF`: nothing is open there. The table is sparse, so most of this range is holes.
            guard flags >= 0, flags & FD_CLOEXEC == 0 else { continue }
            if fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 { marked += 1 }
        }
        return marked
    }

    /// One past the highest descriptor worth asking about.
    ///
    /// The soft limit is the real answer, but it can be `RLIM_INFINITY`, and a sweep to infinity is
    /// not a sweep. The app asks for 10 240 at launch, so a cap an order of magnitude above that
    /// covers every descriptor it can actually hold while keeping this a few milliseconds of
    /// `fcntl` rather than an afternoon.
    private static func ceiling() -> Int32 {
        let cap: rlim_t = 65_536
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else { return Int32(cap) }
        return Int32(min(limits.rlim_cur, cap))
    }
}
