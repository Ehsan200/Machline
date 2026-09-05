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
    let generation: Int
    /// Asks for a fresh shell. What the notice's button does.
    let onRestart: () -> Void

    var body: some View {
        ShellSurface(workingDirectory: workingDirectory, shell: shell, onRestart: onRestart)
            // The whole view is rebuilt on a restart: an exited PTY cannot be revived, and
            // recreating the view is how a new one gets attached. The surface is rebuilt with it
            // rather than only the emulator, which is what takes the previous failure's notice
            // away when the new shell starts.
            .id("\(generation)-\(shell ?? "default")")
            .padding(.leading, Theme.Space.sm)
            .background(Theme.Colors.canvas)
    }
}

/// One shell's lifetime: the emulator, and whatever it has to say about having died.
private struct ShellSurface: View {
    let workingDirectory: URL
    let shell: String?
    let onRestart: () -> Void

    @State private var status = ShellStatus()

    var body: some View {
        TerminalRepresentable(workingDirectory: workingDirectory, shell: shell, status: status)
            .overlay(alignment: .top) {
                if let failure = status.failure {
                    ShellNotice(message: failure, onRestart: onRestart)
                }
            }
    }
}

/// What is known about the shell process, on the main actor.
///
/// Both ends of a failure write here. SwiftTerm reports a termination on its own queue, and a
/// shell that never started reports nothing at all — before this, either one left a pane that
/// stayed blank with no account of itself and no way back but a Restart button the operator had no
/// reason to press.
@MainActor
@Observable
final class ShellStatus {
    /// The notice to show, or `nil` while the shell is running.
    var failure: String?
    /// True once the process is known to be gone, so teardown does not signal a pid that has
    /// already been reaped.
    var hasExited = false
}

private struct TerminalRepresentable: NSViewRepresentable {
    let workingDirectory: URL
    let shell: String?
    let status: ShellStatus

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

        // A shell is a path on disk and the chosen one is remembered across launches, so a
        // Homebrew fish that moves in an upgrade leaves the preference pointing at nothing. The
        // forked child cannot report that: a failed `execve` can only `_exit(127)`, which used to
        // arrive as an empty pane. Checking first is what lets the notice name the bad path.
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            report("\(executable) is not an executable shell.")
            return view
        }

        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        environment.append("LANG=\(ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8")")
        environment.append("SHELL=\(executable)")

        // The shell is forked *in* the project, rather than sent there by a `cd` typed at its
        // prompt once it is up. Typing it works, but the shell records what it is typed: the first
        // Up-arrow in every new terminal recalled `cd '/some/project' && clear`, one keystroke
        // ahead of whatever the operator actually last ran. The child chdirs before it execs, so
        // there is nothing to hide with a `clear` either.
        // `startProcess` forks, and a fork hands the child every descriptor this app has open —
        // which at a busy moment is over a thousand, enough to push the shell's own descriptors
        // past what `select` can name. fish dies there. See `DescriptorHygiene`.
        DescriptorHygiene.closeOnExecAll()

        view.startProcess(
            executable: executable,
            args: LoginShell.loginArguments(for: executable),
            environment: environment,
            execName: nil,
            currentDirectory: workingDirectory.path)

        // `startProcess` returns nothing and throws nothing: a `forkpty` that fails just leaves the
        // view attached to no process. This app is a process farm — every session tab holds pipes
        // and a socket, every `git` call takes four more descriptors — so that failure is real, and
        // `running` is the only trace of it.
        if !view.process.running {
            report("Could not open a pseudo-terminal for \(executable).")
        }

        return view
    }

    /// Hands a notice to the main actor.
    ///
    /// Deferred rather than written in place: `makeNSView` runs inside a SwiftUI update, and state
    /// written during an update is state SwiftUI is already in the middle of reading.
    private func report(_ message: String) {
        let status = status
        Task { @MainActor in
            status.hasExited = true
            status.failure = message
        }
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

    func makeCoordinator() -> Coordinator { Coordinator(status: status) }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        private let status: ShellStatus

        init(status: ShellStatus) {
            self.status = status
            super.init()
        }

        @MainActor
        func terminate(_ view: LocalProcessTerminalView) {
            guard !status.hasExited else { return }
            status.hasExited = true
            // SIGHUP is what a closing terminal sends: the shell runs its exit handling rather
            // than being killed outright, and its children hang up with it.
            let pid = view.process.shellPid
            if pid > 0 { kill(pid, SIGHUP) }
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        /// SwiftTerm reports a termination on its own dispatch queue, so the notice is handed to
        /// the main actor rather than written from here. Only the status object crosses — the
        /// coordinator itself stays on the thread it was called on.
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            let notice = Self.notice(for: exitCode)
            let status = status
            Task { @MainActor in
                status.hasExited = true
                status.failure = notice
            }
        }

        /// SwiftTerm forwards `waitpid`'s raw status rather than an exit code, so it is decoded
        /// here. 127 is the shell that could not be `exec`d — the one failure the child has no
        /// other way to describe.
        private static func notice(for raw: Int32?) -> String {
            guard let raw else { return "The shell stopped." }
            let signal = raw & 0x7F
            if signal != 0 { return "The shell was stopped by signal \(signal)." }
            switch (raw >> 8) & 0xFF {
            case 0: return "The shell exited."
            case 127: return "The shell could not be started."
            case let code: return "The shell exited (\(code))."
            }
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

/// Why the pane is empty, and the one thing to do about it.
///
/// A bar at the top rather than a panel over the middle: whatever the dead shell printed before it
/// went is usually the reason it went, and covering that would be hiding the evidence.
private struct ShellNotice: View {
    let message: String
    let onRestart: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Text(message)
                .font(Theme.Typography.controlMedium)
                .foregroundStyle(Theme.Colors.text)
                .textSelection(.enabled)
            Spacer(minLength: Theme.Space.sm)
            QuietButton(title: "Restart", action: onRestart)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.surface)
        .overlay(alignment: .bottom) { Hairline(color: Theme.Colors.border) }
    }
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
