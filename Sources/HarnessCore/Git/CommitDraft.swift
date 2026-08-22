import Foundation

/// A Conventional Commits message.
public struct ConventionalCommit: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case feat, fix, refactor, perf, docs, test, build, ci, style, chore, revert

        public var explanation: String {
            switch self {
            case .feat: return "A new capability"
            case .fix: return "A bug fix"
            case .refactor: return "Restructuring without behaviour change"
            case .perf: return "A performance improvement"
            case .docs: return "Documentation only"
            case .test: return "Tests only"
            case .build: return "Build system or dependencies"
            case .ci: return "CI configuration"
            case .style: return "Formatting only, no behaviour change"
            case .chore: return "Maintenance work"
            case .revert: return "Reverts a previous commit"
            }
        }
    }

    public var kind: Kind
    public var scope: String?
    public var isBreaking: Bool
    /// The subject text, without the `type(scope):` prefix.
    public var summary: String
    public var body: String?
    /// Trailers such as `Refs: #123`.
    public var footers: [String]

    public init(
        kind: Kind, scope: String? = nil, isBreaking: Bool = false,
        summary: String, body: String? = nil, footers: [String] = []
    ) {
        self.kind = kind
        self.scope = scope
        self.isBreaking = isBreaking
        self.summary = summary
        self.body = body
        self.footers = footers
    }

    public var subject: String {
        var prefix = kind.rawValue
        if let scope, !scope.isEmpty { prefix += "(\(scope))" }
        if isBreaking { prefix += "!" }
        return "\(prefix): \(summary)"
    }

    public func rendered() -> String {
        var parts = [subject]
        if let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(body.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !footers.isEmpty {
            parts.append(footers.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Advisories

    /// Style guidance shown next to the composer. **Advisory, never enforced** (docs/RUNTIME.md) — a long
    /// subject is a nudge, not a blocked commit.
    public struct Advisory: Sendable, Hashable, Identifiable {
        public enum Kind: String, Sendable { case subjectTooLong, bodyLineTooLong, emptySummary,
                                                  subjectEndsWithPeriod, summaryNotImperative }
        public var id: String { "\(kind.rawValue):\(detail)" }
        public let kind: Kind
        public let detail: String
    }

    public static let subjectLimit = 50
    public static let bodyWrapLimit = 72

    public func advisories() -> [Advisory] {
        var advisories: [Advisory] = []

        if summary.trimmingCharacters(in: .whitespaces).isEmpty {
            advisories.append(Advisory(kind: .emptySummary, detail: "The subject has no summary"))
        }
        if subject.count > Self.subjectLimit {
            advisories.append(Advisory(
                kind: .subjectTooLong,
                detail: "Subject is \(subject.count) characters; \(Self.subjectLimit) is the guide"))
        }
        if summary.hasSuffix(".") {
            advisories.append(Advisory(
                kind: .subjectEndsWithPeriod, detail: "Subjects conventionally omit the full stop"))
        }
        if let body {
            for (index, line) in body.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.count > Self.bodyWrapLimit {
                advisories.append(Advisory(
                    kind: .bodyLineTooLong,
                    detail: "Body line \(index + 1) is \(line.count) characters; wrap at \(Self.bodyWrapLimit)"))
            }
        }
        return advisories
    }

    // MARK: - Parsing

    /// Parses an existing message, so an edited draft can round-trip back into the composer.
    /// Returns `nil` when the subject is not Conventional Commits shaped.
    public static func parse(_ message: String) -> ConventionalCommit? {
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let subject = lines.first, let colon = subject.firstIndex(of: ":") else { return nil }

        var prefix = String(subject[subject.startIndex..<colon])
        let summary = String(subject[subject.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)

        var isBreaking = false
        if prefix.hasSuffix("!") {
            isBreaking = true
            prefix.removeLast()
        }

        var scope: String?
        if let open = prefix.firstIndex(of: "("), prefix.hasSuffix(")") {
            scope = String(prefix[prefix.index(after: open)..<prefix.index(before: prefix.endIndex)])
            prefix = String(prefix[prefix.startIndex..<open])
        }
        guard let kind = Kind(rawValue: prefix) else { return nil }

        let remainder = lines.dropFirst().drop { $0.isEmpty }
        var body: String?
        var footers: [String] = []
        if !remainder.isEmpty {
            let text = remainder.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            // A trailing block of `Key: value` lines is treated as footers.
            let paragraphs = text.components(separatedBy: "\n\n")
            if paragraphs.count > 1, Self.looksLikeFooters(paragraphs[paragraphs.count - 1]) {
                footers = paragraphs[paragraphs.count - 1].split(separator: "\n").map(String.init)
                body = paragraphs.dropLast().joined(separator: "\n\n")
            } else if paragraphs.count == 1, Self.looksLikeFooters(text) {
                footers = text.split(separator: "\n").map(String.init)
            } else {
                body = text
            }
        }

        if body?.isEmpty == true { body = nil }
        return ConventionalCommit(
            kind: kind, scope: scope, isBreaking: isBreaking,
            summary: summary, body: body, footers: footers)
    }

    private static func looksLikeFooters(_ text: String) -> Bool {
        let lines = text.split(separator: "\n")
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { line in
            guard let colon = line.firstIndex(of: ":") else { return false }
            let key = line[line.startIndex..<colon]
            return !key.isEmpty && !key.contains(" ") || key.hasPrefix("BREAKING CHANGE")
        }
    }
}

/// Generates a commit-message draft from the staged diff.
///
/// Reuses the agent runtime rather than adding a second LLM path (docs/RUNTIME.md): a short-lived
/// `claude -p` invocation with `--json-schema`, so the result is a validated object rather than
/// prose to be scraped. The draft is always a suggestion — the operator edits it and triggers the
/// commit themselves.
public struct CommitDraftGenerator: Sendable {

    public enum Failure: Error, Sendable {
        case nothingStaged
        case generationFailed(String)
        case unusableResponse(String)
    }

    /// Forks a conversation that already watched the work happen, instead of starting cold.
    ///
    /// The fork inherits the session's context — including the edits it just made — so the prompt
    /// carries a much smaller slice of the diff and the provider's cache already holds the prefix.
    /// It also means the session's own model is used: overriding the model on a fork throws the
    /// warm cache away and re-sends the whole conversation, which is slower than a cold small
    /// model, not faster.
    public struct Fork: Sendable, Hashable {
        public let sessionID: String
        /// Where the conversation is filed, so `--resume` finds it and the forked transcript can
        /// be deleted afterwards.
        public let workingDirectory: URL

        public init(sessionID: String, workingDirectory: URL) {
            self.sessionID = sessionID
            self.workingDirectory = workingDirectory
        }
    }

    /// Writing a subject line from a diff is summarising, not reasoning: the small model answers
    /// in a second or two where the session's model took tens of them, on the same three lines of
    /// output. Only used for a cold run — a fork keeps whatever model that session negotiated.
    public static let defaultModel = "claude-haiku-4-5-20251001"

    public var executable: String
    public var model: String?
    /// Passed to `--effort`. Drafting has nothing to think about.
    public var effort: String?
    /// Staged diffs beyond this many characters are truncated before being sent.
    public var diffCharacterLimit: Int
    public var fork: Fork?

    public init(
        executable: String = "claude",
        model: String? = CommitDraftGenerator.defaultModel,
        effort: String? = "low",
        diffCharacterLimit: Int = 60_000,
        fork: Fork? = nil
    ) {
        self.executable = executable
        self.model = model
        self.effort = effort
        self.diffCharacterLimit = diffCharacterLimit
        self.fork = fork
    }

    /// A fork already knows what changed, so it is sent a slice rather than the whole patch.
    private var effectiveDiffLimit: Int {
        fork == nil ? diffCharacterLimit : min(diffCharacterLimit, 8_000)
    }

    static let schema = #"""
    {"type":"object","properties":{"kind":{"type":"string","enum":["feat","fix","refactor","perf","docs","test","build","ci","style","chore","revert"]},"scope":{"type":"string"},"isBreaking":{"type":"boolean"},"summary":{"type":"string"},"body":{"type":"string"}},"required":["kind","summary","isBreaking"]}
    """#

    public func draft(for manager: GitManager) async throws -> ConventionalCommit {
        let status = try manager.status()
        guard !status.staged.isEmpty else { throw Failure.nothingStaged }

        let diffText = try manager.stagedDiff()
            .compactMap(\.fullPatch)
            .joined(separator: "\n")
        let limit = effectiveDiffLimit
        let truncated = diffText.count > limit
            ? String(diffText.prefix(limit)) + "\n[diff truncated]"
            : diffText

        let opening = fork == nil
            ? "Write a Conventional Commits message for the staged changes below."
            : "Write a Conventional Commits message for the changes staged in this repository. "
                + "You have been working on them, so use what you already know about why they "
                + "were made; the diff below is included only as a reminder and may be truncated."
        let prompt = """
        \(opening)

        Rules:
        - The subject line, including the `type(scope):` prefix, should fit in \
        \(ConventionalCommit.subjectLimit) characters.
        - Use the imperative mood and omit a trailing full stop.
        - Include a body only when the reason for the change is not obvious from the diff. \
        Wrap it at \(ConventionalCommit.bodyWrapLimit) characters.
        - Set isBreaking only for a genuine incompatible change.

        Staged diff:
        \(truncated)
        """

        // Drafting is a one-shot question, not a conversation the operator will return to — but
        // the CLI records every run as a session, and a run in the repository would file it under
        // that project and put it in the session list. A cold run therefore happens in a scratch
        // directory under a known id; a fork has to run where the conversation it forks is filed,
        // so its transcript is found by the id the CLI reports back and deleted afterwards.
        let scratch = fork == nil ? try Self.makeScratchDirectory() : nil
        let sessionID = UUID()
        defer {
            if let scratch { Self.discardTranscript(sessionID: sessionID, scratch: scratch) }
        }

        let process = Process()
        // Resolved and given the login shell's environment, exactly as a session is.
        //
        // This used to be `/usr/bin/env claude` on the app's own environment. Launched from Finder
        // that is `launchd`'s, whose `PATH` is `/usr/bin:/bin:/usr/sbin:/sbin` — so a Homebrew or
        // npm `claude` was invisible, `env` exited 127, and Suggest span and then did nothing.
        do {
            process.executableURL = try SessionSupervisor.resolve(executable: executable)
        } catch {
            throw Failure.generationFailed(
                "Could not find `\(executable)` on the path. \(String(describing: error))")
        }
        process.environment = SessionSupervisor.inheritedEnvironment()

        var arguments = [
            "-p",
            "--output-format", "json",
            "--json-schema", Self.schema,
            // A drafting call has no business reading the operator's settings or touching tools.
            "--setting-sources", "",
            "--strict-mcp-config",
            "--tools", ""
        ]
        if let fork {
            // `--fork-session` branches off rather than continuing the operator's conversation, so
            // the session they are working in is left exactly as it was.
            arguments += ["--resume", fork.sessionID, "--fork-session"]
        } else {
            arguments += ["--session-id", sessionID.uuidString.lowercased()]
            if let model { arguments += ["--model", model] }
        }
        if let effort, !effort.isEmpty { arguments += ["--effort", effort] }
        process.arguments = arguments
        // A cold run gets the scratch directory: the diff is already in the prompt, and
        // `--tools ""` means nothing here needs to see the working tree. A fork runs in the
        // repository, because that is where its conversation lives.
        process.currentDirectoryURL = scratch ?? fork?.workingDirectory

        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw Failure.generationFailed(String(describing: error))
        }
        try? stdinPipe.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
        try? stdinPipe.fileHandleForWriting.close()

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw Failure.generationFailed(String(decoding: errData, as: UTF8.self))
        }
        let response = String(decoding: outData, as: UTF8.self)
        // The fork was minted with an id we did not choose, so it is removed by the one the CLI
        // reports. Best-effort, like the cold path: a good draft must not fail on a stray file.
        if let fork, let forked = Self.reportedSessionID(in: response) {
            Self.discardForkedTranscript(sessionID: forked, workingDirectory: fork.workingDirectory)
        }
        return try Self.parseResponse(response)
    }

    /// The id the run was actually recorded under, from the `json` envelope.
    static func reportedSessionID(in text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(JSONValue.self, from: data),
              let id = envelope["session_id"]?.stringValue, !id.isEmpty
        else { return nil }
        return id
    }

    /// Removes a forked drafting transcript from the project it was filed under.
    static func discardForkedTranscript(
        sessionID: String, workingDirectory: URL, store: SessionHistory = SessionHistory()
    ) {
        let directory = store.root.appendingPathComponent(
            SessionHistory.directoryName(for: workingDirectory), isDirectory: true)
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("\(sessionID.lowercased()).jsonl"))
    }

    /// A directory for the drafting run to be recorded against.
    ///
    /// The path is resolved through symlinks before it is handed to the CLI. On macOS the
    /// temporary directory sits under `/var`, which is a link to `/private/var`: the CLI files the
    /// transcript under the resolved path, so a scratch directory named by the unresolved one is
    /// filed somewhere `discardTranscript` never looks and the run is left behind as a project.
    static func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("machline-commit-draft-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw Failure.generationFailed("Could not create a scratch directory: \(error)")
        }
        return url.resolvingSymlinksInPath()
    }

    /// Removes everything the drafting run left behind.
    ///
    /// Both the scratch directory and the CLI's own transcript for it. Best-effort: a draft that
    /// succeeded must not fail because a temporary file could not be deleted, and the next run
    /// would remove a leftover anyway.
    static func discardTranscript(sessionID: UUID, scratch: URL, store: SessionHistory = SessionHistory()) {
        let manager = FileManager.default
        let projectDirectory = store.root.appendingPathComponent(
            SessionHistory.directoryName(for: scratch), isDirectory: true)

        // The whole directory: it exists only for this run, so nothing else is in it.
        try? manager.removeItem(at: projectDirectory)
        // Belt and braces, in case the CLI filed it somewhere the mangling did not predict.
        try? manager.removeItem(
            at: store.root
                .appendingPathComponent(SessionHistory.directoryName(for: scratch))
                .appendingPathComponent("\(sessionID.uuidString.lowercased()).jsonl"))
        try? manager.removeItem(at: scratch)
        discardOrphanedScratchProjects(store: store)
    }

    /// Removes scratch projects earlier runs left behind.
    ///
    /// A scratch directory belongs to exactly one drafting run, so any project directory named
    /// after one is finished by definition — including those filed under a path the mangling used
    /// to miss. Without this they accumulate in the session list as one project per draft.
    static func discardOrphanedScratchProjects(store: SessionHistory = SessionHistory()) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: store.root, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.contains("machline-commit-draft-") {
            try? manager.removeItem(at: entry)
        }
    }

    /// Extracts the structured draft from a `--output-format json` envelope.
    static func parseResponse(_ text: String) throws -> ConventionalCommit {
        guard let data = text.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { throw Failure.unusableResponse(text) }

        // The payload arrives as a JSON string in `result`; some versions nest it directly.
        let payload: JSONValue
        if let resultText = envelope["result"]?.stringValue,
           let resultData = resultText.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(JSONValue.self, from: resultData) {
            payload = decoded
        } else if let structured = envelope["structured_output"] ?? envelope["result"] {
            payload = structured
        } else {
            payload = envelope
        }

        guard let kindText = payload["kind"]?.stringValue,
              let kind = ConventionalCommit.Kind(rawValue: kindText),
              let summary = payload["summary"]?.stringValue
        else { throw Failure.unusableResponse(text) }

        let scope = payload["scope"]?.stringValue
        return ConventionalCommit(
            kind: kind,
            scope: (scope?.isEmpty ?? true) ? nil : scope,
            isBreaking: payload["isBreaking"]?.boolValue ?? false,
            summary: summary,
            body: payload["body"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
    }
}
