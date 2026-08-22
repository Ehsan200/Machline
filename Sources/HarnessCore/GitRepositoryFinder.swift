import Foundation

/// Finds the Git repositories under a directory.
///
/// A project folder is often a container of repositories rather than one itself — a `Projects/`
/// directory, or a workspace holding a handful of services side by side. Treating only the opened
/// folder as the repository leaves the Git workbench empty in exactly those cases.
public enum GitRepositoryFinder {

    /// How far down to look. Deep enough for `workspace/team/service`, shallow enough that opening
    /// a home directory does not turn into a full-disk walk.
    public static let defaultDepth = 3

    /// Directories that never contain a repository worth listing, and are expensive to walk.
    private static let skipped: Set<String> = [
        ".build", ".swiftpm", "node_modules", "DerivedData", ".next", "dist", "build",
        "target", "vendor", "Pods", "__pycache__", ".venv", "venv", ".gradle", ".idea", ".cache"
    ]

    /// Repositories at or under `root`, nearest first.
    ///
    /// Breadth-first, so the shallowest repositories are found first and the depth limit means
    /// what it says. A directory that is itself a repository is not descended into: repositories
    /// nested inside a working tree are submodules or vendored copies, which belong to their
    /// parent rather than beside it.
    public static func repositories(
        under root: URL, maxDepth: Int = defaultDepth
    ) -> [URL] {
        let start = root.standardizedFileURL
        var found: [URL] = []
        var queue: [(url: URL, depth: Int)] = [(start, 0)]

        while !queue.isEmpty {
            let (directory, depth) = queue.removeFirst()

            if isRepository(directory) {
                found.append(directory)
                continue
            }
            guard depth < maxDepth else { continue }

            let children = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []

            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      !skipped.contains(child.lastPathComponent)
                else { continue }
                queue.append((child.standardizedFileURL, depth + 1))
            }
        }
        return found
    }

    /// True when the directory holds a `.git` entry.
    ///
    /// A file rather than a directory is a worktree or submodule pointer, which is still a
    /// repository as far as `git` is concerned.
    public static func isRepository(_ directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".git").path)
    }
}
