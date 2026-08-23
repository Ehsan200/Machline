import Foundation
import HarnessCore
import Observation
import SwiftUI

/// A project the operator has opened.
struct Workspace: Identifiable, Hashable {
    let id = UUID()
    var url: URL
    var name: String { url.lastPathComponent }
}

/// The bridge between `HarnessCore`'s actors and SwiftUI.
///
/// Everything the views read lives here on the main actor. The core stays UI-free: this type is the
/// only place that folds `SessionUpdate` and `ApprovalEvent` streams into observable state.
@MainActor
@Observable
final class AppModel: Identifiable {

    /// Identity for the window's tab list. Sessions are compared by object, not by value.
    nonisolated let id = UUID()

    /// Persisted settings are loaded here rather than by whoever happens to present the model.
    ///
    /// Every tab is its own `AppModel`, so anything loaded only by the first one — the slash
    /// command list, the approval mode, the recent projects — was simply missing everywhere else.
    init() {
        loadPersistedSettings()
        // Installing an update means quitting, which on top of a running agent throws away the
        // turn it was mid-way through. The update model asks before it takes that decision itself.
        updates.isHostBusy = { [weak self] in self?.sessionState.isRunning ?? false }
        // Somewhere for an automatic check to land. Held weakly there, so this does not outlive
        // the window it belongs to.
        UpdateScheduler.shared.register(self)
    }

    private func loadPersistedSettings() {
        allRecentProjects = recents.load()
        machineConfiguration = MachineConfiguration.read()
        loadAutoApproval()
        loadSlashCommands()
        loadIsolation()
        loadBilling()
        loadCustomTitles()
        terminalShell = UserDefaults.standard.string(forKey: "terminalShell")
    }

    // MARK: Session

    private(set) var session: AgentSession?
    private(set) var graph = AgentGraph()
    private(set) var selectedAgentID: String?
    private(set) var sessionState: SessionState = .idle
    private(set) var transcriptRevision = 0

    enum SessionState: Equatable {
        case idle
        case starting
        case running
        case exited(status: Int32)
        case failed(String)

        var isRunning: Bool { self == .running }

        /// The single word the composer's status strip shows.
        var label: String {
            switch self {
            case .idle: return "Idle"
            case .starting: return "Starting"
            case .running: return "Working"
            case .exited(let status): return status == 0 ? "Done" : "Exited \(status)"
            case .failed: return "Failed"
            }
        }
    }

    // MARK: Approvals

    /// Requests awaiting the operator. The head of this queue drives the modal sheet.
    private(set) var pendingApprovals: [PendingApproval] = []
    private(set) var auditLog: [AuditEntry] = []
    /// Raised when the runtime cancelled an approval hook, meaning a command may have run
    /// unapproved. This is an incident banner, not a transient warning.
    private(set) var failOpenIncidents: [String] = []
    /// Raised when the approval channel itself fails. While this is set, the gate is degraded.
    private(set) var approvalChannelFailure: String?

    /// The permission rules the operator's own `~/.claude/settings.json` imposes.
    ///
    /// Only in force when sessions run `inherited`, and they outrank this app: a `deny` there
    /// refuses a command the operator has just approved here, which is what made an approval look
    /// like it did nothing. Read once per model so the panel and the sheet can say so.
    private(set) var machineConfiguration = MachineConfiguration.none

    /// The rules that actually apply to the sessions this model starts.
    var enforcedMachineConfiguration: MachineConfiguration {
        isolation == .inherited ? machineConfiguration : .none
    }

    /// The machine denylist entry that would refuse this command, if any.
    func machineDenial(for command: String?) -> String? {
        guard let command else { return nil }
        return enforcedMachineConfiguration.deniesBashCommand(command)
    }

    /// Opens `~/.claude/settings.json` in whatever handles it, so the rules can be edited where
    /// they actually live. Machline does not rewrite that file: it is the operator's, it is shared
    /// with every other Claude session on this machine, and reformatting it behind their back to
    /// delete one line is not a trade worth making.
    func openMachineSettings() {
        let url = MachineConfiguration.defaultSettingsURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Re-reads the machine's rules, for after they have been edited by hand.
    func reloadMachineConfiguration() {
        machineConfiguration = MachineConfiguration.read()
    }

    struct AuditEntry: Identifiable {
        let id = UUID()
        let at: Date
        let toolName: String
        let summary: String
        let verdict: ApprovalDecision.Verdict
        let provenance: ApprovalDecision.Provenance
        /// The decision's own words. A call nobody read is the one whose reason matters most, so
        /// the panel shows this verbatim rather than paraphrasing the provenance.
        let reason: String
    }

    // MARK: Workspace

    var workspace: Workspace?
    /// The model this session runs on. `nil` leaves `--model` off the command line entirely, so
    /// the CLI falls back to whatever the operator configured for it.
    var model: String?
    var promptDraft: String = ""

    /// The models offered in the composer's Model cell.
    ///
    /// The CLI takes an alias for the latest model in a family, or a full model name. Aliases are
    /// listed first because they are what an operator normally wants; a pinned name is for holding
    /// a session on one exact model.
    static let knownModels = [
        "opus", "sonnet", "haiku", "fable",
        "claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5", "claude-fable-5"
    ]

    /// What the Model cell shows when no model is pinned.
    static let defaultModelLabel = "default"

    var modelLabel: String { model ?? Self.defaultModelLabel }

    /// The model the running session was actually launched with.
    ///
    /// `--model` is a launch flag, so picking a different one cannot affect a session already in
    /// flight. Keeping the two apart lets the composer say so instead of appearing to have applied
    /// a change that did nothing.
    private(set) var activeModel: String??

    var isModelPendingRestart: Bool {
        guard let activeModel, sessionState.isRunning else { return false }
        return activeModel != model
    }

    /// Recently opened projects, newest first, minus the ones the operator removed.
    var recentProjects: [URL] { allRecentProjects.filter { !hidden.contains($0) } }
    private var allRecentProjects: [URL] = []
    private let recents = RecentProjects()
    private let hidden = HiddenProjects.shared

    // MARK: Completions

    /// Suggestions for the token being typed, or empty when there is nothing to suggest.
    private(set) var completions: [Completion] = []
    private(set) var selectedCompletion = 0
    /// Project files and folders, for `@` mentions.
    private(set) var fileIndex: [FileIndex.Entry] = []
    /// The commands the last handshake advertised, cached across launches so the composer has
    /// something to offer before a session has started.
    private(set) var cachedSlashCommands: [String] = []

    /// The commands this session actually has.
    ///
    /// A running session is authoritative: its handshake reflects the model, the settings sources,
    /// and the plugins that session was launched with. The cache is only a stand-in until then.
    var slashCommands: [String] {
        let live = graph.root?.capabilities?.slashCommands ?? []
        return live.isEmpty ? cachedSlashCommands : live
    }

    /// True while the list on offer is last session's rather than this one's.
    var isSlashCommandListStale: Bool {
        (graph.root?.capabilities?.slashCommands ?? []).isEmpty && !cachedSlashCommands.isEmpty
    }

    private static let slashCommandsKey = "slashCommands"

    var isShowingCompletions: Bool { !completions.isEmpty }

    /// Recomputes suggestions for the draft. Cheap enough to run on every keystroke: the file
    /// index is already in memory and the match is a single pass over it.
    func updateCompletions() {
        guard let trigger = CompletionTrigger.detect(in: promptDraft) else {
            completions = []
            selectedCompletion = 0
            return
        }

        switch trigger.kind {
        case .slashCommand:
            // Machline's own commands are offered alongside the CLI's, marked so it is clear which
            // never leave the app.
            let local = CompletionMatcher
                .rank(LocalCommand.allCases.map(\.rawValue), query: trigger.query)
                .compactMap(LocalCommand.init(rawValue:))
                .map { Completion(
                    kind: .slashCommand, insert: "/\($0.rawValue)",
                    label: "/\($0.rawValue)", detail: $0.summary) }

            // A name Machline owns is answered here and never reaches the CLI, so the CLI's own
            // entry for it is dropped rather than listed alongside — `/context`, `/agents`,
            // `/mcp` and several more appear in both sets, and offering both put the same command
            // in the list twice with only one of them doing anything.
            let owned = Set(LocalCommand.allCases.map(\.rawValue))
            completions = local + CompletionMatcher
                .rank(slashCommands.filter { !owned.contains($0) }, query: trigger.query)
                .map { Completion(kind: .slashCommand, insert: "/\($0)", label: "/\($0)") }
        case .file:
            completions = CompletionMatcher
                .rank(fileIndex, query: trigger.query, key: \.path)
                .map { entry in
                    Completion(
                        kind: entry.isDirectory ? .directory : .file,
                        insert: "@\(entry.mention)",
                        label: entry.isDirectory ? entry.name + "/" : entry.name,
                        detail: entry.path)
                }
        }
        selectedCompletion = min(selectedCompletion, max(0, completions.count - 1))
    }

    func moveCompletionSelection(by offset: Int) {
        guard !completions.isEmpty else { return }
        let count = completions.count
        selectedCompletion = ((selectedCompletion + offset) % count + count) % count
    }

    /// Replaces the token being typed with the highlighted suggestion.
    func acceptCompletion() {
        guard let trigger = CompletionTrigger.detect(in: promptDraft),
              completions.indices.contains(selectedCompletion)
        else { return }

        let chosen = completions[selectedCompletion]
        // A trailing space so the next token starts clean and the popover closes.
        promptDraft.replaceSubrange(trigger.start..., with: chosen.insert + " ")
        completions = []
        selectedCompletion = 0
    }

    /// Turns dropped files into `@` mentions.
    ///
    /// Paths inside the project are written relative to it, which is both shorter to read and what
    /// the agent resolves against; anything outside keeps its absolute path.
    ///
    /// A file the agent's process cannot reach is copied somewhere it can first — see
    /// `AttachmentStore`. A dragged screenshot is handed over in a directory macOS scopes to this
    /// app alone, so mentioning it where it lies gives the agent a path that reads back as a
    /// permission error.
    func mentionDroppedFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let root = workspace?.url.standardizedFileURL.path
        let mentions = urls.map { dropped -> String in
            let url = Self.reachable(dropped)
            let path = url.standardizedFileURL.path
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)

            var mention = path
            if let root, path.hasPrefix(root + "/") {
                mention = String(path.dropFirst(root.count + 1))
            }
            // A trailing slash is how a folder mention reads, matching the completion list.
            if exists, isDirectory.boolValue, !mention.hasSuffix("/") { mention += "/" }
            return "@" + mention
        }

        // Separated from whatever is already typed, and left with a trailing space so the
        // completion list does not open on the path just inserted.
        if !promptDraft.isEmpty, !promptDraft.hasSuffix(" ") { promptDraft += " " }
        promptDraft += mentions.joined(separator: " ") + " "
        dismissCompletions()
    }

    /// The dropped file, or a copy of it the agent is able to open.
    ///
    /// Best-effort: a copy that fails leaves the original path in the prompt, which is what would
    /// have been there anyway. Directories are left alone — a drop box only ever hands over files,
    /// and copying a tree because it sits in `/tmp` would be a surprise.
    private static func reachable(_ url: URL) -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              AttachmentStore.isUnreachableByAgent(url)
        else { return url }

        let store = AttachmentStore()
        guard let copy = try? store.adopt(url) else { return url }
        store.prune()
        return copy
    }

    func dismissCompletions() {
        completions = []
        selectedCompletion = 0
    }

    /// Walks the project for `@` mentions. Off the main actor: a large tree takes a moment.
    private func buildFileIndex(for workspace: URL) {
        fileIndex = []
        Task {
            let paths = await Task.detached(priority: .utility) {
                FileIndex.build(for: workspace)
            }.value
            await MainActor.run { self.fileIndex = paths }
        }
    }

    private func loadSlashCommands() {
        cachedSlashCommands = UserDefaults.standard.stringArray(forKey: Self.slashCommandsKey) ?? []
    }

    /// Records the commands the CLI actually advertised. Replaces rather than merges: the
    /// handshake is re-emitted when the command set changes.
    private func rememberSlashCommands(_ commands: [String]) {
        guard !commands.isEmpty, commands != cachedSlashCommands else { return }
        cachedSlashCommands = commands
        UserDefaults.standard.set(commands, forKey: Self.slashCommandsKey)
    }

    // MARK: Auto-approval

    /// What the gate answers without asking. Persisted, because an operator who turned it on does
    /// not want it silently reverting on relaunch — and because it must be visible in the UI at all
    /// times, which it is in the composer's Approvals cell.
    var autoApproval: AutoApproval = .manual {
        didSet {
            guard autoApproval != oldValue else { return }
            persistAutoApproval()
            if let session {
                Task { await session.setAutoApproval(autoApproval) }
            }
        }
    }

    /// Allow rules currently in force, so "Always allow" stops being invisible state.
    private(set) var activeRules: [ApprovalRule] = []

    private static let autoApprovalKey = "autoApproval"
    private static let isolationKey = "sessionIsolation"
    private static let billingKey = "sessionBilling"

    /// Which account sessions bill against.
    ///
    /// Defaults to the signed-in subscription, with the CLI's credential-override variables
    /// removed from the child's environment so a stray `ANTHROPIC_API_KEY` cannot quietly move
    /// billing to the API without anything changing on screen.
    var billing: SessionConfiguration.Billing = .subscription {
        didSet {
            guard billing != oldValue else { return }
            UserDefaults.standard.set(billing.rawValue, forKey: Self.billingKey)
        }
    }

    private func loadBilling() {
        guard let raw = UserDefaults.standard.string(forKey: Self.billingKey),
              let stored = SessionConfiguration.Billing(rawValue: raw)
        else { return }
        billing = stored
    }

    /// What sessions inherit from the machine's own Claude configuration.
    ///
    /// Defaults to `.inherited`, so sessions behave like `claude` in a terminal. That is a
    /// deliberate trade: the approval gate still applies, but the harness can no longer state what
    /// tool surface a session had, because ambient MCP servers join unannounced.
    var isolation: SessionConfiguration.Isolation = .inherited {
        didSet {
            guard isolation != oldValue else { return }
            UserDefaults.standard.set(isolation.rawValue, forKey: Self.isolationKey)
        }
    }

    private func loadIsolation() {
        guard let raw = UserDefaults.standard.string(forKey: Self.isolationKey),
              let stored = SessionConfiguration.Isolation(rawValue: raw)
        else { return }
        isolation = stored
    }

    private func persistAutoApproval() {
        guard let data = try? JSONEncoder().encode(autoApproval) else { return }
        UserDefaults.standard.set(data, forKey: Self.autoApprovalKey)
    }

    private func loadAutoApproval() {
        guard let data = UserDefaults.standard.data(forKey: Self.autoApprovalKey),
              let stored = try? JSONDecoder().decode(AutoApproval.self, from: data)
        else { return }
        // Re-run through the initialiser so a stored ceiling above the cap is clamped rather
        // than trusted.
        autoApproval = AutoApproval(
            bashCeiling: stored.bashCeiling,
            workspaceFileEdits: stored.workspaceFileEdits,
            holdsOutwardCommands: stored.holdsOutwardCommands)
    }

    func refreshRules() {
        guard let session else {
            activeRules = []
            return
        }
        Task {
            let store = await session.policy()
            await MainActor.run { self.activeRules = store.rules }
        }
    }

    func removeRule(_ rule: ApprovalRule) {
        guard let session else { return }
        Task {
            await session.remove(ruleID: rule.id)
            await MainActor.run { self.refreshRules() }
        }
    }

    // MARK: Conversation history

    /// The CLI's own recorded conversations for the open project, most recently active first.
    private(set) var projectSessions: [HistoricalSession] = []
    private(set) var isLoadingHistory = false
    /// The recorded session the running session was resumed from, if any.
    private(set) var resumedFrom: HistoricalSession?
    /// The conversation that already happened, shown above the live timeline. Resuming does not
    /// replay, so without this a resumed session looks empty.
    private(set) var replay: [ReplayEntry] = []
    /// Context occupancy carried over from the resumed transcript, until a turn completes here.
    private(set) var recordedUsage: SessionHistory.RecordedUsage?
    private(set) var isLoadingReplay = false
    private let history = SessionHistory()
    private static let titlesKey = "sessionTitles"
    /// Titles the operator typed, by session id. A transcript's first prompt is a serviceable
    /// name; a name they chose is a better one, and it must survive relaunch.
    private var customTitles: [String: String] = [:]
    private let archive = SessionArchive()
    /// Archived conversations, hidden from the main list until asked for.
    private(set) var archivedSessions: [HistoricalSession] = []
    /// Raised when an archive or delete fails, so a silent no-op is impossible.
    var archiveError: String?

    // MARK: Usage

    /// The most recent `result` frame. Context accounting is read from this rather than
    /// accumulated, because a `result` reports the window as the runtime sees it now.
    private(set) var lastTurn: TurnResult?
    /// Cost accumulates across turns; a single `result` only reports its own turn.
    private(set) var cumulativeCostUSD: Double = 0
    private(set) var sessionID: UUID?

    // MARK: Diff modal

    /// The changed file whose complete diff is open, if any.
    var diffModalPath: DiffTarget?

    // MARK: Updates

    /// Checking for a new build, fetching it, installing it. Its own model — see `UpdateModel`.
    let updates = UpdateModel()

    /// This build's version, as stamped by the release workflow. Forwarded because it is the app's
    /// identity rather than update state: `/status` and the tab strip both want it.
    var appVersion: String { UpdateModel.appVersion }

    // MARK: Shell pane

    /// Whether the shell pane is showing.
    var isTerminalVisible = false
    /// The shell to run, or `nil` for the account's login shell. Persisted.
    var terminalShell: String? {
        didSet {
            guard terminalShell != oldValue else { return }
            UserDefaults.standard.set(terminalShell, forKey: "terminalShell")
            restartTerminal()
        }
    }
    /// Bumped to replace an exited shell with a fresh one.
    private(set) var terminalGeneration = 0

    /// True once the shell has been opened in this session, so the pane can stay mounted.
    private(set) var hasOpenedTerminal = false

    func toggleTerminal() {
        isTerminalVisible.toggle()
        if isTerminalVisible { hasOpenedTerminal = true }
    }

    /// Ends the shell and unmounts the pane.
    func closeTerminal() {
        isTerminalVisible = false
        hasOpenedTerminal = false
    }

    func restartTerminal() {
        terminalGeneration &+= 1
    }

    /// The file open in the viewer, if any.
    var viewerPath: DiffTarget?
    /// The command whose report is on screen, if any.
    var reportCommand: LocalCommand?
    /// A run-panel section a command asked to open.
    var focusedPanelSection: RunPanelSection?

    /// Kept for `/status`, which reads the account before presenting.
    var isShowingStatus: Bool {
        get { reportCommand != nil }
        set { if !newValue { reportCommand = nil } }
    }
    /// Who the CLI says is signed in. Read on demand — it costs a process spawn.
    private(set) var accountStatus: AccountStatus?
    private(set) var isLoadingAccount = false

    func refreshAccountStatus() {
        guard !isLoadingAccount else { return }
        isLoadingAccount = true
        Task {
            let status = await Task.detached(priority: .userInitiated) {
                AccountStatus.read()
            }.value
            await MainActor.run {
                self.accountStatus = status
                self.isLoadingAccount = false
            }
        }
    }

    /// Prompts already sent, newest last, for the arrow keys to walk.
    private(set) var promptHistory: [String] = []
    /// Where the arrow keys currently sit in `promptHistory`. `nil` means "at the live draft".
    private var historyIndex: Int?
    /// What was typed before history navigation started, restored on the way back down.
    private var draftBeforeHistory: String?

    /// Walks prompt history, shell style. Returns false when there is nowhere to go, so the caller
    /// lets the key fall through to ordinary caret movement.
    func navigateHistory(backward: Bool) -> Bool {
        guard !promptHistory.isEmpty else { return false }

        if backward {
            let next = (historyIndex ?? promptHistory.count) - 1
            guard next >= 0 else { return true }
            if historyIndex == nil { draftBeforeHistory = promptDraft }
            historyIndex = next
            promptDraft = promptHistory[next]
            return true
        }

        guard let current = historyIndex else { return false }
        let next = current + 1
        if next < promptHistory.count {
            historyIndex = next
            promptDraft = promptHistory[next]
        } else {
            // Past the newest entry is the draft that was interrupted, not an empty box.
            historyIndex = nil
            promptDraft = draftBeforeHistory ?? ""
            draftBeforeHistory = nil
        }
        return true
    }

    /// Records a sent prompt so the arrow keys can walk back to it.
    func recordHistory(_ text: String) {
        historyIndex = nil
        draftBeforeHistory = nil
        // Consecutive duplicates are noise to walk back through.
        guard promptHistory.last != text else { return }
        promptHistory.append(text)
        if promptHistory.count > 200 { promptHistory.removeFirst() }
    }

    struct DiffTarget: Identifiable, Hashable {
        let path: String
        var id: String { path }
    }

    /// When the selected agent last became busy, for the activity line's elapsed counter.
    private(set) var busySince: Date?
    /// Coalesces streaming updates. Partial-message frames arrive dozens per second; rebuilding
    /// the snapshot for each would spend the whole main thread on layout.
    @ObservationIgnored private var lastStreamingRefresh = Date.distantPast
    /// How long a streaming burst is allowed to coalesce for.
    private static let streamingInterval: TimeInterval = 0.08
    /// Set when a streaming update was throttled away, cleared by the refresh that renders it.
    @ObservationIgnored private var streamingDirty = false
    /// The timer that renders a throttled burst's tail once its window closes.
    @ObservationIgnored private var streamingFlush: Task<Void, Never>?

    /// Serialises snapshot refreshes. Reading the snapshot suspends on the session actor, and
    /// Swift actors are reentrant and not FIFO: two refreshes in flight can resume in either
    /// order and write a stale snapshot over a fresh one, which reads on screen as the transcript
    /// stepping backwards a frame. One runs at a time; whatever arrives meanwhile is coalesced
    /// into a single follow-up pass instead of queueing a task per frame.
    @ObservationIgnored private var graphRefreshInFlight = false
    @ObservationIgnored private var graphRefreshPending = false
    /// Whether the coalesced work includes something structural, which also costs a `git status`.
    @ObservationIgnored private var graphRefreshNeedsGit = false

    // The memos below are filled from view bodies. `@Observable` treats a plain stored property as
    // observable state, so writing one mid-body is a change made during a view update: SwiftUI
    // invalidates, re-runs the body, fills the memo again, and the window never settles. They are
    // caches, not state — nothing should redraw because one was populated.

    /// Memoised `sessionChanges`, invalidated by the Git panel's revision counter.
    @ObservationIgnored
    private var changesCache: (revision: Int, diffs: [GitFileDiff], statuses: [String: GitFileStatus])?

    /// Memoised `timelineEvents`, invalidated by the transcript's revision counter.
    @ObservationIgnored
    private var timelineCache: (revision: Int, agentID: String?, events: [TimelineEvent])?

    /// When each agent last produced a transcript entry, for the relative time in the rail.
    @ObservationIgnored private var agentUpdatedAt: [String: Date] = [:]
    @ObservationIgnored private var lastTranscriptCount: [String: Int] = [:]

    // MARK: Diagnostics

    private(set) var malformedLines: [String] = []
    private(set) var standardError: [String] = []

    /// How many stderr chunks the operator has already waved away. Counted in chunks rather than
    /// lines because that is what arrives: stderr is yielded as raw writes, not split for us.
    private var acknowledgedErrorChunks = 0

    /// What the CLI has written to stderr and the operator has not dismissed.
    ///
    /// The CLI puts real warnings here — a flag it no longer honours, a settings file it could not
    /// read, a model it silently swapped — and they were only reachable through `/status`, which
    /// nobody opens while everything still looks fine. Surfaced as a banner instead.
    ///
    /// Split, trimmed and de-duplicated: one warning repeated on every turn is one line, not forty.
    var pendingWarnings: [String] {
        var seen = Set<String>()
        return standardError.dropFirst(acknowledgedErrorChunks)
            .flatMap { $0.split(separator: "\n") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func dismissWarnings() {
        acknowledgedErrorChunks = standardError.count
    }

    // MARK: Panels

    var git: GitPanelModel?
    var mcp = MCPPanelModel()

    private var pump: Task<Void, Never>?

    // MARK: - Derived

    var agents: [AgentNode] { graph.orderedNodes() }

    var selectedAgent: AgentNode? {
        guard let selectedAgentID else { return graph.root }
        return graph.node(id: selectedAgentID) ?? graph.root
    }

    var currentApproval: PendingApproval? { pendingApprovals.first }

    /// The gate is degraded whenever the approval channel is down or a fail-open has been observed.
    var isGateDegraded: Bool {
        approvalChannelFailure != nil || !failOpenIncidents.isEmpty
    }

    func select(agentID: String) {
        selectedAgentID = agentID
    }

    // MARK: - Timeline disclosure

    /// Which timeline rows the operator has opened or closed, keyed by the entry they belong to.
    ///
    /// The timeline is a `LazyVStack`: a row scrolled out of the viewport is torn down and the
    /// `@State` inside it goes with it. Opening a tool row and then receiving a few frames —
    /// which scrolls the timeline to its foot — was enough to lose it, which is why the
    /// disclosure control looked like it worked only sometimes. Held here, a row's state belongs
    /// to the conversation rather than to whichever view currently exists.
    private var rowExpansion: [RowKey: Bool] = [:]

    /// Live entries carry a UUID; replayed ones are numbered by their position in the file, which
    /// is only unique within the conversation currently loaded — hence two cases rather than one
    /// shared key space.
    enum RowKey: Hashable {
        case live(UUID)
        case replay(Int)
    }

    /// `whenUnset` carries the row's default — errors and blocks open themselves.
    func isRowExpanded(_ key: RowKey, whenUnset fallback: Bool = false) -> Bool {
        rowExpansion[key] ?? fallback
    }

    func setRow(_ key: RowKey, expanded: Bool) {
        rowExpansion[key] = expanded
    }

    func toggleRow(_ key: RowKey, whenUnset fallback: Bool = false) {
        rowExpansion[key] = !isRowExpanded(key, whenUnset: fallback)
    }

    /// A binding for the rows that take one, so the disclosure control stays unchanged.
    func rowExpansionBinding(_ key: RowKey, whenUnset fallback: Bool = false) -> Binding<Bool> {
        Binding(
            get: { self.isRowExpanded(key, whenUnset: fallback) },
            set: { self.setRow(key, expanded: $0) })
    }

    // MARK: - Lifecycle

    /// Re-reads the recent-project list, which another window may have added to.
    func loadRecentProjects() {
        allRecentProjects = recents.load()
    }

    func open(workspace url: URL) {
        // Opening a real project ends whatever made this a scratch window.
        if workspace?.url != url, !ScratchWorkspace().url.standardizedFileURL.path
            .elementsEqual(url.standardizedFileURL.path) {
            isScratch = false
        }
        workspace = Workspace(url: url)
        git = GitPanelModel(workspace: url)
        git?.refresh()
        // Opening a removed project is how it comes back: the operator asked for this directory by
        // name, so hiding it from the list they are now looking at would be the app arguing.
        hidden.show(url)
        recents.record(url)
        allRecentProjects = recents.load()
        refreshHistory()
        buildFileIndex(for: url)
    }

    /// Every project the CLI has history for, recents first.
    ///
    /// The project menu used to offer only what this app had opened, which on a fresh install is
    /// nothing — while the machine may hold eighty projects the CLI already knows about.
    var knownProjects: [URL] { allKnownProjects.filter { !hidden.contains($0) } }
    private var allKnownProjects: [URL] = []

    func loadKnownProjects() {
        guard allKnownProjects.isEmpty else { return }
        Task { [history] in
            let known = await Task.detached(priority: .utility) {
                history.knownWorkspaces().map(\.url)
            }.value
            await MainActor.run {
                var seen = Set(self.allRecentProjects.map(\.standardizedFileURL))
                var ordered = self.allRecentProjects
                for url in known where seen.insert(url.standardizedFileURL).inserted {
                    ordered.append(url)
                }
                self.allKnownProjects = ordered
            }
        }
    }

    /// Recent work across every project, for a window with nothing open yet.
    var homeProjects: [(workspace: URL, sessions: [HistoricalSession])] {
        allHomeProjects.filter { !hidden.contains($0.workspace) }
    }
    private var allHomeProjects: [(workspace: URL, sessions: [HistoricalSession])] = []
    private(set) var isLoadingHome = false

    private let homeCache = HomeCache()

    /// Shows the remembered landing page immediately, then refreshes it behind that.
    ///
    /// Walking every project the CLI knows about is a visible pause; showing last time's answer
    /// first means the window is useful the instant it opens, and the refresh replaces it a moment
    /// later. Only ever called for an empty window.
    func loadHome() {
        guard !isLoadingHome else { return }

        if allHomeProjects.isEmpty, let cached = homeCache.read() {
            allHomeProjects = cached.projects.map { ($0.workspace, $0.sessions) }
        }

        isLoadingHome = allHomeProjects.isEmpty
        Task { [history, homeCache] in
            let found = await Task.detached(priority: .userInitiated) {
                history.recentWork()
            }.value
            let snapshot = HomeCache.Snapshot(
                projects: found.map { HomeCache.Project(workspace: $0.workspace, sessions: $0.sessions) })
            await Task.detached(priority: .utility) { homeCache.write(snapshot) }.value

            await MainActor.run {
                self.allHomeProjects = found
                self.isLoadingHome = false
            }
        }
    }

    /// True while this window is a scratch chat rather than work on a project.
    private(set) var isScratch = false

    /// Opens the scratch workspace and starts a chat in it.
    ///
    /// Chat only: the session launches with an empty tool set, so it can read nothing, write
    /// nothing, and run nothing. That is what makes it safe to ask an unrelated question without
    /// choosing a project first — there is no working tree for a tool to wander into.
    func openScratch(startingWith prompt: String? = nil) {
        let scratch = ScratchWorkspace()
        guard let url = try? scratch.prepare() else {
            archiveError = "Could not create the scratch workspace."
            return
        }
        isScratch = true
        open(workspace: url)
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            promptDraft = prompt
        }
        submit()
    }

    /// Opens a project and resumes one of its conversations, in this window.
    func openFromHome(workspace: URL, session: HistoricalSession) {
        open(workspace: workspace)
        resume(session)
    }

    /// Today's conversations, then yesterday's, then the rest. Only today's group opens by
    /// default — a rail listing two hundred rows hides the handful that matter.
    ///
    /// The running session is grouped by when it was last *typed into*, not by what its transcript
    /// said when the rail was built: resuming an old conversation and sending a prompt puts it under
    /// Today, where the operator just put it.
    var sessionGroups: [SessionGroup] {
        SessionGroup.group(projectSessions.map { session in
            guard let liveActivityAt, isLive(session), session.lastActivityAt < liveActivityAt
            else { return session }
            return session.restamped(lastActivityAt: liveActivityAt)
        })
    }

    /// When the running session last had a prompt sent to it from here.
    ///
    /// The transcript on disk is only reread when the child exits, so this is the only record of
    /// activity in a session that is still going. `nil` until this window sends something.
    private var liveActivityAt: Date?

    /// The conversation a commit draft should fork: the one running here, or failing that the
    /// project's most recently active one.
    ///
    /// Forking beats a cold run twice over — the agent already knows why it made these changes,
    /// and the provider's cache already holds the conversation, so the drafting call sends a short
    /// prompt instead of the whole patch. `nil` means there is nothing to fork and the draft runs
    /// cold on the small model.
    var commitDraftFork: CommitDraftGenerator.Fork? {
        guard let workspace = workspace?.url else { return nil }
        guard let id = liveSessionID ?? projectSessions.first?.id, !id.isEmpty else { return nil }
        return CommitDraftGenerator.Fork(sessionID: id, workingDirectory: workspace)
    }

    /// The name to show, preferring one the operator typed.
    func title(for session: HistoricalSession) -> String {
        customTitles[session.id] ?? session.title
    }

    func hasCustomTitle(_ session: HistoricalSession) -> Bool {
        customTitles[session.id] != nil
    }

    /// Renames a conversation. An empty name restores the transcript's own first prompt.
    func rename(_ session: HistoricalSession, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            customTitles.removeValue(forKey: session.id)
        } else {
            customTitles[session.id] = trimmed
        }
        UserDefaults.standard.set(customTitles, forKey: Self.titlesKey)
    }

    private func loadCustomTitles() {
        customTitles = UserDefaults.standard.dictionary(forKey: Self.titlesKey)
            as? [String: String] ?? [:]
    }

    /// Rereads the CLI's transcript store for the open project.
    ///
    /// Off the main actor: it stats a directory and reads the head of each transcript, and the
    /// store grows with every session the operator has ever run.
    func refreshHistory() {
        guard let workspace else {
            projectSessions = []
            return
        }
        isLoadingHistory = true
        Task { [history, url = workspace.url] in
            let found = await Task.detached(priority: .utility) {
                history.sessions(forWorkspace: url)
            }.value
            await MainActor.run {
                self.projectSessions = found
                self.isLoadingHistory = false
            }
        }
        Task { [archive, url = workspace.url] in
            let archived = await Task.detached(priority: .utility) {
                archive.sessions(forWorkspace: url)
            }.value
            await MainActor.run { self.archivedSessions = archived }
        }
    }

    /// Moves a conversation out of the CLI's store. Reversible.
    func archiveSession(_ session: HistoricalSession) {
        perform(on: session) { try archive.archive(session) }
    }

    func restoreSession(_ session: HistoricalSession) {
        perform(on: session) { try archive.restore(session, to: history) }
    }

    /// Permanently removes a conversation. Callers must confirm first — there is no undo, and no
    /// trash step, because the CLI would simply re-list a file that came back.
    func deleteSession(_ session: HistoricalSession) {
        perform(on: session) { try archive.delete(session) }
    }

    private func perform(
        on session: HistoricalSession, _ operation: () throws -> Void
    ) {
        // A session being edited out from under a running child would leave the transcript and the
        // live process disagreeing about what happened.
        guard !isLive(session) else {
            archiveError = "Stop this session before archiving or deleting it."
            return
        }
        do {
            try operation()
            archiveError = nil
            refreshHistory()
        } catch {
            archiveError = String(describing: error)
        }
    }

    /// Continues a recorded conversation.
    ///
    /// Forking branches into a new session id and leaves the original transcript untouched;
    /// otherwise the CLI appends to it. Either way this is a fresh child process, so the agent tree
    /// is rebuilt from the resumed session's own frames.
    func resume(_ session: HistoricalSession, fork: Bool = false) {
        guard workspace != nil else { return }
        if self.session != nil { stop() }
        resumedFrom = session
        // A resumed conversation continues on the model that wrote it, unless this tab has already
        // been pinned to something else.
        if model == nil, let recorded = session.model { model = recorded }
        loadReplay(of: session)
        startSession(resuming: SessionConfiguration.Resume(sessionID: session.id, fork: fork))
    }

    /// Reads a recorded conversation for display. Off the main actor: transcripts run to megabytes.
    private func loadReplay(of session: HistoricalSession) {
        replay = []
        // Replay keys are positions in the file, so they mean nothing once a different
        // conversation is loaded into this tab.
        rowExpansion = rowExpansion.filter { key, _ in
            if case .replay = key { return false }
            return true
        }
        recordedUsage = nil
        isLoadingReplay = true
        Task { [history] in
            let loaded = await Task.detached(priority: .userInitiated) {
                (entries: history.replay(of: session), usage: history.lastUsage(of: session))
            }.value
            await MainActor.run {
                self.replay = loaded.entries
                self.recordedUsage = loaded.usage
                self.isLoadingReplay = false
                self.transcriptRevision &+= 1
            }
        }
    }

    /// Takes a project out of every list the app shows, and keeps it out.
    ///
    /// Two stores, because the lists have two sources: the recent list is this app's own and is
    /// simply forgotten, while the project menu also draws on the CLI's transcript directory, which
    /// this app does not own and will not delete. The removal is recorded instead, and the lists
    /// filter against it. Nothing on disk is touched — neither the project nor its conversations.
    func removeProject(_ url: URL) {
        recents.forget(url)
        allRecentProjects = recents.load()
        hidden.hide(url)
    }

    /// Puts every removed project back in the lists.
    func restoreRemovedProjects() {
        hidden.showAll()
    }

    /// How many projects are being kept out of the lists, for the control that offers them back.
    var removedProjectCount: Int { hidden.count }

    func clearRecentProjects() {
        recents.clear()
        allRecentProjects = []
    }

    /// Restarts the session so a launch-time change — a different model — takes effect.
    func restartSession() {
        guard let session else {
            startSession()
            return
        }
        Task {
            await session.stop()
            self.pump?.cancel()
            self.session = nil
            self.sessionState = .idle
            self.startSession()
        }
    }

    /// What this window is showing, published back so `openWindow` can raise it rather than
    /// opening a second window against the same session.
    var windowIdentity: WindowTarget {
        WindowTarget(
            workspace: workspace?.url,
            resumeSessionID: session == nil && resumedFrom == nil ? nil : liveSessionID)
    }

    /// The tab group this window belongs to: one per project.
    ///
    /// macOS groups windows sharing a `tabbingIdentifier`, so sessions of a project become tabs
    /// while a different project opens its own window.
    var tabbingIdentifier: String {
        workspace.map { "machline.project.\($0.url.standardizedFileURL.path)" }
            ?? "machline.project.none"
    }

    /// The window's title: the project, and the session inside it once one is identifiable.
    var windowTitle: String {
        guard let workspace else { return "Machline" }
        if let resumedFrom { return "\(workspace.name) — \(resumedFrom.title)" }
        if let short = shortSessionID, session != nil { return "\(workspace.name) — \(short)" }
        return workspace.name
    }

    /// Waits for an in-flight history read to land, so a window opened to resume a session can
    /// find it in the list.
    func waitForHistory() async {
        for _ in 0..<40 where isLoadingHistory {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func startSession() {
        resumedFrom = nil
        startSession(resuming: nil)
    }

    private func startSession(resuming resume: SessionConfiguration.Resume?) {
        guard session == nil, let workspace else { return }
        sessionState = .starting
        graph = AgentGraph()
        selectedAgentID = nil
        lastTurn = nil
        cumulativeCostUSD = 0
        // A session that has not been typed into yet is grouped by its transcript, not by the
        // moment it was opened — see `sessionGroups`.
        liveActivityAt = nil
        agentUpdatedAt = [:]
        lastTranscriptCount = [:]
        // Diagnostics describe a process. Carrying the last one's stderr into a restart makes the
        // banner accuse a session that has not said anything yet.
        standardError = []
        malformedLines = []
        acknowledgedErrorChunks = 0

        do {
            let (session, id) = try Self.makeSession(
                workspace: workspace.url, model: model, mcp: mcp, resume: resume,
                autoApproval: autoApproval, isolation: isolation, billing: billing,
                isChatOnly: isScratch)
            self.session = session
            self.sessionID = id
            self.activeModel = .some(model)
            pump = Task { [weak self] in
                await self?.consume(session: session)
            }
        } catch {
            sessionState = .failed(String(describing: error))
        }
    }

    private static func makeSession(
        workspace: URL, model: String?, mcp: MCPPanelModel,
        resume: SessionConfiguration.Resume? = nil,
        autoApproval: AutoApproval = .manual,
        isolation: SessionConfiguration.Isolation = .inherited,
        billing: SessionConfiguration.Billing = .subscription,
        isChatOnly: Bool = false
    ) throws -> (AgentSession, UUID) {
        let sessionID = UUID()
        let runDirectory = try ApprovalBroker.defaultRunDirectory()
        let support = runDirectory.deletingLastPathComponent()
        let settingsURL = support.appendingPathComponent("session-\(sessionID.uuidString).json")

        var configuration = SessionConfiguration(
            workingDirectory: workspace, sessionID: sessionID, model: model,
            // Without this the CLI emits only assembled blocks, so a reply appears all at once
            // after the pause rather than as it is written.
            includePartialMessages: true,
            isolation: isolation,
            billing: billing,
            resume: resume)

        // An empty tool set is the whole point of a scratch chat, and it is spelled `--tools ""` —
        // a bare `--tools` would swallow the flag after it (Finding 5).
        if isChatOnly { configuration.tools = [] }

        if !mcp.servers.isEmpty {
            let mcpURL = support.appendingPathComponent("mcp-\(sessionID.uuidString).json")
            try MCPConfiguration(servers: mcp.servers).write(
                to: mcpURL,
                proxyPath: BundledHelpers.mcpProxyPath,
                inspectorSocketPath: mcp.inspectorSocketPath)
            configuration.mcpConfigPath = mcpURL
        }
        // A grant list only means anything when the tool surface is known, which is exactly what
        // an inherited session gives up.
        let granted = mcp.policy.allowedToolArguments()
        if !granted.isEmpty, isolation == .sealed {
            configuration.additionalArguments = ["--allowedTools"] + granted
        }

        let session = try AgentSession(
            configuration: configuration,
            helperPath: BundledHelpers.approvalHelperPath,
            socketPath: try ApprovalBroker.socketPath(forSession: sessionID, in: runDirectory),
            settingsPath: settingsURL,
            autoApproval: autoApproval)
        return (session, sessionID)
    }

    private func consume(session: AgentSession) async {
        do {
            let updates = try await session.start()
            sessionState = .running
            flushPendingPrompt()
            for await update in updates {
                apply(update)
            }
        } catch {
            sessionState = .failed(String(describing: error))
        }
        self.session = nil
        if case .running = sessionState { sessionState = .exited(status: 0) }
    }

    private func apply(_ update: SessionUpdate) {
        switch update {
        case .graphChanged(let changes):
            // Streaming-only bursts are throttled; anything structural refreshes immediately.
            let isStreamingOnly = !changes.isEmpty && changes.allSatisfy {
                if case .streamingUpdated = $0 { return true }
                return false
            }
            if isStreamingOnly {
                let sinceLast = Date().timeIntervalSince(lastStreamingRefresh)
                guard sinceLast >= Self.streamingInterval else {
                    // Throttled, but not discarded. Dropping an update outright loses whichever
                    // one happens to land inside the window — and the last chunk of a reply
                    // almost always does, because the burst stops there. That left the closing
                    // words of a message unrendered until some later frame happened to arrive.
                    streamingDirty = true
                    scheduleStreamingFlush(after: Self.streamingInterval - sinceLast)
                    return
                }
                lastStreamingRefresh = Date()
                streamingDirty = false
            }

            requestGraphRefresh(includingGit: !isStreamingOnly)

        case .approvalPending(let pending):
            pendingApprovals.append(pending)

        case .approvalResolved(let request, let decision):
            pendingApprovals.removeAll { $0.payload.toolUseID == request.payload.toolUseID }
            auditLog.insert(AuditEntry(
                at: Date(),
                toolName: request.payload.toolName,
                summary: request.payload.summary,
                verdict: decision.verdict,
                provenance: decision.provenance,
                reason: decision.reason), at: 0)
            refreshRules()

        case .approvalChannelFailure(let message):
            approvalChannelFailure = message

        case .malformedLine(let line, _):
            malformedLines.append(line)

        case .standardError(let text):
            standardError.append(text)

        case .turnCompleted(let result):
            lastTurn = result
            if let cost = result.totalCostUSD { cumulativeCostUSD += cost }
            git?.refresh()

        case .exited(let status):
            sessionState = .exited(status: status)
            git?.refresh()
            // The CLI has finished writing its transcript, so the list can pick up this session.
            refreshHistory()
        }
    }

    /// Renders a throttled burst's tail once its window closes.
    ///
    /// One timer at a time: every further update inside the window only re-raises the dirty flag,
    /// so a burst schedules one flush rather than one per frame.
    private func scheduleStreamingFlush(after delay: TimeInterval) {
        guard streamingFlush == nil else { return }
        streamingFlush = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            self.streamingFlush = nil
            // A live update may have beaten the timer to it, in which case the tail is on screen
            // already and this pass has nothing to add.
            guard !Task.isCancelled, self.streamingDirty else { return }
            self.streamingDirty = false
            self.lastStreamingRefresh = Date()
            self.requestGraphRefresh(includingGit: false)
        }
    }

    /// Asks for the session's snapshot to be republished, coalescing with any refresh already
    /// running rather than racing it. See `graphRefreshInFlight`.
    private func requestGraphRefresh(includingGit: Bool) {
        graphRefreshNeedsGit = graphRefreshNeedsGit || includingGit
        guard !graphRefreshInFlight else {
            graphRefreshPending = true
            return
        }
        graphRefreshInFlight = true
        Task { [weak self] in
            guard let self else { return }
            repeat {
                self.graphRefreshPending = false
                await self.refreshGraph()
            } while self.graphRefreshPending
            self.graphRefreshInFlight = false
        }
    }

    /// Republishes everything derived from the session's snapshot.
    private func refreshGraph() async {
        guard let session else { return }
        let snapshot = await session.graph
        let wantsGit = graphRefreshNeedsGit
        graphRefreshNeedsGit = false

        graph = snapshot
        transcriptRevision &+= 1
        recordActivity(in: snapshot)
        recordBusyState(in: snapshot)
        if selectedAgentID == nil { selectedAgentID = snapshot.root?.id }
        if let capabilities = snapshot.root?.capabilities {
            mcp.update(capabilities: capabilities)
            rememberSlashCommands(capabilities.slashCommands)
        }

        // Sorted because `nodes` is a dictionary: unordered, this reshuffles the incident banner
        // between frames and never compares equal to the list it just replaced.
        let incidents = snapshot.nodes.values
            .filter(\.hasFailOpenIncident)
            .sorted { $0.id < $1.id }
            .map { "Agent \($0.title) ran a command without approval." }
        // Assigning an equal array still invalidates every view observing it, and this is
        // recomputed on every frame of a stream while being empty in almost every session.
        if incidents != failOpenIncidents { failOpenIncidents = incidents }

        // The working tree is being changed *during* a turn, not at the end of one. Waiting for
        // `turnCompleted` meant the Changes list and the Git workbench sat stale for minutes while
        // files moved underneath them. `refresh()` coalesces, so a burst of edits still costs one
        // `git status`.
        if wantsGit { git?.refresh() }
    }

    // MARK: - Actions

    /// What Return and the composer's primary button both do: start the session if it is not
    /// running, otherwise send what is in the draft.
    func submit() {
        // A command Machline owns never reaches the agent — sending it would only put the literal
        // text in the transcript.
        if runLocalCommand() { return }
        guard canSubmit else { return }

        if sessionState.isRunning {
            sendPrompt()
            return
        }

        // Starting a session was its own step, and pressing Return before it discarded what had
        // been typed. Typing is the intent; the session is plumbing. The draft is held and sent
        // the moment the session is up.
        let text = promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            pendingPrompt = text
            recordHistory(text)
            promptDraft = ""
        }
        startSession()
    }

    /// Typed before a session existed, delivered as soon as one does.
    private var pendingPrompt: String?

    /// Sends whatever was typed before the session came up.
    private func flushPendingPrompt() {
        guard let text = pendingPrompt, let session else { return }
        pendingPrompt = nil
        liveActivityAt = Date()
        Task { try? await session.send(steer: text) }
    }

    /// The failure text behind a `.failed` state, for the composer to show. A session that could
    /// not start must say why — otherwise it reads as a hang.
    var failureMessage: String? {
        if case .failed(let message) = sessionState { return message }
        return nil
    }

    func sendPrompt() {
        let text = promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let session else { return }
        recordHistory(text)
        promptDraft = ""
        liveActivityAt = Date()
        Task { try? await session.send(steer: text) }
    }

    /// Empties the conversation on both sides of the process boundary. `/clear`.
    ///
    /// `clear` is one of the CLI's own slash commands, so before this it was forwarded like any
    /// other prompt: the CLI dropped the context it was carrying and said nothing this app could
    /// act on, which left every message still on screen over a conversation that no longer
    /// existed. It is intercepted now — the timeline is emptied here, and `AgentSession.clear()`
    /// still sends `/clear` on, so the agent forgets what the screen has just stopped showing.
    func clearConversation() {
        // Replayed history is part of the conversation being cleared, not a record of it.
        replay = []
        recordedUsage = nil
        // Every key refers to a row that no longer exists, replayed or live.
        rowExpansion = [:]
        diffModalPath = nil
        transcriptRevision &+= 1

        // With no session there is nothing carrying context, and clearing the screen is the whole
        // of the job.
        guard let session else { return }
        Task { try? await session.clear() }
    }

    func interrupt() {
        guard let session else { return }
        Task { await session.interrupt() }
    }

    func stop() {
        guard let session else { return }
        Task { await session.stop() }
        pump?.cancel()
    }

    func approve(_ pending: PendingApproval) {
        pending.approveOnce()
    }

    func deny(_ pending: PendingApproval, feedback: String) {
        pending.deny(feedback: feedback)
    }

    /// Answers an `AskUserQuestion` call.
    ///
    /// Resolved as a denial carrying the answer, which is not the contradiction it looks like: the
    /// verdict stops the runtime asking again through an interface this app does not present, and
    /// the reason is delivered to the agent as the call's result — which is precisely where an
    /// answer belongs. `AskUserQuestion.result` words it so the agent reads a reply, not a refusal.
    func answer(_ pending: PendingApproval, with answers: [AskUserQuestion.Answer]) {
        pending.deny(feedback: AskUserQuestion.result(for: answers))
    }

    /// Adds an always-allow rule, then approves the request that prompted it.
    func alwaysAllow(_ pending: PendingApproval) {
        guard let session else { return }
        let command = pending.payload.bashCommand ?? pending.payload.summary
        // A prefix up to the first argument keeps the rule narrow: `git status` rather than `git`.
        let words = command.split(separator: " ").prefix(2).joined(separator: " ")
        let rule = ApprovalRule.allowBashPrefix(words)
        Task {
            await session.add(rule: rule)
            pending.approveOnce()
        }
    }

    func dismissIncidents() {
        failOpenIncidents.removeAll()
        approvalChannelFailure = nil
    }

    func openDiffModal(path: String) {
        diffModalPath = DiffTarget(path: path)
    }

    func openViewer(path: String) {
        viewerPath = DiffTarget(path: path)
    }

    /// Closes the diff and opens the viewer on the same file.
    ///
    /// Sequenced rather than simultaneous: SwiftUI drops a presentation requested while another
    /// sheet is still dismissing, which is why doing both in one action did nothing.
    func replaceDiffModalWithViewer(path: String) {
        diffModalPath = nil
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            self.viewerPath = DiffTarget(path: path)
        }
    }

    /// Opens the file in whatever the operator uses for it.
    func openFile(path: String) {
        guard let url = fileURL(for: path) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Selects the file in Finder without opening it.
    func revealInFinder(path: String) {
        guard let url = fileURL(for: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Resolves a path the interface is showing to a file on disk.
    ///
    /// Git reports paths relative to the *repository*, and since repositories are discovered up to
    /// three levels below the workspace, the two are often not the same directory. Resolving
    /// against the workspace produced a path that did not exist, and `NSWorkspace.open` fails
    /// silently on one of those — which is what made these buttons look dead.
    func fileURL(for path: String) -> URL? {
        if path.hasPrefix("/") {
            let absolute = URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: absolute.path) ? absolute : nil
        }

        // The active repository first, then the workspace, so a path from either resolves.
        let bases = [git?.activeRepository, workspace?.url].compactMap { $0 }
        for base in bases {
            let candidate = base.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Stamps an agent as updated when its transcript actually grew. Re-deriving this from a graph
    /// snapshot alone would restamp every agent on every frame.
    /// Stamps when the selected agent started its current stretch of work, so the activity line
    /// counts from that moment rather than from the window opening.
    private func recordBusyState(in snapshot: AgentGraph) {
        let selected = selectedAgentID.flatMap { snapshot.node(id: $0) } ?? snapshot.root
        guard let selected, selected.state.isBusy else {
            busySince = nil
            return
        }
        if busySince == nil { busySince = Date() }
    }

    private func recordActivity(in snapshot: AgentGraph) {
        let now = Date()
        for node in snapshot.orderedNodes() {
            let count = node.transcript.count
            if lastTranscriptCount[node.id] != count {
                lastTranscriptCount[node.id] = count
                agentUpdatedAt[node.id] = now
            }
        }
    }
}

// MARK: - Derived presentation state

extension AppModel {

    // MARK: Timeline

    /// The selected agent's transcript, folded into the rows the timeline draws.
    ///
    /// Memoised on the transcript revision, which is bumped by exactly the refresh that can change
    /// a transcript. Without the memo this ran from the timeline's body — an O(transcript) walk
    /// with a string concatenation per multi-block reply, re-run on every body pass, which during a
    /// stream is a dozen a second and during a scroll is once per preference change.
    var timelineEvents: [TimelineEvent] {
        let agent = selectedAgent
        if let timelineCache, timelineCache.revision == transcriptRevision,
           timelineCache.agentID == agent?.id {
            return timelineCache.events
        }
        let events = agent.map { TimelineFold.events(in: $0.transcript) } ?? []
        timelineCache = (transcriptRevision, agent?.id, events)
        return events
    }

    // MARK: Rail

    var canStartSession: Bool { workspace != nil && !sessionState.isRunning }

    var canSubmit: Bool {
        guard workspace != nil else { return false }
        if sessionState.isRunning {
            return !promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // With nothing typed the button still starts an empty session, which is occasionally what
        // an operator wants; with something typed it starts one and sends it.
        return session == nil
    }

    /// Indentation depth, walking up the parent chain.
    func depth(of node: AgentNode) -> Int {
        var depth = 0
        var current = node
        while let parentID = current.parentID, let parent = graph.node(id: parentID) {
            depth += 1
            current = parent
        }
        return depth
    }

    func relativeUpdateTime(for node: AgentNode) -> String {
        guard let updated = agentUpdatedAt[node.id] else { return "" }
        let elapsed = Int(Date().timeIntervalSince(updated))
        if elapsed < 60 { return "\(max(elapsed, 0))s" }
        if elapsed < 3600 { return "\(elapsed / 60)m" }
        return "\(elapsed / 3600)h"
    }

    // MARK: Run panel

    /// Busy agents first, and within those the ones that need an operator before the ones that do
    /// not — a blocked agent is the one costing wall-clock.
    var activeAgents: [AgentNode] {
        agents
            .filter { $0.state.isBusy }
            .sorted { lhs, rhs in
                priority(of: lhs.state) < priority(of: rhs.state)
            }
    }

    var completedAgents: [AgentNode] {
        agents.filter(\.state.isTerminal)
    }

    private func priority(of state: AgentState) -> Int {
        switch state {
        case .waitingForApproval: return 0
        case .blocked: return 1
        case .executingTool: return 2
        default: return 3
        }
    }

    /// The CLI's id for the running session.
    ///
    /// Taken from the root agent when the handshake has landed, because a forked resume mints an
    /// id we did not choose. Before that, the id we asked for is the best available answer.
    var liveSessionID: String? {
        if case .root(let id)? = graph.root?.kind, !id.isEmpty { return id.lowercased() }
        if let resumedFrom { return resumedFrom.id.lowercased() }
        return sessionID?.uuidString.lowercased()
    }

    func isLive(_ recorded: HistoricalSession) -> Bool {
        session != nil && recorded.id.lowercased() == liveSessionID
    }

    var shortSessionID: String? {
        liveSessionID.map { String($0.prefix(8)) }
    }

    var queuedSteerCount: Int {
        selectedAgent?.transcript.count { entry in
            if case .steerQueued = entry { return true }
            return false
        } ?? 0
    }

    var claudeCodeVersion: String? {
        graph.root?.capabilities?.claudeCodeVersion
    }

    // MARK: Context accounting

    /// The window the current model is expected to have. The runtime does not report it, so this
    /// is a lookup, and it is only ever used as the denominator of a proportion — the exact token
    /// counts beside the ring come from the runtime.
    var contextWindow: Int {
        // The negotiated model is authoritative; the picker's value may be an alias or unset.
        ContextWindow.size(forModel:
            graph.root?.capabilities?.model
            ?? recordedUsage?.model
            ?? model)
    }

    /// Tokens occupying the window right now.
    ///
    /// Taken from the most recent model call, not from the `result` frame. A turn is many calls
    /// and the result's usage adds them all up — with a cached prefix re-read on every call that
    /// total runs to millions, so using it here showed a conversation at several hundred percent
    /// of a window it was comfortably inside. What each call carried is the occupancy.
    var contextUsed: Int {
        if let occupancy = graph.root?.telemetry.contextTokens, occupancy > 0 { return occupancy }
        // Nothing has come back in this process yet. A resumed conversation still occupies its
        // window, and the transcript is where that number lives until the first reply lands.
        return recordedUsage?.contextTokens ?? 0
    }

    /// Every token this session has sent or received, across every agent in the tree.
    ///
    /// Not a proportion of anything: a long conversation re-reads its cached prefix on each call,
    /// so this passes a million while the window stays half empty. That is what it costs, and it
    /// is shown as its own figure rather than mixed into the context reading.
    var tokensSpent: Int {
        agents.reduce(0) { $0 + $1.telemetry.billedTokens }
    }

    var tokensSpentLabel: String { tokensSpent.abbreviated }

    var contextFraction: Double {
        UsageAccounting.fraction(used: contextUsed, window: contextWindow)
    }

    var contextUsedLabel: String { "\(contextUsed.abbreviated) / \(contextWindow.abbreviated)" }

    var contextRemainingLabel: String {
        UsageAccounting.remaining(used: contextUsed, window: contextWindow).abbreviated
    }

    /// True once a turn has completed here and actually reported a cost.
    var hasRecordedCost: Bool { cumulativeCostUSD > 0 }

    var costLabel: String { UsageAccounting.costLabel(forUSD: cumulativeCostUSD) }

    /// Cost arrives on a `result` frame and transcripts do not record those, so a resumed
    /// conversation genuinely has no earlier figure to show — only what it spends from here.
    var costExplanation: String {
        hasRecordedCost
            ? "Spent since this session started here."
            : "No completed turn yet. Cost is reported per turn and is not recorded in transcripts,"
                + " so a resumed conversation counts only from now."
    }

    var usageDetails: [UsageAccounting.Row] {
        UsageAccounting.rows(usage: lastTurn?.usage, turns: lastTurn?.numTurns, spent: tokensSpent)
    }

    // MARK: Changes

    /// Net working-tree changes, staged and unstaged merged, most-changed first.
    ///
    /// A file edited twice appears once with its current net diff. Summing per-edit counts would
    /// double-count it.
    var sessionChanges: [GitFileDiff] {
        guard let git else { return [] }
        if let cached = changesCache, cached.revision == git.revision { return cached.diffs }
        var byPath: [String: GitFileDiff] = [:]
        for diff in git.unstaged + git.staged {
            if let existing = byPath[diff.newPath] {
                // The larger of the two sides is the better single summary; they are not additive.
                if diff.additions + diff.deletions > existing.additions + existing.deletions {
                    byPath[diff.newPath] = diff
                }
            } else {
                byPath[diff.newPath] = diff
            }
        }
        let sorted = byPath.values
            .sorted { $0.additions + $0.deletions > $1.additions + $1.deletions }
        changesCache = (git.revision, sorted, Dictionary(
            uniqueKeysWithValues: (git.status?.files ?? []).map { ($0.path, $0) }))
        return sorted
    }

    func diff(for path: String) -> GitFileDiff? {
        let wanted = repositoryRelativePath(path)
        return sessionChanges.first { $0.newPath == wanted }
    }

    /// A path as Git reports it: relative to the repository root.
    ///
    /// The Changes list already speaks that language, but a diff opened from the timeline does not:
    /// a tool call carries `file_path` as an absolute path, so comparing it to `newPath` never
    /// matched and Expand opened a modal that said the file was no longer in the working tree.
    ///
    /// The repository first, then the workspace, for the same reason `fileURL(for:)` tries both —
    /// a repository discovered below the workspace is not the same directory.
    func repositoryRelativePath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path

        for base in [git?.activeRepository, workspace?.url].compactMap({ $0 }) {
            let root = base.standardizedFileURL.path
            if standardized.hasPrefix(root + "/") {
                return String(standardized.dropFirst(root.count + 1))
            }
        }
        return standardized
    }

    /// The porcelain status letter for a path, so a rename or delete reads correctly rather than
    /// being inferred from the diff.
    func changeStatus(for path: String) -> String {
        // Indexed rather than scanned: this is called once per visible row, and a linear search
        // per row makes the Changes list quadratic in a repository with many changed files.
        _ = sessionChanges
        guard let file = changesCache?.statuses[repositoryRelativePath(path)] else { return "M" }
        if file.isUntracked { return "A" }
        let change = file.indexChange != .unmodified ? file.indexChange : file.worktreeChange
        switch change {
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .typeChanged: return "T"
        case .updatedButUnmerged: return "U"
        default: return "M"
        }
    }
}

extension MCPPanelModel {
    var grantedCount: Int {
        drawer?.groups.reduce(0) { $0 + $1.grantedCount } ?? 0
    }
}

/// Locates the helper binaries the app spawns.
enum BundledHelpers {
    /// The approval helper. A session that cannot find it must not start: a helper that cannot
    /// launch is the fail-open case, because the runtime times it out and runs the command.
    static var approvalHelperPath: String {
        path(for: "harness-approve")
    }

    static var mcpProxyPath: String {
        path(for: "harness-mcp-proxy")
    }

    private static func path(for name: String) -> String {
        // Inside the bundle when installed; alongside the executable when run from `.build`.
        let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()
        if let candidate = executableDirectory?.appendingPathComponent(name).path,
           FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return name
    }
}
