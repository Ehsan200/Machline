import Foundation

/// High-level Git operations for the staging workbench.
public struct GitManager: Sendable {

    public enum Failure: Error, Sendable {
        case nothingStaged
        case emptyCommitMessage
        case noSelectedHunks
        case patchRejected(standardError: String)
        case unsupportedForUntrackedFile(path: String)
    }

    /// Where a set of hunks is being applied.
    public enum StagingTarget: Sendable {
        /// Worktree → index. Diff source is `git diff`.
        case stage
        /// Index → HEAD. Diff source is `git diff --cached`, applied in reverse.
        case unstage
        /// Throw the change away entirely. Applied in reverse against the worktree.
        case discard
    }

    public var runner: GitRunner

    public init(runner: GitRunner) {
        self.runner = runner
    }

    public init(workingDirectory: URL) {
        self.runner = GitRunner(workingDirectory: workingDirectory)
    }

    // MARK: - Status

    public func status() throws -> GitStatus {
        let output = try runner.check([
            "status", "--porcelain=v2", "-z", "--untracked-files=all", "--branch"
        ])
        return GitStatus.parse(porcelainV2: output.standardOutput)
    }

    public func isRepository() throws -> Bool {
        try runner.repositoryRoot() != nil
    }

    // MARK: - Diffs

    private static let diffFlags = ["--no-color", "--no-ext-diff", "-U3"]

    /// Unstaged changes: worktree against the index.
    public func unstagedDiff(paths: [String] = []) throws -> [GitFileDiff] {
        var arguments = ["diff"] + Self.diffFlags
        if !paths.isEmpty { arguments += ["--"] + paths }
        return GitDiffParser.parse(try runner.check(arguments).text)
    }

    /// Staged changes: index against HEAD.
    public func stagedDiff(paths: [String] = []) throws -> [GitFileDiff] {
        var arguments = ["diff", "--cached"] + Self.diffFlags
        if !paths.isEmpty { arguments += ["--"] + paths }
        return GitDiffParser.parse(try runner.check(arguments).text)
    }

    /// A diff for a file git is not yet tracking.
    ///
    /// `git diff` ignores untracked files entirely, so the workbench would otherwise show a new file
    /// as having no content to review. `--no-index` exits 1 when the files differ, which is the
    /// normal case here rather than an error.
    public func untrackedDiff(path: String) throws -> GitFileDiff? {
        let output = try runner.run(
            ["diff", "--no-index"] + Self.diffFlags + ["--", "/dev/null", path])
        guard output.exitCode == 0 || output.exitCode == 1 else {
            throw GitRunner.Failure.commandFailed(
                arguments: ["diff", "--no-index"], exitCode: output.exitCode,
                standardError: output.standardError)
        }
        return GitDiffParser.parse(output.text).first
    }

    /// Everything in the working tree that the index does not have: `git diff` for tracked files,
    /// plus an against-nothing diff for every untracked path.
    ///
    /// `git diff` is blind to untracked files, so a freshly written file would otherwise never
    /// appear in the workbench — and the workbench is the one surface that would have told you it
    /// needs adding. Composed here rather than in the UI so every caller sees the same working
    /// tree.
    public func unstagedDiffIncludingUntracked(status known: GitStatus? = nil) throws
        -> [GitFileDiff] {
        let status = try known ?? self.status()
        var diffs = try unstagedDiff()
        let tracked = Set(diffs.map(\.newPath))
        for file in status.files where file.isUntracked && !tracked.contains(file.path) {
            if let diff = try untrackedDiff(path: file.path) { diffs.append(diff) }
        }
        return diffs.sorted { $0.newPath < $1.newPath }
    }

    // MARK: - Whole-file operations

    public func stage(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try runner.check(["add", "--"] + paths)
    }

    public func unstage(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try runner.check(["restore", "--staged", "--"] + paths)
    }

    /// Throws away working-tree changes. Destructive and irreversible — always confirm first.
    public func discard(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try runner.check(["restore", "--worktree", "--"] + paths)
    }

    /// Marks an untracked file as intended for addition so it appears in `git diff` and becomes
    /// hunk-stageable, matching how `git add -p` handles new files.
    public func markIntentToAdd(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try runner.check(["add", "--intent-to-add", "--"] + paths)
    }

    // MARK: - Hunk-level staging

    /// Applies a subset of a file's hunks.
    ///
    /// The patch reproduces the original header and the selected hunks verbatim; hunk offsets are
    /// not rewritten, because they already describe the pre-image being applied to. `--recount` is
    /// belt and braces for the line counts.
    public func apply(
        diff: GitFileDiff, hunkIDs: Set<Int>, target: StagingTarget
    ) throws {
        guard !hunkIDs.isEmpty else { throw Failure.noSelectedHunks }
        guard let patch = diff.patch(includingHunks: hunkIDs) else { throw Failure.noSelectedHunks }

        var arguments = ["apply", "--recount", "--whitespace=nowarn"]
        switch target {
        case .stage:
            arguments.append("--cached")
        case .unstage:
            arguments += ["--cached", "--reverse"]
        case .discard:
            arguments.append("--reverse")
        }

        let output = try runner.run(arguments, input: Data(patch.utf8))
        guard output.succeeded else {
            throw Failure.patchRejected(standardError: output.standardError)
        }
    }

    public func stage(diff: GitFileDiff, hunkIDs: Set<Int>) throws {
        try apply(diff: diff, hunkIDs: hunkIDs, target: .stage)
    }

    public func unstage(diff: GitFileDiff, hunkIDs: Set<Int>) throws {
        try apply(diff: diff, hunkIDs: hunkIDs, target: .unstage)
    }

    /// Discards selected hunks from the working tree. Destructive.
    public func discard(diff: GitFileDiff, hunkIDs: Set<Int>) throws {
        try apply(diff: diff, hunkIDs: hunkIDs, target: .discard)
    }

    // MARK: - Commit

    /// Creates a commit from the current index.
    ///
    /// Requires a human trigger by construction: nothing in this type commits as a side effect of
    /// staging (README, Runtime).
    @discardableResult
    public func commit(message: String, allowEmpty: Bool = false) throws -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyCommitMessage }
        if !allowEmpty {
            guard try !status().staged.isEmpty else { throw Failure.nothingStaged }
        }

        var arguments = ["commit", "--file=-", "--cleanup=strip"]
        if allowEmpty { arguments.append("--allow-empty") }
        try runner.check(arguments, input: Data(trimmed.utf8))

        return try runner.check(["rev-parse", "HEAD"]).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - History

    public struct Commit: Sendable, Hashable, Identifiable {
        public let id: String
        public let subject: String
        public let author: String
        public let date: String
    }

    public func recentCommits(limit: Int = 20) throws -> [Commit] {
        // ASCII unit/record separators avoid colliding with anything in a commit subject.
        let output = try runner.run([
            "log", "--max-count=\(limit)", "--format=%H%x1f%s%x1f%an%x1f%aI%x1e"
        ])
        guard output.succeeded else { return [] }  // No commits yet.
        return output.text
            .split(separator: "\u{1e}", omittingEmptySubsequences: true)
            .compactMap { record in
                let fields = record
                    .trimmingCharacters(in: .newlines)
                    .split(separator: "\u{1f}", omittingEmptySubsequences: false)
                    .map(String.init)
                guard fields.count == 4 else { return nil }
                return Commit(id: fields[0], subject: fields[1], author: fields[2], date: fields[3])
            }
    }
}

// MARK: - Remote

extension GitManager {

    /// How `git pull` should reconcile a diverged branch.
    public enum PullStrategy: String, Sendable, CaseIterable {
        /// Refuses rather than inventing history. The only one that cannot leave a half-finished
        /// state behind.
        case fastForwardOnly
        case rebase
        case merge

        var arguments: [String] {
            switch self {
            case .fastForwardOnly: return ["--ff-only"]
            case .rebase: return ["--rebase"]
            case .merge: return ["--no-rebase"]
            }
        }
    }

    /// What the repository itself says `pull` should do.
    ///
    /// `nil` means the repository has no opinion — neither `pull.rebase` nor `pull.ff` is set — and
    /// the caller must ask rather than pick, because the three outcomes differ in whether they can
    /// rewrite commits or leave conflict markers in the working tree.
    public func configuredPullStrategy() throws -> PullStrategy? {
        if let rebase = try configValue("pull.rebase") {
            // `pull.rebase` also takes `merges`/`interactive`, which are still rebases.
            return ["false", "no", "0"].contains(rebase.lowercased()) ? .merge : .rebase
        }
        if let fastForward = try configValue("pull.ff") {
            return fastForward.lowercased() == "only" ? .fastForwardOnly : .merge
        }
        return nil
    }

    private func configValue(_ key: String) throws -> String? {
        // `--get` exits 1 when the key is unset, which is an answer rather than a failure.
        let output = try runner.run(["config", "--get", key])
        let value = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.succeeded && !value.isEmpty ? value : nil
    }

    /// Updates remote-tracking refs. Reads only — it cannot change the working tree or any branch.
    public func fetch() throws {
        try runner.check(["fetch", "--prune"])
    }

    public func pull(strategy: PullStrategy) throws {
        try runner.check(["pull"] + strategy.arguments)
    }

    /// Publishes the current branch.
    ///
    /// A branch with no upstream is pushed with `--set-upstream` to the default remote: the
    /// alternative is an error telling the operator to run a command Machline could have run.
    public func push() throws {
        let status = try status()
        if status.branch.hasUpstream {
            try runner.check(["push"])
            return
        }
        guard let head = status.branch.head, !status.branch.isDetached else {
            throw Failure.patchRejected(
                standardError: "HEAD is detached — check out a branch before pushing.")
        }
        try runner.check(["push", "--set-upstream", "origin", head])
    }

    /// True when the repository has anything the operator has not committed.
    public func hasUncommittedChanges() throws -> Bool {
        !(try status()).isClean
    }
}
