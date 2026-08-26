import AppKit
import HarnessCore
import Observation
import SwiftUI

/// Remembers which projects were open in which windows, and puts them back at the next launch.
///
/// macOS already has a mechanism for this, and it is not dependable here: "Close windows when
/// quitting an application" is on by default, so a normal ⌘Q discards the system's restoration
/// state while a force quit — which never runs that code — leaves it behind. The result was an app
/// that reopened its projects only when it was killed. This owns the record instead: every change
/// to a window's tabs, selection, or frame is written to disk as it happens, so both exits restore
/// the same thing, and a crash loses at most the last unsaved instant.
///
/// What comes back is the shape of the work — windows, projects, tabs, and the conversation each
/// tab was reading. Not the agents: their child processes died with the app, and starting one per
/// restored tab would be a farm of agents nobody asked for. A restored tab shows its transcript,
/// exactly as a stopped tab does, and resumes on a click.
@MainActor
final class WindowRestoration {

    static let shared = WindowRestoration()

    /// How long a burst of changes is allowed to settle before it is written.
    ///
    /// Long enough that dragging a window is one write rather than a hundred, short enough that a
    /// force quit a second after opening a project still restores it.
    private static let settleInterval: Duration = .milliseconds(400)

    private let store: WindowLayoutStore
    /// Windows currently on screen, in the order they were first recorded.
    private var live: [UUID: WindowLayout] = [:]
    private var order: [UUID] = []
    /// Read at launch and handed out to the windows that adopt them.
    private var unclaimed: [WindowLayout]
    private var pending: [UUID: WindowLayout] = [:]
    private var writer: Task<Void, Never>?
    /// Windows the operator closed. A closed window is not merely dropped from `live`: a view tree
    /// coming down is still a view tree, and one last layout report on the way out would put the
    /// window straight back into the record it was just removed from.
    private var closed: Set<UUID> = []
    /// The windows being watched for their close, by the window object. See `watchClose`.
    private var watched: [ObjectIdentifier: CloseWatch] = [:]
    /// Set the moment the app is on its way out, so the windows AppKit closes on the way are not
    /// mistaken for windows the operator closed.
    private var isTerminating = false

    /// One window's close observation: the token to release, and the model whose id the close is
    /// reported against. The model is held rather than weakly referenced because it is what the id
    /// is read from, and it is let go the moment the window closes.
    private struct CloseWatch {
        let token: any NSObjectProtocol
        let model: WindowModel
    }

    init(store: WindowLayoutStore = WindowLayoutStore()) {
        self.store = store
        unclaimed = store.load()
    }

    // MARK: - Launch

    /// Whether anything is waiting to be restored. Read by the launch window before it decides it
    /// is a plain empty window.
    var hasLaunchLayouts: Bool { !unclaimed.isEmpty }

    /// The stored windows, handed out once: the caller adopts the first and opens the rest.
    ///
    /// Layouts whose project has since been moved or deleted are dropped rather than restored as a
    /// window pointing at nothing.
    func takeLaunchLayouts() -> [WindowLayout] {
        let layouts = unclaimed.filter { layout in
            guard let workspace = layout.workspace else { return false }
            return FileManager.default.fileExists(atPath: workspace.path)
        }
        unclaimed = []
        for layout in layouts.dropFirst() { pending[layout.id] = layout }
        return layouts
    }

    /// The layout a window was opened to restore.
    func claim(id: UUID) -> WindowLayout? {
        pending.removeValue(forKey: id)
    }

    // MARK: - Recording

    /// Notes what a window is showing now. Cheap to call often — writes are coalesced.
    ///
    /// A window with no project is not recorded at all. It has nothing to restore, and recording it
    /// would empty the file the launch window is about to restore *from*, since that window reports
    /// itself before it has adopted anything.
    func record(_ layout: WindowLayout) {
        guard !isTerminating, !closed.contains(layout.id), layout.isRestorable else { return }
        if live.updateValue(layout, forKey: layout.id) == nil { order.append(layout.id) }
        scheduleWrite()
    }

    /// Watches a window for its close, from an object that outlives the view tree.
    ///
    /// The natural home for this is the chrome's coordinator, beside the move and resize observers,
    /// and that is where it was — where it never fired. SwiftUI observes `willClose` itself, from a
    /// registration made when the window was created, which is before the chrome has a view at all;
    /// its handler tears the window's view tree down, and that takes the coordinator, its observer
    /// bag, and the bag's `deinit` with it. `NotificationCenter` does not deliver to an observer
    /// removed while the notification is being posted, so the app heard about every window that
    /// moved and none that closed: a project the operator closed was still in the record at the
    /// next launch, and came back. Observing from here settles the ordering question — this object
    /// is never torn down.
    func watchClose(of nsWindow: NSWindow, model: WindowModel) {
        let key = ObjectIdentifier(nsWindow)
        guard watched[key] == nil else { return }
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nsWindow, queue: .main
        ) { _ in
            MainActor.assumeIsolated { WindowRestoration.shared.noteClosed(key) }
        }
        watched[key] = CloseWatch(token: token, model: model)
    }

    private func noteClosed(_ key: ObjectIdentifier) {
        guard let watch = watched.removeValue(forKey: key) else { return }
        NotificationCenter.default.removeObserver(watch.token)
        forget(id: watch.model.id)
    }

    /// Forgets a window the operator closed.
    ///
    /// Ignored once the app is terminating: quitting closes every window, and treating that as the
    /// operator emptying their workspace is exactly the bug this type exists to fix.
    ///
    /// Written at once rather than coalesced. A close is a single deliberate act, not the burst a
    /// drag is, and the 400 ms of settling was long enough to lose it: closing the last window and
    /// quitting in the same breath cancelled the pending write, and `beginTermination` will not
    /// write an empty record — so the file kept the window that had just been closed.
    func forget(id: UUID) {
        guard !isTerminating else { return }
        closed.insert(id)
        guard live.removeValue(forKey: id) != nil else { return }
        order.removeAll { $0 == id }
        writer?.cancel()
        writer = nil
        store.save(orderedLayouts())
    }

    /// Freezes the record and flushes it. Called as the app begins to quit.
    ///
    /// An empty record is never written here. By this point the windows may already have been
    /// closed on the way out, and "there are no windows" at termination is indistinguishable from
    /// "the app is halfway through closing them" — while a workspace the operator really did empty
    /// was already cleared by `forget` when they closed the last window.
    func beginTermination() {
        guard !isTerminating else { return }
        writer?.cancel()
        writer = nil
        let layouts = orderedLayouts()
        if !layouts.isEmpty { store.save(layouts) }
        isTerminating = true
    }

    // MARK: - Writing

    private func orderedLayouts() -> [WindowLayout] {
        order.compactMap { live[$0] }
    }

    private func scheduleWrite() {
        writer?.cancel()
        writer = Task { [store] in
            try? await Task.sleep(for: Self.settleInterval)
            guard !Task.isCancelled else { return }
            store.save(self.orderedLayouts())
        }
    }
}

/// The window itself: its background, its frame, and the moves only AppKit can report. Its close is
/// watched by `WindowRestoration`, which outlives the view tree the close destroys.
///
/// SwiftUI has no window object to hold, so this reaches the `NSWindow` through a zero-sized view.
/// It also switches the system's own restoration off: this app restores its windows from
/// `WindowRestoration`, and leaving AppKit's mechanism on would reopen a second set beside them.
struct WindowChrome: NSViewRepresentable {
    let window: WindowModel

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        // A view has no window until it is in one, which is a runloop after this call.
        DispatchQueue.main.async {
            guard let nsWindow = view.window else { return }
            context.coordinator.attach(nsWindow, to: window)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Holds notification tokens for as long as the coordinator lives.
    ///
    /// Its own class because the tokens have to be released in a `deinit`, and a `deinit` on a
    /// main-actor type cannot touch non-`Sendable` state.
    final class ObserverBag: @unchecked Sendable {
        var tokens: [any NSObjectProtocol] = []

        deinit {
            for token in tokens { NotificationCenter.default.removeObserver(token) }
        }
    }

    @MainActor
    final class Coordinator {
        private weak var attached: NSWindow?
        private let observers = ObserverBag()

        func attach(_ nsWindow: NSWindow, to model: WindowModel) {
            guard attached !== nsWindow else { return }
            attached = nsWindow

            nsWindow.backgroundColor = NSColor(Theme.Colors.canvas)
            nsWindow.isRestorable = false

            // A window built from a stored layout comes back where it was.
            if let frame = model.takePendingFrame() {
                nsWindow.setFrame(NSRectFromString(frame), display: false)
            }
            model.frameProvider = { [weak nsWindow] in
                nsWindow.map { NSStringFromRect($0.frame) }
            }
            // The window records itself before this runs — a view has no `NSWindow` until it is in
            // one — so the first record carries no frame until it is taken again here.
            model.noteLayoutChanged()

            let center = NotificationCenter.default
            for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
                observers.tokens.append(center.addObserver(
                    forName: name, object: nsWindow, queue: .main
                ) { _ in
                    MainActor.assumeIsolated { model.noteLayoutChanged() }
                })
            }
            // Not one of the observers above: a closing window takes this coordinator with it
            // before the notification is delivered. See `WindowRestoration.watchClose`.
            WindowRestoration.shared.watchClose(of: nsWindow, model: model)
        }
    }
}
