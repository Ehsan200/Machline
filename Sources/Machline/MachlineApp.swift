import HarnessCore
import SwiftUI

/// What a window opens onto: a project, and optionally one recorded session inside it to resume.
///
/// A window is one project. Sessions within it are tabs drawn by the app, so this only ever
/// describes a window's starting point.
struct WindowTarget: Hashable, Codable {
    var workspacePath: String?
    var resumeSessionID: String?
    /// Makes an otherwise identical target unique.
    ///
    /// `openWindow` reuses a window already presenting the same value, so asking for a second
    /// empty window returned the first one — including one that had since opened a project and no
    /// longer looked empty at all. A fresh nonce means ⌘N always produces a new window.
    var nonce: String?

    var workspace: URL? { workspacePath.map { URL(fileURLWithPath: $0) } }

    init(workspace: URL? = nil, resumeSessionID: String? = nil, isUnique: Bool = false) {
        self.workspacePath = workspace?.standardizedFileURL.path
        self.resumeSessionID = resumeSessionID
        self.nonce = isUnique ? UUID().uuidString : nil
    }
}

@main
struct MachlineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // One window per project. Its sessions are tabs, each with its own child process,
        // approval broker, and agent tree, so several run at once without stopping each other.
        WindowGroup(id: "session", for: WindowTarget.self) { $target in
            ContentView(target: $target)
                .frame(
                    minWidth: Theme.Layout.windowMinWidth,
                    minHeight: Theme.Layout.windowMinHeight)
        } defaultValue: {
            WindowTarget()
        }
        // The title bar is the only chrome above the rails: the interface carries no header of its
        // own, so leaving the system bar visible but unadorned keeps the first event at the top.
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(after: .appInfo) {
                UpdateCommand()
            }
            CommandGroup(replacing: .newItem) {
                NewWindowButtons()
            }
            CommandGroup(after: .newItem) {
                SessionTabCommands()
            }
        }
    }
}

/// The File-menu entries that open windows. Split out because `openWindow` needs a view context.
private struct NewWindowButtons: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Project…") {
            guard let url = WorkspacePicker.choose() else { return }
            openWindow(id: "session", value: WindowTarget(workspace: url, isUnique: true))
        }
        .keyboardShortcut("o")

        // Always a new window, landing on the home page.
        Button("New Window") {
            openWindow(id: "session", value: WindowTarget(isUnique: true))
        }
        .keyboardShortcut("n")
    }
}

/// Keeps AppKit out of the tab business.
///
/// Sessions are tabbed by the app inside one window (`WindowModel`), so system window tabbing is
/// switched off: with it on, macOS folds two projects' windows into one tab group and the two
/// tab strips stack.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        // Belt and braces behind the per-descriptor `SO_NOSIGPIPE`/`F_SETNOSIGPIPE` calls: this
        // app writes to two things that can hang up under it — the agent's stdin and an approval
        // helper's socket — and the default disposition of `SIGPIPE` is to kill the process. A
        // write to a vanished peer should be an error to handle, never the end of the app.
        signal(SIGPIPE, SIG_IGN)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Waits for a window to exist before it asks anything — see `UpdateScheduler.checkIfDue`.
        UpdateScheduler.shared.start()
    }
}

/// The open panel, in one place so the menu and the rail present the same thing.
enum WorkspacePicker {
    @MainActor
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

/// Tab commands for the window in front.
///
/// `WindowModel` lives inside a window's view tree, so the menu reaches it through the focused
/// value rather than through a global.
struct SessionTabCommands: View {
    @FocusedValue(\.windowModel) private var window

    var body: some View {
        Button("New Session Tab") { window?.openBlankTab() }
            .keyboardShortcut("t")
            .disabled(window?.workspace == nil)

        Button("Close Session Tab") { window?.closeCurrent() }
            .keyboardShortcut("w")
            .disabled(window == nil)

        Divider()

        Button("Next Session") { window?.selectNextTab() }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled((window?.tabs.count ?? 0) < 2)

        Button("Previous Session") { window?.selectPreviousTab() }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled((window?.tabs.count ?? 0) < 2)

        Divider()

        Button(window?.isSessionRailVisible == false ? "Show Session Rail" : "Hide Session Rail") {
            window?.toggleSessionRail()
        }
        .keyboardShortcut("[", modifiers: [.command, .option])
        .disabled(window?.workspace == nil)

        Button(window?.isRunPanelVisible == false ? "Show Run Panel" : "Hide Run Panel") {
            window?.toggleRunPanel()
        }
        .keyboardShortcut("]", modifiers: [.command, .option])
        .disabled(window?.workspace == nil)

        Divider()

        Button("Toggle Shell") { window?.current.toggleTerminal() }
            // Control-backtick, the shortcut every editor uses for its terminal drawer.
            .keyboardShortcut("`", modifiers: .control)
            .disabled(window?.workspace == nil)

        Divider()

        // ⌘1…⌘9 jump straight to a tab, the way every tabbed application does. Hidden from the
        // menu once a window has fewer tabs than the number, so the list does not fill with
        // entries that do nothing.
        ForEach(1...9, id: \.self) { index in
            Button("Session \(index)") { window?.select(index - 1) }
                .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                .disabled((window?.tabs.count ?? 0) < index)
        }
    }
}

struct WindowModelFocusKey: FocusedValueKey {
    typealias Value = WindowModel
}

extension FocusedValues {
    var windowModel: WindowModel? {
        get { self[WindowModelFocusKey.self] }
        set { self[WindowModelFocusKey.self] = newValue }
    }
}

/// The update check, in the application menu where macOS users look for it.
struct UpdateCommand: View {
    @FocusedValue(\.windowModel) private var window

    @State private var scheduler = UpdateScheduler.shared

    var body: some View {
        Button("Check for Updates…") { window?.current.checkForUpdates() }
            .disabled(window == nil)

        // The daily check is the app talking to GitHub without being asked, so the switch for it
        // sits next to the manual one rather than in a settings window nobody opens.
        Toggle("Check Automatically", isOn: $scheduler.isEnabled)
    }
}
