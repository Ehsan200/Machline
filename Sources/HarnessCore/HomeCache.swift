import Foundation

/// A remembered snapshot of the landing page.
///
/// Building it means walking every project directory the CLI knows about and parsing the head and
/// tail of a transcript in each — fine once, and a visible pause every time a window opens. The
/// cache is shown immediately and replaced by a fresh read that runs behind it, so the page is
/// never stale for longer than one refresh and never empty while it waits.
public struct HomeCache: Sendable {

    public struct Snapshot: Sendable, Codable {
        public let projects: [Project]
        public let recordedAt: Date

        public init(projects: [Project], recordedAt: Date = Date()) {
            self.projects = projects
            self.recordedAt = recordedAt
        }
    }

    public struct Project: Sendable, Codable {
        public let workspacePath: String
        public let sessions: [HistoricalSession]

        public var workspace: URL { URL(fileURLWithPath: workspacePath) }

        public init(workspace: URL, sessions: [HistoricalSession]) {
            self.workspacePath = workspace.standardizedFileURL.path
            self.sessions = sessions
        }
    }

    public let fileURL: URL

    /// Under Caches rather than Application Support: every value here can be rebuilt from the
    /// transcript store, so losing it costs a refresh and nothing else.
    public init(directory: URL? = nil) {
        let root = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Machline", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Machline")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.fileURL = root.appendingPathComponent("home.json")
    }

    public func read() -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Snapshot.self, from: data)
    }

    /// Best-effort: a cache that cannot be written is a slower next launch, not a failure.
    public func write(_ snapshot: Snapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
