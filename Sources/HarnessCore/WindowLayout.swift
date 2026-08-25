import Foundation

/// One window as it stood the last time the app looked: its project, its session tabs, which tab
/// was in front, and where the window sat on screen.
///
/// This is the app's own record rather than AppKit's. System window restoration is switched off by
/// the "Close windows when quitting an application" setting, which is on by default — so a normal
/// quit threw the open projects away while a force quit, which never reaches that code, brought
/// them back. Restoring from a file the app writes itself makes both exits behave the same.
public struct WindowLayout: Codable, Sendable, Hashable, Identifiable {

    /// One session tab: the project it is open on, and the conversation it was showing.
    public struct Tab: Codable, Sendable, Hashable {
        public var workspacePath: String?
        /// The recorded conversation the tab was on, if any. Restored as a transcript, not as a
        /// running agent — the child process died with the app, and starting one per tab at launch
        /// would be a farm of agents nobody asked for.
        public var sessionID: String?

        public var workspace: URL? { workspacePath.map { URL(fileURLWithPath: $0) } }

        public init(workspace: URL?, sessionID: String? = nil) {
            self.workspacePath = workspace?.standardizedFileURL.path
            self.sessionID = sessionID
        }
    }

    public var id: UUID
    public var tabs: [Tab]
    public var selection: Int
    /// `NSStringFromRect` of the window's frame. A string because this type stays free of AppKit.
    public var frame: String?

    public init(id: UUID = UUID(), tabs: [Tab], selection: Int = 0, frame: String? = nil) {
        self.id = id
        self.tabs = tabs
        self.selection = selection
        self.frame = frame
    }

    /// The project this window is open on — the first tab's, since a window is one project.
    public var workspace: URL? { tabs.compactMap(\.workspace).first }

    /// A window with no project is the home page, which restores itself by simply launching.
    public var isRestorable: Bool { workspace != nil }
}

/// Reads and writes the open-window record.
///
/// Kept deliberately small and file-backed: the layout has to survive a force quit, so it is
/// written as it changes rather than at termination, and a half-written file must never take the
/// app's windows with it — a failed decode reads as "nothing to restore".
public struct WindowLayoutStore: Sendable {

    public let url: URL

    /// `~/Library/Application Support/AgentHarness/windows.json` by default.
    public init(url: URL? = nil) {
        if let url {
            self.url = url
            return
        }
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        self.url = base
            .appendingPathComponent("AgentHarness", isDirectory: true)
            .appendingPathComponent("windows.json")
    }

    public func load() -> [WindowLayout] {
        guard let data = try? Data(contentsOf: url),
              let layouts = try? JSONDecoder().decode([WindowLayout].self, from: data)
        else { return [] }
        return layouts.filter(\.isRestorable)
    }

    /// Writes the record, dropping windows with nothing to restore.
    ///
    /// Best-effort by design: a window that cannot be recorded is not a reason to interrupt the
    /// operator, and the next change writes the whole record again anyway.
    public func save(_ layouts: [WindowLayout]) {
        let restorable = layouts.filter(\.isRestorable)
        let manager = FileManager.default
        try? manager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard !restorable.isEmpty else {
            try? manager.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(restorable) else { return }
        // Atomic: a force quit mid-write must not leave a truncated file that reads as no windows.
        try? data.write(to: url, options: .atomic)
    }
}
