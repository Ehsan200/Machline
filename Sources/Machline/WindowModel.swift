import Foundation
import HarnessCore
import Observation
import SwiftUI

/// The sessions open in one window, and which is in front.
///
/// Tabs are drawn by the app rather than by AppKit. Native window tabs need `tabbingIdentifier` set
/// before the window is ordered in, which is not reachable from SwiftUI — the join happens a
/// runloop later, and the window that was already on screen is left behind as an empty shell. Owning
/// the tab strip removes that whole class of problem, and every tab shares one window's lifecycle.
///
/// One window is one project. A different project opens a different window.
@MainActor
@Observable
final class WindowModel {

    private(set) var tabs: [AppModel] = []
    private(set) var selection = 0

    /// This window's identity in the restoration record. Adopting a stored layout adopts its id, so
    /// the window keeps updating the same entry rather than adding a second one for itself.
    private(set) var id = UUID()

    /// Where the window should be put back, until the chrome has an `NSWindow` to put it on.
    private var pendingFrame: String?
    /// The last frame that was known, so a record written before AppKit has a window to ask —
    /// which is every window's first one — carries the frame it was restored with rather than
    /// dropping it.
    private var lastFrame: String?
    /// Reads the live window's frame. Set by `WindowChrome`; `nil` before the window exists.
    var frameProvider: (@MainActor () -> String?)?

    /// Whether the session rail is showing. Chrome belongs to the window, not to a tab: hiding a
    /// rail and having it come back on the next tab would be a setting that does not hold.
    var isSessionRailVisible = true {
        didSet { UserDefaults.standard.set(isSessionRailVisible, forKey: Self.sessionRailKey) }
    }

    /// Whether the run panel is showing.
    var isRunPanelVisible = true {
        didSet { UserDefaults.standard.set(isRunPanelVisible, forKey: Self.runPanelKey) }
    }

    private static let sessionRailKey = "isSessionRailVisible"
    private static let runPanelKey = "isRunPanelVisible"

    init() {
        tabs = [AppModel()]
        // Absent means never hidden, which is the default either way — `bool(forKey:)` would
        // report `false` for a first run and open every window with both rails collapsed.
        let defaults = UserDefaults.standard
        isSessionRailVisible = defaults.object(forKey: Self.sessionRailKey) as? Bool ?? true
        isRunPanelVisible = defaults.object(forKey: Self.runPanelKey) as? Bool ?? true
    }

    func toggleSessionRail() { isSessionRailVisible.toggle() }
    func toggleRunPanel() { isRunPanelVisible.toggle() }

    // MARK: - Restoration

    /// What this window would come back as. See `WindowRestoration` for why the app keeps its own
    /// record rather than leaving it to AppKit.
    func snapshot() -> WindowLayout {
        lastFrame = frameProvider?() ?? lastFrame
        return WindowLayout(
            id: id,
            tabs: tabs.map {
                WindowLayout.Tab(workspace: $0.workspace?.url, sessionID: $0.restorableSessionID)
            },
            selection: selection,
            frame: lastFrame)
    }

    /// Files the window's current shape. Cheap: the store coalesces writes.
    func noteLayoutChanged() {
        WindowRestoration.shared.record(snapshot())
    }

    /// A value that changes exactly when something the record holds changes, so a view can watch
    /// one thing rather than every tab.
    ///
    /// Deliberately built from settled state — the project, the conversation a tab was opened on —
    /// and never from the live agent tree, which changes with every streamed frame. A window that
    /// re-derived its layout at that rate would cost the timeline its frame rate.
    var layoutSignature: String {
        tabs
            .map { "\($0.workspace?.url.path ?? "")#\($0.restorableSessionID ?? "")" }
            .joined(separator: "|")
            + "@\(selection)"
    }

    /// Rebuilds the window from a stored layout: its project, its tabs, and the conversation each
    /// tab was reading.
    ///
    /// Nothing is started. The agents that were running died with the app, so a restored tab is in
    /// the same state a stopped one is — transcript on screen, one click from resuming.
    func restore(_ layout: WindowLayout) {
        let restored: [AppModel] = layout.tabs.compactMap { tab in
            guard let workspace = tab.workspace,
                  FileManager.default.fileExists(atPath: workspace.path)
            else { return nil }
            let model = AppModel()
            model.open(workspace: workspace)
            if let sessionID = tab.sessionID { model.show(recorded: sessionID) }
            return model
        }
        guard !restored.isEmpty else { return }

        for tab in tabs { tab.stop() }
        id = layout.id
        tabs = restored
        selection = min(max(layout.selection, 0), restored.count - 1)
        pendingFrame = layout.frame
        lastFrame = layout.frame
        noteLayoutChanged()
    }

    /// The frame a restored window should be put back at, handed over once.
    func takePendingFrame() -> String? {
        defer { pendingFrame = nil }
        return pendingFrame
    }

    /// The session in front, or `nil` only during the instant `close` holds no tabs.
    ///
    /// `current` used to end in `tabs[0]`, which crashed outright the moment the array was empty —
    /// which is exactly what `close` produces between removing the last tab and installing its
    /// replacement.
    private var frontTab: AppModel? {
        tabs.indices.contains(selection) ? tabs[selection] : tabs.first
    }

    /// The session in front. Always valid: closing the last tab opens an empty one.
    ///
    /// The fallback is a stored tab rather than one minted on demand: reading a property must not
    /// mutate the model, or a plain view read becomes a state change during a SwiftUI update.
    var current: AppModel { frontTab ?? fallback }

    /// Stands in for the front tab in the one moment there is none. Never handed out otherwise.
    private let fallback = AppModel()

    var workspace: Workspace? { frontTab?.workspace }

    func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        selection = index
    }

    /// Opens a recorded session in a tab, or raises the tab already showing it.
    func open(_ session: HistoricalSession, in workspace: URL) {
        if let existing = tabs.firstIndex(where: { $0.isShowing(session) }) {
            selection = existing
            return
        }

        // An untouched tab is adopted rather than left behind as an empty one.
        if current.isEmpty {
            current.open(workspace: workspace)
            current.resume(session)
            return
        }

        let model = AppModel()
        model.open(workspace: workspace)
        model.resume(session)
        tabs.append(model)
        selection = tabs.count - 1
    }

    /// Points this window at a different project.
    ///
    /// The window's tabs belong to the project they were opened for, so they are closed — and
    /// stopped, since each owns a child process that would otherwise keep running with nothing
    /// showing it.
    func replaceProject(with url: URL) {
        for tab in tabs { tab.stop() }
        let model = AppModel()
        model.open(workspace: url)
        tabs = [model]
        selection = 0
    }

    /// Opens an empty session tab on the same project.
    func openBlankTab() {
        guard let workspace = current.workspace?.url else { return }
        let model = AppModel()
        model.open(workspace: workspace)
        tabs.append(model)
        selection = tabs.count - 1
    }

    /// Closes a tab, stopping whatever it was running.
    ///
    /// A tab owns a child process and an approval broker; dropping the reference without stopping
    /// it would leave an ungated agent running with nothing watching it.
    func close(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        // Read the project *before* the tab goes: the last tab is also the one `workspace` reads
        // from, and asking after the removal is what crashed the window on ⌘W.
        let project = workspace?.url
        tabs[index].stop()
        tabs.remove(at: index)

        if tabs.isEmpty {
            let replacement = AppModel()
            if let project { replacement.open(workspace: project) }
            tabs = [replacement]
            selection = 0
            return
        }
        selection = min(selection, tabs.count - 1)
    }

    func closeCurrent() {
        close(selection)
    }

    // MARK: - Commit drafting

    /// The conversation a commit draft in `tab` should fork.
    ///
    /// Forking beats a cold run twice over — the agent already watched the work happen, and the
    /// provider's cache already holds the conversation, so the drafting call sends a short prompt
    /// instead of the whole patch. What matters is forking the *right* conversation, and that is a
    /// question about this window: the tab's own, then the most recently active of its siblings on
    /// the same project, and only then the project's newest transcript.
    ///
    /// Reaching straight for the project's newest was wrong in the case that matters — two windows
    /// on one repository, each with its own work in flight — because the draft was written by
    /// whichever window had typed most recently rather than by the one being committed from.
    /// `nil` means there is nothing to fork and the draft runs cold on the small model.
    func commitDraftFork(for tab: AppModel) -> CommitDraftGenerator.Fork? {
        guard let workspace = tab.workspace?.url else { return nil }

        if let sessionID = tab.forkableSessionID {
            return CommitDraftGenerator.Fork(sessionID: sessionID, workingDirectory: workspace)
        }

        let sibling = tabs
            .filter {
                $0 !== tab
                    && $0.workspace?.url.standardizedFileURL == workspace.standardizedFileURL
            }
            .compactMap { other in
                other.forkableSessionID.map {
                    (sessionID: $0, activityAt: other.lastActivityAt ?? .distantPast)
                }
            }
            .max { $0.activityAt < $1.activityAt }
        if let sibling {
            return CommitDraftGenerator.Fork(
                sessionID: sibling.sessionID, workingDirectory: workspace)
        }

        return tab.projectDraftFork
    }

    func selectNextTab() {
        guard tabs.count > 1 else { return }
        selection = (selection + 1) % tabs.count
    }

    func selectPreviousTab() {
        guard tabs.count > 1 else { return }
        selection = (selection - 1 + tabs.count) % tabs.count
    }
}

extension AppModel {
    /// True for a tab nothing has happened in yet, which may be reused rather than added to.
    var isEmpty: Bool {
        session == nil && graph.root == nil && replay.isEmpty && workspace == nil
    }

    func isShowing(_ session: HistoricalSession) -> Bool {
        resumedFrom?.id == session.id || isLive(session)
    }

    /// The label for this session's tab.
    var tabTitle: String {
        if let resumedFrom { return title(for: resumedFrom) }
        if let workspace { return workspace.name }
        return "New session"
    }
}

/// Defers a window's model to first use, so re-creating the view does not rebuild it.
///
/// See `ContentView.box` for why the model cannot simply be `@State`'s initial value.
@MainActor
final class WindowModelBox {
    lazy var model = WindowModel()
}
