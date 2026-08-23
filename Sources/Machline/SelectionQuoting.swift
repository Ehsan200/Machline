import AppKit
import SwiftUI

/// Notices that the operator has selected part of the conversation, so quoting it can be offered as
/// a control rather than only as a menu item nobody finds.
///
/// SwiftUI reports neither that a `Text` selection exists nor what is in it, so the selection is
/// read the only way AppKit offers: `copy:` down the responder chain, with the pasteboard put back
/// exactly as it was found. That is the same trick `AppModel.quoteSelection` uses — this only
/// arranges for it to happen at the moment a selection is finished, so the answer is already in
/// hand when the button is pressed.
///
/// The probe runs after a *drag* or a shifted key, never on a plain click: a click clears the
/// selection anyway, and touching the pasteboard on every click in the window would be rude to
/// whatever the operator has copied.
@MainActor
@Observable
final class TextSelectionWatcher {

    /// What is selected in the conversation, or `nil` when nothing is.
    private(set) var selection: String?

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var isDragging = false

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyUp]
        ) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        selection = nil
    }

    func clear() {
        selection = nil
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            isDragging = false
            // The click that begins the next selection ends the last one.
            if selection != nil { selection = nil }
        case .leftMouseDragged:
            isDragging = true
        case .leftMouseUp:
            guard isDragging else { return }
            isDragging = false
            scheduleRead()
        case .keyUp:
            // Shift-arrow and ⌘A are the keyboard ways to select; nothing else changes a selection.
            guard event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
            else { return }
            scheduleRead()
        default:
            break
        }
    }

    /// A turn later: AppKit finishes the selection after the event that made it, and reading during
    /// the event itself returns what was selected a moment ago.
    private func scheduleRead() {
        Task { @MainActor in
            let taken = await PasteboardProbe.readSelection()
            if taken != selection { selection = taken }
        }
    }
}

/// Reads the window's text selection through `copy:`, and puts the pasteboard back.
///
/// The only route AppKit offers to a `Text` selection, and therefore the one both the ⌘⇧' command
/// and `TextSelectionWatcher` take. Everything on the pasteboard is restored, not just the string:
/// `copy:` replaces whatever was there, so an operator who had an image on the clipboard would
/// otherwise lose it to a drag of the mouse across the transcript.
@MainActor
enum PasteboardProbe {

    /// Above this, the clipboard is left alone entirely — holding a copy of something enormous to
    /// hand back a sentence is the wrong trade, and the ⌘⇧' command still works.
    private static let restorableBytes = 8 * 1024 * 1024

    static func readSelection() async -> String? {
        // Editing a draft is not quoting the conversation, and the composer answers `copy:` too.
        if let responder = NSApp.keyWindow?.firstResponder as? NSTextView, responder.isEditable {
            return nil
        }

        let board = NSPasteboard.general
        guard let saved = snapshot(board) else { return nil }
        let mark = board.changeCount
        guard NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) else { return nil }

        // The responder handling `copy:` may write after the send returns.
        await Task.yield()

        guard board.changeCount != mark else { return nil }
        let taken = board.string(forType: .string)
        restore(saved, to: board)

        let trimmed = taken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private typealias Item = [NSPasteboard.PasteboardType: Data]

    /// Everything currently on the pasteboard, or `nil` when it is too big to hold.
    private static func snapshot(_ board: NSPasteboard) -> [Item]? {
        var total = 0
        var items: [Item] = []
        for item in board.pasteboardItems ?? [] {
            var stored: Item = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                guard total <= restorableBytes else { return nil }
                stored[type] = data
            }
            items.append(stored)
        }
        return items
    }

    private static func restore(_ items: [Item], to board: NSPasteboard) {
        board.clearContents()
        guard !items.isEmpty else { return }
        board.writeObjects(items.map { stored in
            let item = NSPasteboardItem()
            for (type, data) in stored { item.setData(data, forType: type) }
            return item
        })
    }
}
