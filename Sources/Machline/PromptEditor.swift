import AppKit
import SwiftUI

/// The composer's text input, backed by `NSTextView`.
///
/// SwiftUI's `TextEditor` publishes neither the caret nor the selection, so shell-style editing —
/// kill-to-end, delete-word-back, history on the arrow keys — cannot be built on it. AppKit already
/// implements most of the Emacs bindings a shell user expects (`ctrl-A/E/B/F/D/K/P/N`); this adds
/// the ones it leaves out and routes the rest to the composer.
struct PromptEditor: NSViewRepresentable {

    @Binding var text: String
    var isEnabled = true
    /// Return with no modifiers.
    var onSubmit: () -> Void = {}
    /// Arrow keys, when nothing else claims them. Return `true` to consume.
    var onHistory: (_ backward: Bool) -> Bool = { _ in false }
    /// Keys the completion list claims while it is open. Return `true` to consume.
    var onCompletionKey: (_ key: CompletionKey) -> Bool = { _ in false }

    enum CompletionKey { case up, down, accept, dismiss }

    func makeNSView(context: Context) -> NSScrollView {
        // Built by hand rather than with `NSTextView.scrollableTextView()`, which hard-codes the
        // base class and leaves no way to install the subclass carrying the shell chords.
        let textView = PromptTextView(frame: .zero)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        context.coordinator.install(on: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        // Writing the same string back would collapse the selection on every keystroke.
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        }
        textView.isEditable = isEnabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptEditor

        init(parent: PromptEditor) {
            self.parent = parent
        }

        // `@MainActor` is explicit rather than inherited: on Swift 6.1 toolchains the
        // representable's Coordinator is not inferred to be main-actor, and AppKit's setters are.
        @MainActor
        func install(on textView: NSTextView) {
            textView.delegate = self
            textView.isRichText = false
            textView.allowsUndo = true
            textView.drawsBackground = false
            // Typed Persian gets Vazirmatn here too, not just once it is in the transcript.
            textView.font = Fonts.nsUI(size: 15)
            textView.textColor = NSColor(Theme.Colors.textStrong)
            textView.insertionPointColor = NSColor(Theme.Colors.accent)
            textView.textContainerInset = NSSize(width: 12, height: 12)
            // Smart substitutions rewrite quotes and dashes, which corrupts a pasted command.
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false

            if let editor = textView as? PromptTextView {
                editor.coordinator = self
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            Self.highlightTokens(in: textView)
        }

        /// Colours `/command` and `@path` inside the input.
        ///
        /// One input, but the parts that are not prose look like what they are: a command that the
        /// app or the CLI will act on, and a path that resolves to a file. Applied as temporary
        /// attributes so they never become part of the text that gets sent.
        @MainActor
        static func highlightTokens(in textView: NSTextView) {
            guard let layoutManager = textView.layoutManager else { return }
            let text = textView.string
            let whole = NSRange(location: 0, length: (text as NSString).length)
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)

            for token in PromptTokens.ranges(in: text) {
                layoutManager.addTemporaryAttributes(
                    [
                        .foregroundColor: NSColor(
                            token.kind == .command ? Theme.Colors.accent : Theme.Colors.link),
                        .backgroundColor: NSColor(
                            (token.kind == .command ? Theme.Colors.accent : Theme.Colors.link)
                                .opacity(0.12))
                    ],
                    forCharacterRange: token.range)
            }
        }

        /// AppKit routes special keys here as selector names.
        func textView(
            _ textView: NSTextView, doCommandBy selector: Selector
        ) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if parent.onCompletionKey(.accept) { return true }
                parent.onSubmit()
                return true

            case #selector(NSResponder.insertTab(_:)):
                return parent.onCompletionKey(.accept)

            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onCompletionKey(.dismiss)

            // `moveUp`/`moveDown` are also what ctrl-P and ctrl-N produce, so history and the
            // completion list share one path.
            case #selector(NSResponder.moveUp(_:)):
                if parent.onCompletionKey(.up) { return true }
                return parent.onHistory(true)

            case #selector(NSResponder.moveDown(_:)):
                if parent.onCompletionKey(.down) { return true }
                return parent.onHistory(false)

            // Shift-Return inserts the newline a multi-line composer needs.
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true

            default:
                return false
            }
        }
    }
}

/// `NSTextView` with the shell chords AppKit does not bind.
///
/// `ctrl-A/E/B/F/D/K/P/N` are already standard on macOS text views; `ctrl-U`, `ctrl-W`, and
/// `ctrl-C`-to-clear are not, and their absence is what makes an input feel unlike a shell.
final class PromptTextView: NSTextView {
    weak var coordinator: PromptEditor.Coordinator?

    private var caretObservers: [NSObjectProtocol] = []

    /// Brings the caret back after the window has been away.
    ///
    /// `NSTextView` runs the insertion point on a blink timer that stops when its window resigns
    /// key — and after a display sleep or a lock screen it does not always restart on its own, so
    /// the composer comes back looking as though it has no cursor at all while still accepting
    /// typing. Restarting the timer when the window or the app becomes active again is the
    /// documented way to reassert it.
    /// Also the teardown: AppKit calls this with no window when the view is removed, which is when
    /// the observers are dropped.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in caretObservers { NotificationCenter.default.removeObserver(observer) }
        caretObservers = []
        guard let window else { return }

        let centre = NotificationCenter.default
        let restart: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.firstResponder === self else { return }
                self.updateInsertionPointStateAndRestartTimer(true)
            }
        }
        caretObservers = [
            centre.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main,
                using: restart),
            centre.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main,
                using: restart),
            centre.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main,
                using: restart)
        ]
    }

    /// Return sends; Shift-Return and Option-Return break the line. Claimed before
    /// `interpretKeyEvents`, which leaves Option-Return unbound and beeping.
    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if isReturn, modifiers.contains(.shift) || modifiers.contains(.option) {
            insertText("\n", replacementRange: selectedRange())
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // A key equivalent is offered to *every* view in the window before the focused one gets
        // `keyDown`, so claiming these unconditionally took them from the shell pane as well: the
        // terminal never saw ctrl-C, and the running command never got SIGINT. These chords belong
        // to this editor only while this editor is where the typing is going.
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        guard event.modifierFlags.contains(.control),
              let characters = event.charactersIgnoringModifiers?.lowercased()
        else {
            return super.performKeyEquivalent(with: event)
        }

        switch characters {
        case "u":
            deleteToBeginningOfLine(nil)
            return true
        case "w":
            deleteWordBackward(nil)
            return true
        case "c":
            // Clearing the line, not copying: a shell's ctrl-C abandons what was typed. Copy is
            // ⌘C, which is unaffected.
            selectAll(nil)
            delete(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

/// Finds the parts of a draft that are not prose.
enum PromptTokens {
    enum Kind { case command, mention }
    struct Token { let range: NSRange; let kind: Kind }

    /// A command only counts at the very start of the message — anywhere else a slash is a path,
    /// a date, or a regex. A mention counts at any token boundary.
    static func ranges(in text: String) -> [Token] {
        var tokens: [Token] = []
        let string = text as NSString

        if let match = try? NSRegularExpression(pattern: "^/[A-Za-z0-9_:-]+")
            .firstMatch(in: text, range: NSRange(location: 0, length: string.length)) {
            tokens.append(Token(range: match.range, kind: .command))
        }

        if let mentions = try? NSRegularExpression(pattern: "(?<=^|\\s)@[^\\s]+") {
            for match in mentions.matches(
                in: text, range: NSRange(location: 0, length: string.length)) {
                tokens.append(Token(range: match.range, kind: .mention))
            }
        }
        return tokens
    }
}
