import Foundation
import Observation

/// Which conversations are running anywhere in the app, and when the recorded ones changed.
///
/// Every tab is its own `AppModel` with its own child process, and a window is a list of tabs. So a
/// tab asking "is this session live?" of itself gets the wrong answer about every other tab — which
/// is how a conversation running in one tab could be deleted from another, leaving that tab's
/// process writing to a transcript that no longer exists.
///
/// Process-wide rather than per-window on purpose: ⌘N opens another window on the same project, so
/// window scope has the same hole one level up.
@MainActor
@Observable
final class LiveSessions {
    static let shared = LiveSessions()

    /// Lower-cased CLI session ids with a child process behind them.
    private(set) var running: Set<String> = []

    /// Bumped whenever a conversation is archived, restored, or deleted. Rails watch it so a list
    /// somewhere else stops offering a conversation that has gone.
    private(set) var historyRevision = 0

    private init() {}

    func began(_ id: String?) {
        guard let id, !id.isEmpty else { return }
        running.insert(id.lowercased())
    }

    func ended(_ id: String?) {
        guard let id, !id.isEmpty else { return }
        running.remove(id.lowercased())
    }

    func isRunning(_ id: String) -> Bool {
        running.contains(id.lowercased())
    }

    func noteHistoryChanged() {
        historyRevision &+= 1
    }
}
