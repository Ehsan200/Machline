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

    init() {
        tabs = [AppModel()]
    }

    /// The session in front. Always valid: closing the last tab opens an empty one.
    var current: AppModel {
        tabs.indices.contains(selection) ? tabs[selection] : tabs[0]
    }

    var workspace: Workspace? { current.workspace }

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
        tabs[index].stop()
        tabs.remove(at: index)

        if tabs.isEmpty {
            let replacement = AppModel()
            if let workspace = workspace?.url { replacement.open(workspace: workspace) }
            tabs = [replacement]
            selection = 0
            return
        }
        selection = min(selection, tabs.count - 1)
    }

    func closeCurrent() {
        close(selection)
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
