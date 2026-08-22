import AppKit
import HarnessCore
import SwiftTerm
import SwiftUI

/// A real shell, inside the window.
///
/// SwiftTerm supplies the emulator and the PTY; everything third-party is behind this file, so
/// swapping it later — for libghostty once that has a stable API and a renderer — means rewriting
/// one type rather than hunting through the interface.
///
/// SwiftTerm ships no macOS SwiftUI view (its only `SwiftUITerminalView` is iOS-only and marked
/// internal), so the `NSViewRepresentable` is ours.
struct TerminalPane: View {
    let workingDirectory: URL
    /// Which shell to run. `nil` uses the account's login shell.
    let shell: String?
    /// Bumped to start a fresh shell in place of one that exited.
    @Binding var generation: Int

    var body: some View {
        TerminalRepresentable(workingDirectory: workingDirectory, shell: shell)
            // The whole view is rebuilt on a restart: an exited PTY cannot be revived, and
            // recreating the view is how a new one gets attached.
            .id("\(generation)-\(shell ?? "default")")
            .padding(.leading, Theme.Space.sm)
            .background(Theme.Colors.canvas)
    }
}

private struct TerminalRepresentable: NSViewRepresentable {
    let workingDirectory: URL
    let shell: String?

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.processDelegate = context.coordinator

        // Gruvbox, so the shell is not a bright rectangle in the middle of a dark interface.
        view.installColors(Self.palette)
        view.nativeBackgroundColor = NSColor(Theme.Colors.canvas)
        view.nativeForegroundColor = NSColor(Theme.Colors.text)
        view.caretColor = NSColor(Theme.Colors.accent)
        view.font = Fonts.nsMono(size: 12.5)

        // The operator's own login shell — read from the account record, not from `$SHELL`, which
        // reports whatever spawned this process. Started as a login shell so their profile,
        // aliases, and PATH are all present.
        let executable = shell ?? LoginShell.path()
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        environment.append("LANG=\(ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8")")
        environment.append("SHELL=\(executable)")

        view.startProcess(
            executable: executable,
            args: LoginShell.loginArguments(for: executable),
            environment: environment,
            execName: nil)

        // `startProcess` does not take a working directory, so the shell is sent there once it is
        // up. Quoted, because a project path may contain spaces.
        let path = workingDirectory.path.replacingOccurrences(of: "'", with: "'\\''")
        view.send(txt: "cd '\(path)' && clear\n")

        return view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {}

    /// Ends the shell when the view goes away.
    ///
    /// Without this, hiding the pane tore down the view and left its `fork`ed shell running with
    /// nothing attached to it. Toggling repeatedly stacked up orphans — each holding the project
    /// directory open and, on a login shell, whatever its profile started.
    static func dismantleNSView(_ view: LocalProcessTerminalView, coordinator: Coordinator) {
        // `dismantleNSView` is a nonisolated static requirement, but SwiftUI only ever tears a view
        // down on the main thread and `view.process` is main-actor state. Asserting that here is
        // what lets `terminate` stay isolated instead of reaching across actors — which older
        // toolchains reject outright rather than warning about.
        MainActor.assumeIsolated { coordinator.terminate(view) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        private var hasTerminated = false

        @MainActor
        func terminate(_ view: LocalProcessTerminalView) {
            guard !hasTerminated else { return }
            hasTerminated = true
            // SIGHUP is what a closing terminal sends: the shell runs its exit handling rather
            // than being killed outright, and its children hang up with it.
            let pid = view.process.shellPid
            if pid > 0 { kill(pid, SIGHUP) }
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            hasTerminated = true
        }
    }

    /// Gruvbox dark-hard, in SwiftTerm's 16-colour order.
    private static let palette: [SwiftTerm.Color] = [
        .init(hex: 0x282828), .init(hex: 0xCC241D), .init(hex: 0x98971A), .init(hex: 0xD79921),
        .init(hex: 0x458588), .init(hex: 0xB16286), .init(hex: 0x689D6A), .init(hex: 0xA89984),
        .init(hex: 0x928374), .init(hex: 0xFB4934), .init(hex: 0xB8BB26), .init(hex: 0xFABD2F),
        .init(hex: 0x83A598), .init(hex: 0xD3869B), .init(hex: 0x8EC07C), .init(hex: 0xEBDBB2)
    ]
}

extension SwiftTerm.Color {
    /// SwiftTerm's colour channels are 16-bit, so an 8-bit hex component is scaled rather than
    /// truncated — otherwise every colour comes out near-black.
    convenience init(hex: UInt32) {
        func channel(_ shift: UInt32) -> UInt16 {
            UInt16((hex >> shift) & 0xFF) * 257
        }
        self.init(red: channel(16), green: channel(8), blue: channel(0))
    }
}
