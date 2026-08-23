import Foundation
import HarnessCore
import Observation

/// Backing state for the Git workbench.
///
/// Git work is synchronous subprocess calls, so it runs off the main actor and publishes results
/// back. Refreshes are coalesced: a burst of file writes from an agent would otherwise queue a
/// `git status` per change.
@MainActor
@Observable
final class GitPanelModel {
    /// The folder the operator opened. May itself be a repository, or may just contain some.
    let workspace: URL
    /// Repositories found at or under the workspace, nearest first.
    private(set) var repositories: [URL] = []
    /// One line per repository, the ones needing attention first. Nothing is hidden.
    private(set) var summaries: [RepositorySummary] = []
    /// The one the workbench is showing.
    private(set) var activeRepository: URL

    private(set) var status: GitStatus?
    private(set) var unstaged: [GitFileDiff] = []
    private(set) var staged: [GitFileDiff] = []
    private(set) var recentCommits: [GitManager.Commit] = []
    private(set) var isRepository = false
    private(set) var errorMessage: String?
    private(set) var isRefreshing = false
    /// Bumped whenever status or diffs change, so derived views can memoise against it.
    private(set) var revision = 0

    var selectedPath: String?
    /// Paths ticked for a bulk stage or unstage. Independent of `selectedPath`, which drives the
    /// hunk view: an operator inspects one file while queueing several.
    private(set) var checkedPaths: Set<String> = []
    var showStagedSide = false
    var commitDraft = ConventionalCommit(kind: .feat, summary: "")
    private(set) var isDrafting = false
    /// Why the last draft did not arrive. A spinner that stops and leaves the field as it was is
    /// indistinguishable from a button that does nothing.
    private(set) var draftError: String?

    // MARK: Remote

    private(set) var isFetching = false
    private(set) var lastFetchedAt: Date?
    private(set) var remoteError: String?
    /// Set when a pull needs the operator to choose a strategy, because the repository has none.
    var pullStrategyChoiceNeeded = false
    /// Set when a push is waiting on confirmation. Carries what would be published.
    var pendingPush: PendingPush?

    struct PendingPush: Identifiable {
        let branch: String
        let upstream: String?
        let commitCount: Int
        var id: String { branch }
    }

    /// How often to refresh remote-tracking refs while the window is open.
    ///
    /// Matches the interval a developer is used to from an editor. Fetch is read-only — it cannot
    /// touch the working tree or move a branch — but it is still periodic network traffic against
    /// the remote's auth, so it is visible in the panel and can be switched off.
    static let autoFetchInterval: Duration = .seconds(180)
    var isAutoFetchEnabled = true {
        didSet {
            guard isAutoFetchEnabled != oldValue else { return }
            isAutoFetchEnabled ? startAutoFetch() : autoFetchTask?.cancel()
        }
    }

    private var manager: GitManager
    private var refreshTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var autoFetchTask: Task<Void, Never>?

    init(workspace: URL) {
        self.workspace = workspace
        self.activeRepository = workspace
        self.manager = GitManager(workingDirectory: workspace)
        discoverRepositories()
    }

    /// Looks for repositories under the workspace.
    ///
    /// Off the main actor: a container of projects means a directory walk, and the workbench must
    /// not block the interface to do it.
    private func discoverRepositories() {
        discoveryTask?.cancel()
        discoveryTask = Task { [workspace] in
            let found = await Task.detached(priority: .utility) {
                GitRepositoryFinder.repositories(under: workspace)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.repositories = found
                // Prefer the workspace itself when it is a repository; otherwise the first one
                // found, so a container folder still shows something useful.
                if !found.contains(self.activeRepository), let first = found.first {
                    self.select(repository: first)
                }
                self.refreshSummaries()
                self.startAutoFetch()
            }
        }
    }

    /// Recomputes the per-repository lines. One `git status` each, off the main actor.
    func refreshSummaries() {
        let repositories = self.repositories
        guard !repositories.isEmpty else { return }
        Task {
            let summaries = await Task.detached(priority: .utility) {
                RepositorySummary.summarise(repositories: repositories)
            }.value
            await MainActor.run { self.summaries = summaries }
        }
    }

    /// A one-line description of a repository's state, for the picker's second line.
    func summaryLine(for url: URL) -> String? {
        guard let summary = summary(for: url) else { return nil }
        var parts: [String] = []
        if summary.changedFileCount > 0 { parts.append("\(summary.changedFileCount) changed") }
        if summary.ahead > 0 { parts.append("↑\(summary.ahead)") }
        if summary.behind > 0 { parts.append("↓\(summary.behind)") }
        if parts.isEmpty { parts.append("clean") }
        if let branch = summary.branch { parts.append("on \(branch)") }
        return parts.joined(separator: " · ")
    }

    func summary(for url: URL) -> RepositorySummary? {
        summaries.first { $0.url == url }
    }

    var activeSummary: RepositorySummary? { summary(for: activeRepository) }

    // MARK: Remote operations

    /// Fetches once now, then on an interval for as long as the window is open.
    private func startAutoFetch() {
        autoFetchTask?.cancel()
        guard isAutoFetchEnabled else { return }
        autoFetchTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchAll()
                try? await Task.sleep(for: Self.autoFetchInterval)
            }
        }
    }

    /// Updates remote-tracking refs for every repository under the workspace.
    ///
    /// Read-only by construction: `git fetch` cannot change the working tree or move a branch, so
    /// it needs no confirmation. Failures are collected rather than raised — a repository with no
    /// remote, or one whose host is unreachable, must not stop the others.
    func fetchAll() async {
        guard !isFetching, !repositories.isEmpty else { return }
        isFetching = true
        let repositories = self.repositories

        let failures = await Task.detached(priority: .utility) { () -> [String] in
            var failures: [String] = []
            for url in repositories {
                let manager = GitManager(workingDirectory: url)
                do {
                    try manager.fetch()
                } catch {
                    failures.append(url.lastPathComponent)
                }
            }
            return failures
        }.value

        isFetching = false
        lastFetchedAt = Date()
        // Only worth reporting when everything failed; one unreachable remote among several is
        // ordinary and not something to interrupt for.
        remoteError = failures.count == repositories.count && !failures.isEmpty
            ? "Could not fetch: \(failures.joined(separator: ", "))"
            : nil
        refreshSummaries()
        refresh()
    }

    /// Pulls the active repository.
    ///
    /// Returns `false` when the repository has no `pull.rebase` or `pull.ff` of its own: the three
    /// strategies differ in whether they rewrite commits or leave conflict markers behind, so that
    /// is the operator's call rather than a default worth guessing.
    @discardableResult
    func pull() -> Bool {
        // `try?` on a method already returning an optional gives a double optional; flatten it so
        // "the repository has no opinion" and "reading the config failed" both mean ask.
        let configured = (try? manager.configuredPullStrategy()) ?? nil
        guard let strategy = configured else {
            pullStrategyChoiceNeeded = true
            return false
        }
        pull(strategy: strategy)
        return true
    }

    func pull(strategy: GitManager.PullStrategy) {
        pullStrategyChoiceNeeded = false
        performRemote { try $0.pull(strategy: strategy) }
    }

    /// Stages a push for confirmation. Publishing is outward-facing, so it never happens on the
    /// click that asks for it.
    func requestPush() {
        guard let summary = activeSummary, let branch = summary.branch else { return }
        pendingPush = PendingPush(
            branch: branch, upstream: summary.upstream, commitCount: summary.ahead)
    }

    func confirmPush() {
        pendingPush = nil
        performRemote { try $0.push() }
    }

    private func performRemote(_ operation: @escaping @Sendable (GitManager) throws -> Void) {
        let manager = self.manager
        isFetching = true
        Task {
            // The failure is returned rather than captured: a `var` written inside a detached task
            // and read outside it is exactly the race the compiler is pointing at.
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try operation(manager)
                    return nil
                } catch {
                    return String(describing: error)
                }
            }.value

            await MainActor.run {
                self.isFetching = false
                self.remoteError = failure
                self.refreshSummaries()
                self.refresh()
            }
        }
    }

    func select(repository url: URL) {
        guard url != activeRepository else { return }
        remoteError = nil
        activeRepository = url
        manager = GitManager(workingDirectory: url)
        status = nil
        unstaged = []
        staged = []
        recentCommits = []
        selectedPath = nil
        refresh()
    }

    /// A short label for the repository, relative to the workspace when it sits inside it.
    func label(for url: URL) -> String {
        let root = workspace.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == root { return url.lastPathComponent }
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return url.lastPathComponent
    }

    var selectedDiff: GitFileDiff? {
        let source = showStagedSide ? staged : unstaged
        guard let selectedPath else { return source.first }
        return source.first { $0.newPath == selectedPath } ?? source.first
    }

    var advisories: [ConventionalCommit.Advisory] { commitDraft.advisories() }

    var canCommit: Bool {
        !(status?.staged.isEmpty ?? true)
            && !commitDraft.summary.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// What one refresh came back with. `Sendable` so it can cross back from a detached task.
    private enum RefreshOutcome: Sendable {
        case notARepository
        case read(GitStatus, [GitFileDiff], [GitFileDiff], [GitManager.Commit])
        case failed(String)
    }

    /// Carries a git failure's text across the actor hop — the error itself need not be `Sendable`.
    private struct RefreshFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [manager] in
            // Coalesce bursts; an agent editing many files fires one refresh, not twenty.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self.isRefreshing = true }

            // Detached on purpose. `Task {}` inside a `@MainActor` type inherits that isolation,
            // so every one of these `git` calls — each a subprocess this thread waits on — ran on
            // the main thread and stalled the window for as long as the repository took to answer.
            let outcome = await Task.detached(priority: .userInitiated) { () -> RefreshOutcome in
                do {
                    guard try manager.isRepository() else { return .notARepository }
                    let status = try manager.status()
                    return .read(
                        status,
                        try manager.unstagedDiffIncludingUntracked(status: status),
                        try manager.stagedDiff(),
                        try manager.recentCommits(limit: 15))
                } catch {
                    return .failed(String(describing: error))
                }
            }.value

            guard !Task.isCancelled else { return }

            let result: Result<(GitStatus, [GitFileDiff], [GitFileDiff], [GitManager.Commit]), Error>
            switch outcome {
            case .notARepository:
                await MainActor.run {
                    self.isRepository = false
                    self.isRefreshing = false
                }
                return
            case .read(let status, let unstaged, let staged, let commits):
                result = .success((status, unstaged, staged, commits))
            case .failed(let message):
                result = .failure(RefreshFailure(message: message))
            }

            await MainActor.run {
                self.isRefreshing = false
                self.isRepository = true
                switch result {
                case .success(let (status, unstaged, staged, commits)):
                    self.revision &+= 1
                    self.status = status
                    self.unstaged = unstaged
                    self.staged = staged
                    self.recentCommits = commits
                    self.errorMessage = nil
                case .failure(let error):
                    self.errorMessage = String(describing: error)
                }
            }
        }
    }

    func stage(hunk: GitHunk, in diff: GitFileDiff) {
        perform { try $0.stage(diff: diff, hunkIDs: [hunk.id]) }
    }

    func unstage(hunk: GitHunk, in diff: GitFileDiff) {
        perform { try $0.unstage(diff: diff, hunkIDs: [hunk.id]) }
    }

    /// Destructive: throws the change away. Callers must confirm first.
    func discard(hunk: GitHunk, in diff: GitFileDiff) {
        perform { try $0.discard(diff: diff, hunkIDs: [hunk.id]) }
    }

    func stageFile(_ path: String) {
        perform { try $0.stage(paths: [path]) }
    }

    func unstageFile(_ path: String) {
        perform { try $0.unstage(paths: [path]) }
    }

    // MARK: Bulk selection

    func toggleChecked(_ path: String) {
        if checkedPaths.contains(path) {
            checkedPaths.remove(path)
        } else {
            checkedPaths.insert(path)
        }
    }

    func setChecked(_ paths: [String], to isChecked: Bool) {
        if isChecked {
            checkedPaths.formUnion(paths)
        } else {
            checkedPaths.subtract(paths)
        }
    }

    func clearChecked() {
        checkedPaths.removeAll()
    }

    /// The checked paths that are actually on the side being shown.
    ///
    /// Staging a path that is no longer unstaged is a no-op that reads as a bug, so the set is
    /// intersected with the visible list rather than sent whole.
    func checkedPathsOnCurrentSide() -> [String] {
        let visible = Set((showStagedSide ? staged : unstaged).map(\.newPath))
        return checkedPaths.intersection(visible).sorted()
    }

    /// Stages or unstages every checked file in one call, so it is one Git operation and one
    /// refresh rather than one per file.
    func stageChecked() {
        let paths = checkedPathsOnCurrentSide()
        guard !paths.isEmpty else { return }
        perform { try $0.stage(paths: paths) }
        checkedPaths.subtract(paths)
    }

    func unstageChecked() {
        let paths = checkedPathsOnCurrentSide()
        guard !paths.isEmpty else { return }
        perform { try $0.unstage(paths: paths) }
        checkedPaths.subtract(paths)
    }

    func commit() {
        let message = commitDraft.rendered()
        perform { try $0.commit(message: message) }
        commitDraft = ConventionalCommit(kind: .feat, summary: "")
    }

    /// Writes a message for what is staged.
    ///
    /// `fork` is the conversation that made these changes, when there is one: forking it is both
    /// faster and better informed than a cold run, because the context is already warm and the
    /// agent knows why it did what it did. With no live session this falls back to a cold run on
    /// the small model, which is the fast way to summarise a diff from nothing.
    func generateDraft(fork: CommitDraftGenerator.Fork? = nil) {
        guard !isDrafting else { return }
        isDrafting = true
        draftError = nil
        Task { [manager] in
            do {
                let generated = try await CommitDraftGenerator(fork: fork).draft(for: manager)
                await MainActor.run {
                    self.isDrafting = false
                    self.commitDraft = generated
                }
            } catch {
                let message = Self.describe(draftError: error)
                await MainActor.run {
                    self.isDrafting = false
                    self.draftError = message
                }
            }
        }
    }

    func dismissDraftError() {
        draftError = nil
    }

    private static func describe(draftError error: Error) -> String {
        guard let failure = error as? CommitDraftGenerator.Failure else {
            return "The draft did not arrive."
        }
        switch failure {
        case .nothingStaged:
            return "Nothing is staged to describe."
        case .generationFailed(let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "The agent could not be run." : trimmed
        case .unusableResponse:
            return "The agent answered with something that was not a commit message."
        }
    }

    private func perform(_ operation: @escaping @Sendable (GitManager) throws -> Void) {
        Task { [manager] in
            // Detached for the same reason as `refresh()`: staging a hunk is a `git` subprocess,
            // and waiting for it on the main thread freezes the window mid-click.
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try operation(manager)
                    return nil
                } catch {
                    return String(describing: error)
                }
            }.value
            await MainActor.run {
                self.errorMessage = failure
                // The summaries carry the ahead/behind counts, and Push is enabled from `ahead`.
                // Committing moves that number, so a commit that did not re-read it left Push
                // greyed out over commits that were sitting there ready to go — until a fetch,
                // which is a *network* round trip, happened to refresh it as a side effect.
                // `git status` knows the branch is ahead without asking the remote anything.
                self.refreshSummaries()
                self.refresh()
            }
        }
    }
}

/// Backing state for the MCP hub.
@MainActor
@Observable
final class MCPPanelModel {
    var servers: [MCPServerDefinition] = []
    var policy = MCPToolPolicy()
    private(set) var drawer: MCPToolDrawer?
    private(set) var exchanges: [MCPExchange] = []
    private(set) var inspectorSocketPath: String?

    private var inspector: MCPInspector?
    private var pump: Task<Void, Never>?

    /// Rebuilds the drawer from a session handshake.
    ///
    /// `system/init` is re-emitted whenever the tool set changes, so this replaces the drawer
    /// rather than merging into it.
    ///
    /// Guarded on the handshake actually differing: this is called from every snapshot refresh,
    /// so during a stream it was rebuilding the whole drawer a dozen times a second and assigning
    /// it — which invalidates the MCP panel — to say the same thing each time.
    func update(capabilities: SessionInit) {
        guard capabilities != lastCapabilities else { return }
        lastCapabilities = capabilities
        drawer = MCPToolDrawer(capabilities: capabilities, policy: policy)
    }

    func toggle(tool: MCPTool, granted: Bool) {
        if granted {
            policy.grant(tool.qualifiedName)
        } else {
            policy.revoke(tool.qualifiedName)
        }
        if let capabilities = lastCapabilities {
            drawer = MCPToolDrawer(capabilities: capabilities, policy: policy)
        }
    }

    /// The handshake the drawer was last built from, so `toggle` can rebuild it against the same
    /// tool set. `update` is what fills this: the separate `remember` that used to do it had no
    /// callers, which left this nil for the whole session — and so left `toggle` changing the
    /// policy without ever rebuilding the drawer that displays it.
    @ObservationIgnored private var lastCapabilities: SessionInit?

    /// Starts the traffic inspector. Observability only — if it fails, sessions still run and only
    /// inspection is lost.
    func startInspector() {
        guard inspector == nil else { return }
        let path = "/tmp/ah-mcp-\(UUID().uuidString.prefix(8)).sock"
        let inspector = MCPInspector(socketPath: path)
        self.inspector = inspector
        inspectorSocketPath = path

        pump = Task { [weak self] in
            guard let events = try? await inspector.start() else {
                await MainActor.run { self?.inspectorSocketPath = nil }
                return
            }
            for await event in events {
                guard case .exchangeCompleted(let exchange) = event else { continue }
                await MainActor.run {
                    self?.exchanges.insert(exchange, at: 0)
                    if let count = self?.exchanges.count, count > 500 {
                        self?.exchanges.removeLast(count - 500)
                    }
                }
            }
        }
    }

    func stopInspector() {
        let inspector = self.inspector
        Task { await inspector?.stop() }
        pump?.cancel()
        self.inspector = nil
        inspectorSocketPath = nil
    }
}
