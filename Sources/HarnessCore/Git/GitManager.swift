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

    /// The working tree against HEAD, untracked files included.
    ///
    /// Neither of the two diffs above answers "how does this file differ from the last commit".
    /// `unstagedDiff` stops at the index, so anything already staged reads as unchanged, and
    /// `stagedDiff` numbers its lines against the index rather than against the file on disk. Using
    /// either for the editor's margin marks lines that are not the ones that changed.
    public func workingTreeDiff(
        status known: GitStatus? = nil, paths: [String] = []
    ) throws -> [GitFileDiff] {
        // A repository with no commits has no HEAD to diff against, and `git diff HEAD` fails
        // rather than reporting everything as new.
        let output = try runner.run(
            ["diff", "HEAD"] + Self.diffFlags + (paths.isEmpty ? [] : ["--"] + paths))
        guard output.exitCode == 0 else {
            return try unstagedDiffIncludingUntracked(status: known)
        }
        var diffs = GitDiffParser.parse(output.text)
        let tracked = Set(diffs.map(\.displayPath))
        let wanted = Set(paths)

        // `status` is only here to find untracked files, which cost a subprocess of their own. A
        // named file that already appeared in the diff is tracked, so there is nothing to look for.
        if !wanted.isEmpty, wanted.isSubset(of: tracked) {
            return diffs.sorted { $0.displayPath < $1.displayPath }
        }
        let status = try known ?? self.status()
        for file in status.files
        where file.isUntracked && !tracked.contains(file.path)
            && (wanted.isEmpty || wanted.contains(file.path)) {
            if let diff = try untrackedDiff(path: file.path) { diffs.append(diff) }
        }
        return diffs.sorted { $0.displayPath < $1.displayPath }
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
        let tracked = Set(diffs.map(\.displayPath))
        for file in status.files where file.isUntracked && !tracked.contains(file.path) {
            if let diff = try untrackedDiff(path: file.path) { diffs.append(diff) }
        }
        return diffs.sorted { $0.displayPath < $1.displayPath }
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

    /// Puts paths back to what HEAD holds, in the index and the working tree both.
    ///
    /// Wider than `discard(paths:)`, which restores from the *index* and so leaves a staged change
    /// standing: undoing a file means the file, not the half of it Git has not been told about yet.
    /// A path HEAD has never seen is *deleted* by this, which is why callers route new files through
    /// `GitRevertPlan` instead. Destructive and irreversible — always confirm first.
    public func revert(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try runner.check(["restore", "--source=HEAD", "--staged", "--worktree", "--"] + paths)
    }

    /// Drops paths from the index, leaving the files on disk untracked.
    ///
    /// The only way to unstage a file staged as new when HEAD holds no version of it — and the only
    /// one at all before the first commit, where `git restore --staged` cannot resolve HEAD.
    public func forget(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try runner.check(["rm", "--cached", "--force", "--quiet", "--"] + paths)
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
    /// staging (docs/RUNTIME.md).
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

    func configValue(_ key: String) throws -> String? {
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

    /// Publishes the current branch to its own remote.
    ///
    /// A branch with no upstream is pushed with `--set-upstream` to the resolved push target: the
    /// alternative is an error telling the operator to run a command Machline could have run. That
    /// target used to be the literal `origin`, which is wrong in a fork that calls its remotes
    /// `upstream` and `fork`, and wrong again wherever `remote.pushDefault` says otherwise.
    ///
    /// Pushing to more than one remote goes through `push(branch:to:setUpstreamOn:)`, which reports
    /// per remote instead of throwing on the first refusal.
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
        guard let target = pushTarget(for: head) else {
            throw Failure.patchRejected(
                standardError: "This repository has no remote to push to.")
        }
        try runner.check(["push", "--set-upstream", target, head])
    }

    /// True when the repository has anything the operator has not committed.
    public func hasUncommittedChanges() throws -> Bool {
        !(try status()).isClean
    }
}
