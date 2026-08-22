import Foundation

/// The projects the operator has opened, most recent first.
///
/// Stored as bookmarks rather than paths, so an entry survives the directory being renamed or
/// moved. They are plain bookmarks, not security-scoped ones: the app is not sandboxed, so it has
/// no need to re-acquire access, and `.withSecurityScope` without the matching entitlement can fail
/// to mint — which would drop projects silently. An entry that no longer resolves is dropped on
/// read rather than shown dead.
@MainActor
struct RecentProjects {
    private static let key = "recentProjects"
    private static let limit = 12

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Resolved, still-existing project directories, newest first.
    func load() -> [URL] {
        let stored = defaults.array(forKey: Self.key) as? [Data] ?? []
        var resolved: [URL] = []
        var surviving: [Data] = []

        for bookmark in stored {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark,
                bookmarkDataIsStale: &isStale)
            else { continue }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }

            resolved.append(url)
            // A stale bookmark still resolved, so re-mint it rather than dropping the entry.
            surviving.append(isStale ? (Self.bookmark(for: url) ?? bookmark) : bookmark)
        }

        if surviving.count != stored.count {
            defaults.set(surviving, forKey: Self.key)
        }
        return resolved
    }

    /// Records a project, moving it to the front if it was already known.
    func record(_ url: URL) {
        guard let bookmark = Self.bookmark(for: url) else { return }
        var entries = defaults.array(forKey: Self.key) as? [Data] ?? []

        // De-duplicate by resolved path: two bookmarks to the same directory are not byte-equal.
        entries.removeAll { existing in
            var isStale = false
            let resolved = try? URL(
                resolvingBookmarkData: existing,
                bookmarkDataIsStale: &isStale)
            return resolved?.standardizedFileURL == url.standardizedFileURL
        }

        entries.insert(bookmark, at: 0)
        defaults.set(Array(entries.prefix(Self.limit)), forKey: Self.key)
    }

    func forget(_ url: URL) {
        var entries = defaults.array(forKey: Self.key) as? [Data] ?? []
        entries.removeAll { existing in
            var isStale = false
            let resolved = try? URL(
                resolvingBookmarkData: existing,
                bookmarkDataIsStale: &isStale)
            return resolved?.standardizedFileURL == url.standardizedFileURL
        }
        defaults.set(entries, forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }

    private static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData()
    }
}
