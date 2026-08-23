import Foundation
import HarnessCore
import Observation
import SwiftUI

/// One open file, and when it goes back to disk.
///
/// The buffer lives here, not in the view: the view is a sheet, torn down for reasons that have
/// nothing to do with the file. Saving is automatic — a departure from the rest of the app, and
/// safe only because `TextBuffer` refuses to write over a file that moved underneath it.
@MainActor
@Observable
final class EditorModel {

    private(set) var buffer: TextBuffer?
    /// Why the file could not be opened, as a sentence.
    private(set) var failure: String?
    private(set) var isLoading = true
    /// Why the last write did not happen. Cleared by the next one that does.
    private(set) var saveFailure: String?
    /// Set when the file moved underneath the buffer and only the operator can settle it.
    private(set) var conflict: EditConflict.Decision?
    /// Bumped on a load or reload. Typing never bumps it, or the caret jumps to the top.
    private(set) var revision = 0
    /// Bumped per write. The editor ends its undo run on each, so ⌘Z steps through typing pauses.
    private(set) var saveGeneration = 0

    var isAutosaveEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAutosaveEnabled, forKey: Self.autosaveKey)
            if isAutosaveEnabled { scheduleAutosave() }
        }
    }

    private var autosave: Task<Void, Never>?
    private var watch: Task<Void, Never>?

    /// Short enough that the margin keeps up with typing; long enough that a burst is one write.
    private static let autosaveDelay = Duration.milliseconds(250)
    private static let autosaveKey = "editorAutosaveEnabled"

    /// Layout is no longer paid per line, but the whole file is still held in a `String`.
    private nonisolated static let byteLimit = 4 * 1_048_576

    init() {
        // Absent means never set; `bool(forKey:)` alone would read a first run as "off".
        isAutosaveEnabled = UserDefaults.standard.object(forKey: Self.autosaveKey) as? Bool ?? true
    }

    var isDirty: Bool { buffer?.isDirty ?? false }

    func load(_ url: URL) async {
        isLoading = true
        let outcome = await Task.detached(priority: .userInitiated) {
            () -> Result<TextBuffer, TextBufferError> in
            do {
                return .success(try TextBuffer.load(url, byteLimit: Self.byteLimit))
            } catch let error as TextBufferError {
                return .failure(error)
            } catch {
                return .failure(.unreadable)
            }
        }.value

        switch outcome {
        case .success(let opened):
            buffer = opened
            failure = nil
            conflict = nil
            revision += 1
            startWatching(url)
        case .failure(let error):
            buffer = nil
            failure = error.message
        }
        isLoading = false
    }

    /// Watches for the other writer.
    ///
    /// The agent edits the same tree, so a file can move under the buffer at any moment. A clean
    /// buffer just follows it; a dirty one has to ask, because either answer loses work.
    private func startWatching(_ url: URL) {
        watch?.cancel()
        watch = Task { [weak self] in
            for await _ in FileWatcher.changes(to: url) {
                guard let self else { return }
                self.noteDiskChanged()
            }
        }
    }

    private func noteDiskChanged() {
        guard let buffer else { return }
        // Our own save re-stamps the buffer, so the write we just made reads as `.unchanged` here
        // and the watcher's report of it costs nothing.
        switch buffer.conflictDecision() {
        case .unchanged:
            if conflict != nil { conflict = nil }
        case .reload:
            reloadFromDisk()
        case .conflict:
            autosave?.cancel()
            conflict = .conflict
        case .vanished:
            autosave?.cancel()
            conflict = .vanished
        }
    }

    /// Adopts what is on disk, discarding unsaved edits. The editor is told to reinstall the text
    /// by way of `revision`.
    func reloadFromDisk() {
        guard var current = buffer else { return }
        do {
            try current.reload()
            buffer = current
            conflict = nil
            saveFailure = nil
            revision += 1
        } catch let error as TextBufferError {
            failure = error.message
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Keeps what is on screen, overwriting whatever arrived.
    func overwriteDisk() {
        save(force: true)
        conflict = nil
    }

    /// The path resolved to nothing, which is not the same as failing to open.
    func reportMissing(_ path: String) {
        buffer = nil
        failure = "Could not find \(path) on disk."
        isLoading = false
    }

    /// The view holds the live text; this keeps the buffer level with it for the next save.
    func edited(_ text: String) {
        guard buffer != nil else { return }
        buffer?.replaceContents(with: text)
        saveFailure = nil
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        autosave?.cancel()
        guard isAutosaveEnabled, isDirty else { return }
        autosave = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Writes now. `force` is the operator overruling a changed file, never the timer.
    func save(force: Bool = false) {
        autosave?.cancel()
        guard var current = buffer else { return }
        do {
            if try current.save(force: force) { saveGeneration += 1 }
            buffer = current
            saveFailure = nil
            conflict = nil
        } catch TextBufferError.conflicted {
            // Not a failure to report as text: it has two answers and only the operator has one.
            conflict = .conflict
        } catch let error as TextBufferError {
            saveFailure = error.message
        } catch {
            saveFailure = error.localizedDescription
        }
    }

    /// Writes before the editor goes away, since the pending timer and the watch go with it.
    func flush() {
        autosave?.cancel()
        autosave = nil
        watch?.cancel()
        watch = nil
        if isDirty, conflict == nil { save() }
    }
}
