import Foundation

/// A one-line view of a repository, cheap enough to compute for every repo under a workspace.
public struct RepositorySummary: Sendable, Hashable, Identifiable {
    public let url: URL
    public let branch: String?
    public let upstream: String?
    /// Commits the local branch has that the remote does not.
    public let ahead: Int
    /// Commits the remote has that the local branch does not, as of the last fetch.
    public let behind: Int
    public let changedFileCount: Int

    public var id: URL { url }
    public var isDirty: Bool { changedFileCount > 0 }
    public var isUnpushed: Bool { ahead > 0 }
    /// Anything at all for the operator to do here.
    public var needsAttention: Bool { isDirty || isUnpushed || behind > 0 }

    public init(url: URL, status: GitStatus) {
        self.url = url
        self.branch = status.branch.head
        self.upstream = status.branch.upstream
        self.ahead = status.branch.ahead
        self.behind = status.branch.behind
        self.changedFileCount = status.files.count
    }

    /// Summaries for every repository under a workspace, ones needing attention first.
    ///
    /// Nothing is hidden: a clean repository stays reachable, it just sorts below the ones with
    /// work outstanding. Repositories that cannot be read at all are dropped, since a row that
    /// shows nothing is worse than no row.
    public static func summarise(
        repositories: [URL], executable: URL = URL(fileURLWithPath: "/usr/bin/git")
    ) -> [RepositorySummary] {
        repositories
            .compactMap { url in
                let manager = GitManager(runner: GitRunner(workingDirectory: url, executable: executable))
                guard let status = try? manager.status() else { return nil }
                return RepositorySummary(url: url, status: status)
            }
            .sorted { lhs, rhs in
                if lhs.needsAttention != rhs.needsAttention { return lhs.needsAttention }
                // Within a group, the busiest first, then alphabetically so the order is stable.
                if lhs.changedFileCount != rhs.changedFileCount {
                    return lhs.changedFileCount > rhs.changedFileCount
                }
                return lhs.url.lastPathComponent < rhs.url.lastPathComponent
            }
    }
}
