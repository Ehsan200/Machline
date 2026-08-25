import Foundation

/// The directory trees a session is entitled to write in.
///
/// Deliberately *not* the hook payload's `cwd`. That field is wherever the agent happens to be
/// standing, and it moves: a session rooted at a monorepo reports a package subdirectory once the
/// agent works there. Judging containment by it calls an ordinary sibling-package edit — `apps/web`
/// from `apps/api` — a write outside the workspace, which is both wrong on the sheet and, in auto
/// mode, a prompt for something the operator had already agreed to.
///
/// The honest boundary is what the session was launched with: its working directory, plus any
/// directory explicitly handed to it through `--add-dir`.
public struct SessionWorkspace: Sendable, Hashable {

    /// Resolved, standardised roots. Order is not meaningful; the first is used as the anchor for
    /// relative paths when a payload carries no usable `cwd`.
    public let roots: [URL]

    public init(roots: [URL]) {
        // Symlinks are resolved once, here: `$TMPDIR` lives under `/var`, which is a link to
        // `/private/var`, and an unresolved root would never match the path the agent asks for.
        self.roots = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }

    /// The trees a launched session may write in.
    ///
    /// - Parameter includingAdditionalDirectories: whether `--add-dir` grants count as workspace.
    ///   They do for *describing* a write (an attachment the operator handed over is not an escape),
    ///   but not for auto-approving one — see `AutoApproval`.
    public init(
        configuration: SessionConfiguration, includingAdditionalDirectories: Bool = true
    ) {
        self.init(roots: includingAdditionalDirectories
            ? [configuration.workingDirectory] + configuration.additionalDirectories
            : [configuration.workingDirectory])
    }

    /// The project root alone, with `--add-dir` grants excluded.
    public var projectOnly: SessionWorkspace {
        SessionWorkspace(roots: roots.isEmpty ? [] : [roots[0]])
    }

    public var isEmpty: Bool { roots.isEmpty }

    /// Whether a tool's path lands inside the workspace.
    ///
    /// `path` may be relative, in which case it is resolved against `base` (the payload's `cwd`)
    /// before comparison, and `..` cannot walk out of a root because resolution happens first.
    public func contains(path: String, base: String? = nil) -> Bool {
        guard !roots.isEmpty else { return false }
        let anchor: URL = if let base, !base.isEmpty {
            URL(fileURLWithPath: base, isDirectory: true)
        } else {
            roots[0]
        }
        let resolved = URL(fileURLWithPath: path, relativeTo: anchor)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return roots.contains { Self.contains(root: $0, path: resolved) }
    }

    /// Compares on path components, so `/work` does not appear to contain `/workspace`.
    private static func contains(root: URL, path: URL) -> Bool {
        let rootParts = root.pathComponents
        let parts = path.pathComponents
        return parts.count > rootParts.count && Array(parts.prefix(rootParts.count)) == rootParts
    }

    /// The workspace to judge a payload against: this one, or — when the session's roots are
    /// unknown — the payload's own `cwd`, which is the best available guess.
    func resolved(for payload: HookPayload) -> SessionWorkspace {
        guard isEmpty else { return self }
        guard !payload.cwd.isEmpty else { return self }
        return SessionWorkspace(roots: [URL(fileURLWithPath: payload.cwd, isDirectory: true)])
    }
}

extension HookPayload {
    /// Every path this tool call would write. Empty means the write shape is unrecognised, which is
    /// a reason to ask rather than to assume.
    var writePaths: [String] {
        ["file_path", "notebook_path"].compactMap { toolInput[$0]?.stringValue }
    }
}
