import Foundation
import Testing
@testable import HarnessCore

/// The record that makes a normal quit restore what a force quit already did. Its edges: what is
/// worth restoring, what a half-written file does, and that an emptied workspace stays empty.
struct WindowLayoutTests {

    private func makeStore() throws -> (WindowLayoutStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("machline-window-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (WindowLayoutStore(url: directory.appendingPathComponent("windows.json")), directory)
    }

    private func layout(
        _ path: String, sessionID: String? = nil, selection: Int = 0
    ) -> WindowLayout {
        WindowLayout(
            tabs: [WindowLayout.Tab(workspace: URL(fileURLWithPath: path), sessionID: sessionID)],
            selection: selection)
    }

    @Test("Windows round-trip through the store")
    func windowsRoundTrip() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let stored = [
            WindowLayout(
                tabs: [
                    WindowLayout.Tab(workspace: URL(fileURLWithPath: "/repo"), sessionID: "abc"),
                    WindowLayout.Tab(workspace: URL(fileURLWithPath: "/repo"))
                ],
                selection: 1,
                frame: "{{10, 20}, {800, 600}}"),
            layout("/other")
        ]
        store.save(stored)

        let loaded = store.load()
        #expect(loaded == stored)
        #expect(loaded.first?.workspace?.path == "/repo")
        #expect(loaded.first?.tabs.count == 2)
        #expect(loaded.first?.selection == 1)
        #expect(loaded.first?.frame == "{{10, 20}, {800, 600}}")
    }

    /// A window on the home page has nothing to put back, and recording it would restore a blank
    /// window over the projects that mattered.
    @Test("A window with no project is not stored")
    func projectlessWindowsAreDropped() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        store.save([WindowLayout(tabs: [WindowLayout.Tab(workspace: nil)]), layout("/repo")])
        #expect(store.load().count == 1)
        #expect(store.load().first?.workspace?.path == "/repo")
    }

    /// Closing every project window and then quitting must not bring them back.
    @Test("Saving nothing clears the record")
    func savingNothingClearsTheRecord() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        store.save([layout("/repo")])
        #expect(!store.load().isEmpty)

        store.save([])
        #expect(store.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
    }

    /// The file is written as the app runs, so a kill can catch it mid-write. Reading rubbish must
    /// read as "nothing to restore" rather than take the launch with it.
    @Test("An unreadable record restores nothing")
    func unreadableRecordRestoresNothing() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data("{ not json".utf8).write(to: store.url)
        #expect(store.load().isEmpty)
    }

    @Test("A missing record restores nothing")
    func missingRecordRestoresNothing() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(store.load().isEmpty)
    }
}
