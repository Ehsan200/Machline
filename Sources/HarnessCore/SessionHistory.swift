import Foundation

/// One conversation the CLI has already recorded on disk.
public struct HistoricalSession: Sendable, Hashable, Identifiable, Codable {
    /// The CLI's session id — the value `--resume` takes.
    public let id: String
    public let fileURL: URL
    /// The working directory the session ran in, read from the transcript rather than inferred
    /// from the directory name.
    public let cwd: String
    /// The first thing the operator said, used as a title. `nil` for a transcript that never got
    /// a user message.
    public let firstPrompt: String?
    public let startedAt: Date?
    /// When the conversation last had a message in it.
    ///
    /// Read from the last timestamped entry rather than from the file's modification date. The two
    /// diverge in a way that matters: opening a session makes the CLI append to its transcript
    /// straight away, so an mtime-based value restamps a months-old conversation as "just now" the
    /// moment it is clicked — which silently reorders the list the operator is reading.
    public let lastActivityAt: Date
    public let gitBranch: String?
    public let cliVersion: String?
    /// The model this conversation was last answered by, as the transcript records it. `nil` for a
    /// transcript with no assistant turn yet.
    public let model: String?
    public let byteCount: Int

    /// True for a transcript the app produced for itself rather than a conversation the operator
    /// had — a commit-message draft, for instance.
    ///
    /// These are recorded by the CLI like any other session, so without this they appear in the
    /// session list as clutter nobody asked for. Matched on the prompt the app itself sends, which
    /// is the only marker the transcript carries.
    public var isMachineGenerated: Bool {
        guard let firstPrompt else { return false }
        return Self.generatedPromptPrefixes.contains { firstPrompt.hasPrefix($0) }
    }

    static let generatedPromptPrefixes = [
        "Write a Conventional Commits message"
    ]

    /// Wrappers the CLI puts around a message before the operator's own words.
    ///
    /// A transcript's first user entry is often one of these rather than anything the operator
    /// typed, and using it as a title fills the list with rows that all read the same.
    static let syntheticPromptPrefixes = [
        "<local-command-caveat>",
        "<command-name>",
        "<command-message>",
        "Caveat: The messages below were generated"
    ]

    /// The same session, seen as having been active at `date`.
    ///
    /// For the conversation running right now: its transcript is reread only when the child exits,
    /// so a months-old session that is being typed into would otherwise sit under "Older" until
    /// then, while the operator is looking straight at it.
    public func restamped(lastActivityAt date: Date) -> HistoricalSession {
        HistoricalSession(
            id: id,
            fileURL: fileURL,
            cwd: cwd,
            firstPrompt: firstPrompt,
            startedAt: startedAt,
            lastActivityAt: date,
            gitBranch: gitBranch,
            cliVersion: cliVersion,
            model: model,
            byteCount: byteCount)
    }

    /// The shell line that resumes this conversation in a terminal.
    ///
    /// The `cd` is part of the command rather than a step left to the operator: the CLI resolves a
    /// session id against the directory it is run from, so `--resume` on its own finds nothing from
    /// anywhere else.
    public var resumeCommand: String {
        "cd \(cwd.shellQuoted) && claude --resume \(id.shellQuoted)"
    }

    /// A one-line title. Falls back to the session id, never to a fabricated summary.
    public var title: String {
        guard let firstPrompt, !firstPrompt.isEmpty else { return "Session \(id.prefix(8))" }
        return firstPrompt
    }
}

/// One entry from a recorded conversation, ready to render.
///
/// Deliberately not `TranscriptEntry`: that type is built from live control-plane frames and
/// carries approval and turn state a transcript cannot reconstruct. Replayed history is read-only
/// and says so by being a different type.
public struct ReplayEntry: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case user(String)
        case assistant(String)
        case thinking(String)
        case toolCall(name: String, detail: String)
        case toolResult(text: String, isError: Bool)
    }

    public let id: Int
    /// Where it sat in the transcript file, for diagnostics.
    public let lineNumber: Int
    public let kind: Kind
    public let at: Date?
}

/// Reads the CLI's own on-disk conversation history.
///
/// The CLI keeps one JSONL transcript per session under
/// `~/.claude/projects/<mangled-cwd>/<session-id>.jsonl`. This reads that store; it never writes to
/// it. Nothing here is authoritative about a *running* session — that comes from the frame stream.
public struct SessionHistory: Sendable {

    /// How much of a transcript's head is read looking for the first user message. Transcripts run
    /// to megabytes and the opening exchange is always near the start, so the whole file is never
    /// paged in.
    private static let headByteLimit = 128 * 1024

    /// How much of the tail is read looking for the last timestamp. The final entries are what
    /// matter, and a fixed window keeps this a bounded read however large the transcript is.
    private static let tailByteLimit = 64 * 1024

    public let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// The CLI's directory name for a working directory: every character that is not
    /// alphanumeric becomes a dash.
    ///
    /// Derived from the observed store rather than documented, so `sessions(forWorkspace:)` treats
    /// it as a fast path and falls back to reading each transcript's own `cwd` when it misses.
    public static func directoryName(for workspace: URL) -> String {
        let path = workspace.standardizedFileURL.path
        return String(path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    /// Every recorded session for a workspace, most recently active first.
    public func sessions(forWorkspace workspace: URL) -> [HistoricalSession] {
        let target = workspace.standardizedFileURL.path
        let direct = root.appendingPathComponent(Self.directoryName(for: workspace), isDirectory: true)

        // Transcripts the app produced for itself are excluded: they are not conversations, and
        // older builds left some behind before drafting moved to a scratch directory.
        var found = sessions(inDirectory: direct)
            .filter { $0.cwd == target && !$0.isMachineGenerated }
        if !found.isEmpty {
            return found.sorted { $0.lastActivityAt > $1.lastActivityAt }
        }

        // The mangling guess missed. Fall back to matching on each transcript's recorded `cwd`,
        // which is the only authoritative link between a directory and a workspace.
        for directory in projectDirectories() where directory != direct {
            found += sessions(inDirectory: directory)
                .filter { $0.cwd == target && !$0.isMachineGenerated }
        }
        return found.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// Every workspace with its most recent conversations, for a landing page.
    ///
    /// Reads a bounded number of transcripts per project rather than all of them: this runs with
    /// nothing else on screen, and a machine with eighty projects should not spend that time
    /// parsing history nobody asked to see.
    public func recentWork(
        projectLimit: Int = 12, sessionsPerProject: Int = 5
    ) -> [(workspace: URL, sessions: [HistoricalSession])] {
        knownWorkspaces()
            .prefix(projectLimit)
            .compactMap { known in
                let sessions = Array(sessions(forWorkspace: known.url).prefix(sessionsPerProject))
                return sessions.isEmpty ? nil : (known.url, sessions)
            }
    }

    /// Every workspace the CLI has a transcript for, most recently active first.
    ///
    /// Reads one transcript per directory: they all share a `cwd`, so the newest is enough to name
    /// the project without paging in the rest.
    public func knownWorkspaces() -> [(url: URL, lastActivityAt: Date)] {
        var byPath: [String: Date] = [:]
        for directory in projectDirectories() {
            guard let newest = sessions(inDirectory: directory, limit: 1).first else { continue }
            let existing = byPath[newest.cwd]
            if existing == nil || existing! < newest.lastActivityAt {
                byPath[newest.cwd] = newest.lastActivityAt
            }
        }
        return byPath
            .map { (URL(fileURLWithPath: $0.key), $0.value) }
            .sorted { $0.1 > $1.1 }
    }

    // MARK: - Usage

    /// What the last recorded turn reported about context occupancy.
    ///
    /// A resumed session has had no turn complete in *this* process, so the live usage counters
    /// start at zero even though the conversation may be most of the way through its window. The
    /// transcript is the only place that number exists until the next turn lands.
    public struct RecordedUsage: Sendable, Hashable {
        public let inputTokens: Int
        public let cacheCreationTokens: Int
        public let cacheReadTokens: Int
        public let outputTokens: Int
        public let model: String?

        /// Everything occupying the window: the prompt, whatever was read from cache, and the
        /// reply. This is the same sum the live counter uses.
        public var contextTokens: Int {
            inputTokens + cacheCreationTokens + cacheReadTokens + outputTokens
        }
    }

    /// Reads the last assistant turn's usage. Scans from the end — the newest turn is what counts,
    /// and a transcript can be megabytes.
    public func lastUsage(of session: HistoricalSession) -> RecordedUsage? {
        guard let data = try? Data(contentsOf: session.fileURL, options: .mappedIfSafe) else {
            return nil
        }

        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line))
                    as? [String: Any],
                  object["type"] as? String == "assistant",
                  object["isSidechain"] as? Bool != true,
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { continue }

            func count(_ key: String) -> Int { usage[key] as? Int ?? 0 }
            return RecordedUsage(
                inputTokens: count("input_tokens"),
                cacheCreationTokens: count("cache_creation_input_tokens"),
                cacheReadTokens: count("cache_read_input_tokens"),
                outputTokens: count("output_tokens"),
                model: message["model"] as? String)
        }
        return nil
    }

    // MARK: - Replay

    /// The recorded conversation, for showing what a resumed session already contains.
    ///
    /// Resuming does not replay: the CLI continues from its own stored state and emits only new
    /// frames. Without this the timeline of a resumed session starts blank, as though the earlier
    /// exchange never happened.
    ///
    /// `limit` caps how many entries are returned, keeping the most recent — a transcript can hold
    /// thousands, and the interesting end is the last one.
    public func replay(of session: HistoricalSession, limit: Int = 400) -> [ReplayEntry] {
        guard let data = try? Data(contentsOf: session.fileURL, options: .mappedIfSafe) else {
            return []
        }

        let timestamps = ISO8601DateFormatter.transcript()
        var entries: [ReplayEntry] = []
        var index = 0

        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            index += 1
            guard let object = try? JSONSerialization.jsonObject(with: Data(line))
                    as? [String: Any] else { continue }
            // Sidechain entries belong to a subagent's own conversation, not this one.
            guard object["isSidechain"] as? Bool != true else { continue }

            let at = (object["timestamp"] as? String).flatMap { timestamps.date(from: $0) }
            let role = object["type"] as? String
            guard role == "user" || role == "assistant",
                  let message = object["message"] as? [String: Any]
            else { continue }

            for kind in Self.kinds(in: message["content"], role: role ?? "") {
                entries.append(ReplayEntry(id: entries.count, lineNumber: index, kind: kind, at: at))
            }
        }

        return entries.count > limit ? Array(entries.suffix(limit)) : entries
    }

    /// Splits one message's content blocks into renderable entries.
    private static func kinds(in content: Any?, role: String) -> [ReplayEntry.Kind] {
        if let text = content as? String {
            guard !text.isEmpty else { return [] }
            return [role == "user" ? .user(text) : .assistant(text)]
        }
        guard let blocks = content as? [[String: Any]] else { return [] }

        return blocks.compactMap { block in
            switch block["type"] as? String {
            case "text":
                guard let text = block["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return role == "user" ? .user(text) : .assistant(text)

            case "thinking":
                guard let text = block["thinking"] as? String, !text.isEmpty else { return nil }
                return .thinking(text)

            case "tool_use":
                let name = block["name"] as? String ?? "tool"
                return .toolCall(name: name, detail: Self.summarise(input: block["input"]))

            case "tool_result":
                return .toolResult(
                    text: Self.flatten(block["content"]),
                    isError: block["is_error"] as? Bool ?? false)

            default:
                return nil
            }
        }
    }

    /// The one line that identifies a call: the command, the path, or the raw JSON as a fallback.
    private static func summarise(input: Any?) -> String {
        guard let input = input as? [String: Any] else { return "" }
        for key in ["command", "file_path", "notebook_path", "pattern", "url", "prompt"] {
            if let value = input[key] as? String { return value }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: input) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func flatten(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    // MARK: - Reading

    private func projectDirectories() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return contents.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    /// Parses the transcripts in one project directory. `limit` stops after that many, newest
    /// first, for callers that only need the most recent.
    private func sessions(inDirectory directory: URL, limit: Int? = nil) -> [HistoricalSession] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "jsonl" }

        let ordered = files
            .map { url -> (URL, Date, Int) in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return (url, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0)
            }
            .sorted { $0.1 > $1.1 }

        var parsed: [HistoricalSession] = []
        for (url, modified, size) in ordered {
            // The filesystem's mtime is only a fallback: see `lastActivityAt`.
            let activity = Self.lastEntryDate(url: url, byteCount: size) ?? modified
            if let session = Self.parse(url: url, modified: activity, byteCount: size) {
                parsed.append(session)
                if let limit, parsed.count >= limit { break }
            }
        }
        return parsed
    }

    /// The timestamp on the last entry that carries one.
    ///
    /// Scans backwards through a bounded tail window. `nil` when the window holds no timestamped
    /// entry, in which case the caller falls back to the file's modification date.
    static func lastEntryDate(url: URL, byteCount: Int) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let offset = max(0, byteCount - tailByteLimit)
        if offset > 0 { try? handle.seek(toOffset: UInt64(offset)) }
        guard let tail = try? handle.readToEnd(), !tail.isEmpty else { return nil }

        var lines = tail.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        // Seeking into the middle of the file almost certainly lands mid-line.
        if offset > 0, !lines.isEmpty { lines.removeFirst() }

        let timestamps = ISO8601DateFormatter.transcript()
        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line))
                    as? [String: Any],
                  let stamp = object["timestamp"] as? String,
                  let date = timestamps.date(from: stamp)
            else { continue }
            return date
        }
        return nil
    }

    /// Reads a transcript's head for the fields that identify and title it.
    static func parse(url: URL, modified: Date, byteCount: Int) -> HistoricalSession? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let head = try? handle.read(upToCount: headByteLimit), !head.isEmpty else {
            return nil
        }

        var sessionID: String?
        var cwd: String?
        var startedAt: Date?
        var gitBranch: String?
        var cliVersion: String?
        var firstPrompt: String?
        var model: String?
        let timestamps = ISO8601DateFormatter.transcript()

        // The last line of a truncated read is very likely incomplete, so it is dropped rather
        // than fed to the parser.
        var lines = head.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if head.count == headByteLimit, !lines.isEmpty { lines.removeLast() }

        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }

            sessionID = sessionID ?? object["sessionId"] as? String
            cwd = cwd ?? object["cwd"] as? String
            gitBranch = gitBranch ?? object["gitBranch"] as? String
            cliVersion = cliVersion ?? object["version"] as? String
            if startedAt == nil, let stamp = object["timestamp"] as? String {
                startedAt = timestamps.date(from: stamp)
            }

            if firstPrompt == nil,
               object["type"] as? String == "user",
               // Sidechain entries belong to a subagent, not to the operator.
               object["isSidechain"] as? Bool != true,
               let message = object["message"] as? [String: Any],
               let candidate = Self.text(in: message["content"]),
               // Keep looking past the CLI's own wrappers for something the operator wrote.
               !HistoricalSession.syntheticPromptPrefixes.contains(where: candidate.hasPrefix) {
                firstPrompt = candidate
            }

            if model == nil, object["type"] as? String == "assistant",
               let message = object["message"] as? [String: Any] {
                model = message["model"] as? String
            }

            if firstPrompt != nil, sessionID != nil, cwd != nil, model != nil { break }
        }

        // The filename is the session id; the field is a cross-check for a transcript whose head
        // was all queue operations.
        let identifier = sessionID ?? url.deletingPathExtension().lastPathComponent
        guard let cwd else { return nil }

        return HistoricalSession(
            id: identifier,
            fileURL: url,
            cwd: cwd,
            firstPrompt: firstPrompt,
            startedAt: startedAt,
            lastActivityAt: modified,
            gitBranch: gitBranch,
            cliVersion: cliVersion,
            model: model,
            byteCount: byteCount)
    }

    /// Flattens a message's content to its first line of text. Content is a string on some
    /// entries and an array of typed blocks on others.
    private static func text(in content: Any?) -> String? {
        let raw: String?
        switch content {
        case let string as String:
            raw = string
        case let blocks as [[String: Any]]:
            raw = blocks.compactMap { $0["text"] as? String }.first
        default:
            raw = nil
        }

        guard let raw else { return nil }
        let firstLine = raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        guard let firstLine, !firstLine.isEmpty else { return nil }
        return firstLine.count > 140 ? String(firstLine.prefix(140)) + "…" : firstLine
    }
}

extension ISO8601DateFormatter {
    /// A formatter for transcript timestamps, which carry fractional seconds the default
    /// configuration rejects.
    ///
    /// Built per use rather than shared: `ISO8601DateFormatter` is a mutable reference type and is
    /// not `Sendable`, and parsing happens off the main actor. Each transcript needs exactly one
    /// timestamp parsed, so a shared instance would save nothing worth the synchronisation.
    static func transcript() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
