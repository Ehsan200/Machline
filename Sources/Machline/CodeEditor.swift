import AppKit
import HarnessCore
import SwiftUI

/// A file, open for editing.
///
/// TextKit 2, so layout is paid per viewport rather than per document. Colour is scanned off the
/// main actor and applied to the visible stretch only, as rendering attributes — beside the text,
/// so it never enters the undo stack nor the saved bytes.
struct CodeEditor: NSViewRepresentable {

    /// Installed only when `revision` changes; writing it back per keystroke collapses the caret.
    let text: String
    /// Bumped on a load or reload, never on typing.
    let revision: Int
    let fileName: String
    let isEditable: Bool
    let onEdit: (String) -> Void
    /// Bumped on every write; each one ends the current undo run.
    let saveGeneration: Int

    /// Above this the file is shown uncoloured — the span list costs more than the colour is worth.
    static let maximumHighlightBytes = 2 * 1_048_576

    /// Line numbers go here. Drawn in SwiftUI — see `GutterView` for why it cannot be AppKit.
    let gutter: EditorGutterModel

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CodeTextView(usingTextLayoutManager: true)
        // Never wrapped: alignment is the point, as in the diff cards. Long lines scroll sideways.
        textView.autoresizingMask = []
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.size = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(Theme.Colors.canvas)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        context.coordinator.install(on: textView, gutter: gutter)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CodeTextView else { return }
        context.coordinator.parent = self
        context.coordinator.adopt(text: text, revision: revision, in: textView)
        context.coordinator.breakUndoCoalescing(at: saveGeneration)
        textView.isEditable = isEditable
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor

        private weak var textView: CodeTextView?
        private var gutter: EditorGutterModel?

        /// In positional order, so the viewport's stretch is found by bisection.
        private var spans: [HighlightSpan] = []
        /// UTF-16 offset of each line start, for offset -> line number.
        private var lineStarts: [Int] = [0]
        /// The stretch already coloured. Scrolling asks to repaint on every frame; this refuses.
        private var painted: NSRange?
        private var installedRevision = -1
        private var brokenAtGeneration = 0
        private var scan: Task<Void, Never>?
        /// Guards against a paint triggered by the layout that a paint itself provoked.
        private var isPainting = false

        init(parent: CodeEditor) {
            self.parent = parent
        }

        /// Explicit: a representable's Coordinator is not inferred main-actor, and AppKit is.
        @MainActor
        func install(on textView: CodeTextView, gutter: EditorGutterModel) {
            self.textView = textView
            self.gutter = gutter
            textView.delegate = self
            textView.coordinator = self

            textView.isRichText = false
            textView.allowsUndo = true
            textView.drawsBackground = true
            textView.backgroundColor = NSColor(Theme.Colors.canvas)
            textView.font = Fonts.nsMono(size: 11.5)
            textView.textColor = NSColor(Theme.Colors.text)
            textView.insertionPointColor = NSColor(Theme.Colors.accent)
            textView.selectedTextAttributes = [
                .backgroundColor: NSColor(Theme.Colors.textSelection)
            ]
            textView.textContainerInset = NSSize(width: 6, height: 10)

            // In prose a convenience; in source, a curly quote the compiler wanted straight.
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.isContinuousSpellCheckingEnabled = false
            textView.isGrammarCheckingEnabled = false
        }

        /// Installs the model's text, if the view is not already showing it.
        func adopt(text: String, revision: Int, in textView: CodeTextView) {
            guard revision != installedRevision else { return }
            installedRevision = revision
            textView.string = text
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            // Opening a file is not an edit; without this the first ⌘Z empties the editor.
            textView.undoManager?.removeAllActions()
            rescan(source: text)
        }

        /// Ends the current run of typing so the next ⌘Z stops here.
        ///
        /// `NSTextView` coalesces keystrokes into one undo step and rarely breaks the run itself, so
        /// an hour of editing was one ⌘Z back to the file as opened. Each save breaks it.
        func breakUndoCoalescing(at generation: Int) {
            guard generation != brokenAtGeneration else { return }
            brokenAtGeneration = generation
            textView?.breakUndoCoalescing()
        }

        // MARK: Editing

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? CodeTextView else { return }
            let source = textView.string
            parent.onEdit(source)
            // Colours now describe text that moved; a stale span beats a blank file until the scan.
            painted = nil
            rescan(source: source)
            refreshGutter()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Only the viewport: `needsDisplay` would dirty the whole document, which for a long
            // file is thousands of points of scrollback invalidated on every arrow key.
            guard let textView else { return }
            textView.setNeedsDisplay(textView.visibleRect)
        }

        // MARK: Scanning

        /// Re-reads the whole file, off the main actor, once typing pauses.
        ///
        /// Whole-file, not incremental: bounding the dirty region needs to know whether the edit
        /// landed inside a string or block comment, which is what the scan answers. Doing it
        /// properly means a parser holding a tree — a later decision, not one to approximate.
        private func rescan(source: String) {
            scan?.cancel()
            let fileName = parent.fileName
            let limit = CodeEditor.maximumHighlightBytes
            scan = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }

                let scanned = await Task.detached(priority: .userInitiated) {
                    () -> ([HighlightSpan], [Int]) in
                    let lines = Self.lineStarts(in: source)
                    guard source.utf8.count <= limit,
                          SyntaxHighlighter.canHighlight(fileName: fileName)
                    else { return ([], lines) }

                    let scanned = SyntaxHighlighter.spans(in: source, fileName: fileName)
                    return (Self.offsets(of: scanned, in: source), lines)
                }.value

                guard !Task.isCancelled else { return }
                self?.spans = scanned.0
                self?.lineStarts = scanned.1
                self?.paint(force: true)
                self?.refreshGutter()
            }
        }

        /// Turns the scanner's `String.Index` ranges into UTF-16 offsets, in one pass.
        ///
        /// `NSRange(_:in:)` measures from the start of the string every time it is called, so using
        /// it per span is quadratic in the file — seconds of it on a few thousand lines. Spans come
        /// out of the scanner in positional order, so a cursor that only moves forward converts the
        /// whole list for the cost of a single walk.
        private nonisolated static func offsets(
            of spans: [SyntaxSpan], in source: String
        ) -> [HighlightSpan] {
            var converted: [HighlightSpan] = []
            converted.reserveCapacity(spans.count)

            let utf16 = source.utf16
            var cursor = source.startIndex
            var offset = 0

            for span in spans {
                offset += utf16.distance(from: cursor, to: span.range.lowerBound)
                let length = utf16.distance(from: span.range.lowerBound, to: span.range.upperBound)
                converted.append(HighlightSpan(
                    range: NSRange(location: offset, length: length), kind: span.kind))
                offset += length
                cursor = span.range.upperBound
            }
            return converted
        }

        /// Line starts in UTF-16 offsets, which is what `NSRange` counts in.
        ///
        /// Characters, not scalars: Swift reads `\r\n` as one, so CRLF counts once per line.
        private nonisolated static func lineStarts(in source: String) -> [Int] {
            var starts = [0]
            var offset = 0
            for character in source {
                offset += character.utf16.count
                if character == "\n" || character == "\r\n" || character == "\r" {
                    starts.append(offset)
                }
            }
            return starts
        }

        // MARK: Painting

        func viewportChanged() {
            paint()
            refreshGutter()
        }

        /// Snapshots which line each visible fragment is and where it sits.
        ///
        /// Never from inside a `draw(_:)`: enumerating fragments forces layout, and forcing it
        /// mid-draw leaves the text view's rendering surfaces uncomposited.
        private func refreshGutter() {
            guard let gutter, let textView,
                  let layoutManager = textView.textLayoutManager,
                  let contentManager = layoutManager.textContentManager,
                  let viewport = layoutManager.textViewportLayoutController.viewportRange
            else { return }

            // Fragments are positioned in the document; the gutter draws in the viewport.
            let scrolled = textView.enclosingScrollView?.contentView.bounds.origin.y ?? 0
            let origin = textView.textContainerInset.height - scrolled

            var rows: [GutterRow] = []
            let document = contentManager.documentRange
            layoutManager.enumerateTextLayoutFragments(
                from: viewport.location, options: [.ensuresLayout]
            ) { fragment in
                guard fragment.rangeInElement.location
                    .compare(viewport.endLocation) != .orderedDescending
                else { return false }

                let offset = contentManager.offset(
                    from: document.location, to: fragment.rangeInElement.location)
                let box = fragment.layoutFragmentFrame
                rows.append(GutterRow(
                    number: self.line(containing: offset),
                    top: origin + box.minY,
                    height: fragment.textLineFragments.first?.typographicBounds.height ?? box.height))
                return true
            }
            // Publishing drives a SwiftUI invalidation, so an unchanged viewport says nothing.
            gutter.update(rows: rows, lineCount: lineStarts.count)
        }

        /// Which line an offset falls on. Bisection, not a newline count per number per frame.
        private func line(containing offset: Int) -> Int {
            var low = 0
            var high = lineStarts.count
            while low < high {
                let middle = (low + high) / 2
                if lineStarts[middle] <= offset {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return max(low, 1)
        }

        /// Colours the visible stretch plus a screen either side, so a slow scroll rarely repaints.
        func paint(force: Bool = false) {
            guard !isPainting,
                  let textView,
                  let layoutManager = textView.textLayoutManager,
                  let contentManager = layoutManager.textContentManager,
                  let viewport = layoutManager.textViewportLayoutController.viewportRange
            else { return }

            let document = contentManager.documentRange
            let visible = NSRange(
                location: contentManager.offset(from: document.location, to: viewport.location),
                length: contentManager.offset(from: viewport.location, to: viewport.endLocation))

            if !force, let painted,
               painted.location <= visible.location,
               painted.upperBound >= visible.upperBound {
                return
            }

            let total = contentManager.offset(from: document.location, to: document.endLocation)
            let lower = max(0, visible.location - Self.paintPadding)
            let upper = min(total, visible.upperBound + Self.paintPadding)
            guard upper > lower else { return }
            let target = NSRange(location: lower, length: upper - lower)
            guard let base = Self.textRange(target, in: contentManager) else { return }

            isPainting = true
            defer { isPainting = false }

            // Reset first, or a span that stopped being a string keeps its old colour forever.
            layoutManager.setRenderingAttributes(
                [.foregroundColor: NSColor(Theme.Syntax.plain)], for: base)

            var index = Self.firstSpan(endingAfter: target.location, in: spans)
            while index < spans.count, spans[index].range.location < target.upperBound {
                let span = spans[index]
                index += 1
                guard span.kind != .plain,
                      let range = Self.textRange(span.range, in: contentManager)
                else { continue }
                layoutManager.setRenderingAttributes(
                    [.foregroundColor: NSColor(Self.colour(for: span.kind))], for: range)
            }
            painted = target
        }

        /// How far past the viewport colour is laid down, in UTF-16 units.
        private static let paintPadding = 4_000

        /// First span not already ended before `offset`. Bisection, not a whole-file filter.
        private static func firstSpan(endingAfter offset: Int, in spans: [HighlightSpan]) -> Int {
            var low = 0
            var high = spans.count
            while low < high {
                let middle = (low + high) / 2
                if spans[middle].range.upperBound <= offset {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return low
        }

        private static func textRange(
            _ range: NSRange, in contentManager: NSTextContentManager
        ) -> NSTextRange? {
            guard let start = contentManager.location(
                    contentManager.documentRange.location, offsetBy: range.location),
                  let end = contentManager.location(start, offsetBy: range.length)
            else { return nil }
            return NSTextRange(location: start, end: end)
        }

        private static func colour(for kind: SyntaxSpan.Kind) -> Color {
            switch kind {
            case .comment: return Theme.Syntax.comment
            case .string: return Theme.Syntax.string
            case .keyword: return Theme.Syntax.keyword
            case .number: return Theme.Syntax.number
            case .type: return Theme.Syntax.type
            case .plain: return Theme.Syntax.plain
            }
        }
    }
}

/// One coloured stretch, in `NSRange` units so it crosses the actor boundary.
struct HighlightSpan: Sendable {
    let range: NSRange
    let kind: SyntaxSpan.Kind
}

// MARK: - Text view

/// `NSTextView` that washes the caret's line and reports its viewport as it moves.
final class CodeTextView: NSTextView {
    weak var coordinator: CodeEditor.Coordinator?

    private var observers: [NSObjectProtocol] = []

    /// Watches the clip view, not the text view: scrolling moves the clip, leaving the text view's
    /// own bounds untouched. Teardown as in the composer — AppKit calls this with no window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        guard window != nil, let clip = enclosingScrollView?.contentView else { return }

        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        let report: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.coordinator?.viewportChanged() }
        }
        observers = [
            NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main,
                using: report),
            NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: clip, queue: .main,
                using: report)
        ]
    }

    /// A quiet wash on the caret's line, suppressed while a selection has its own colour.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        guard selectedRange().length == 0,
              let layoutManager = textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let location = contentManager.location(
                contentManager.documentRange.location, offsetBy: selectedRange().location),
              let fragment = layoutManager.textLayoutFragment(for: location)
        else { return }

        var frame = fragment.layoutFragmentFrame
        frame.origin.x = 0
        frame.origin.y += textContainerInset.height
        frame.size.width = max(bounds.width, frame.width)

        NSColor(Theme.Colors.panel).setFill()
        frame.fill()
    }
}
