import Foundation

/// One configured remote, carrying the URL a push would actually reach.
///
/// `pushurl` exists precisely so fetch and push can go to different places, and it is the push URL
/// that decides whose servers see the branch — so that is the one the operator is shown before
/// publishing, not the friendlier fetch URL beside it.
public struct GitRemote: Sendable, Hashable, Identifiable {
    public let name: String
    public let fetchURL: String
    public let pushURL: String

    public var id: String { name }

    public init(name: String, fetchURL: String, pushURL: String) {
        self.name = name
        self.fetchURL = fetchURL
        self.pushURL = pushURL
    }

    /// The account or organisation the push URL belongs to, when it has one.
    ///
    /// Used to tell "my fork" from "the repository I forked", which is the difference between a
    /// routine push and publishing work-in-progress to someone else's project.
    public var owner: String? { Self.owner(ofURL: pushURL) }

    static func owner(ofURL raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix(".git") { text.removeLast(4) }

        if let scheme = text.range(of: "://") {
            // ssh://git@host/owner/repo, https://host/owner/repo
            let rest = text[scheme.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            text = String(rest[rest.index(after: slash)...])
        } else if let colon = text.firstIndex(of: ":") {
            // git@host:owner/repo
            text = String(text[text.index(after: colon)...])
        } else {
            // A local path names a directory, not an owner. Nothing useful to say.
            return nil
        }

        let parts = text.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return String(parts[parts.count - 2])
    }
}

/// How far a branch has drifted from one remote's copy of it.
public struct GitDivergence: Sendable, Hashable {
    /// Commits the local branch has that this remote does not.
    public let ahead: Int
    /// Commits this remote has that the local branch does not, as of the last fetch.
    public let behind: Int

    public init(ahead: Int, behind: Int) {
        self.ahead = ahead
        self.behind = behind
    }
}

/// What one remote made of one push.
///
/// A push to several remotes is several independent pushes — there is no transaction across them
/// and nothing to roll back — so the outcome is one of these per remote rather than a single
/// success or failure for the lot.
public struct PushResult: Sendable, Hashable, Identifiable {
    public enum Outcome: Sendable, Hashable {
        /// The remote took the commits. `isNew` when the branch did not exist there before.
        case pushed(isNew: Bool)
        case upToDate
        /// The remote refused: non-fast-forward, a protected branch, a pre-receive hook.
        case rejected(String)
        /// Never got as far as a decision: no such host, no credentials, no permission.
        case failed(String)
    }

    public let remote: String
    public let url: String
    public let outcome: Outcome

    public var id: String { remote }

    public var didPublish: Bool {
        if case .pushed = outcome { return true }
        return false
    }

    public var isFailure: Bool {
        switch outcome {
        case .rejected, .failed: return true
        case .pushed, .upToDate: return false
        }
    }

    public init(remote: String, url: String, outcome: Outcome) {
        self.remote = remote
        self.url = url
        self.outcome = outcome
    }
}

extension GitManager {

    // MARK: - Remotes

    /// Every remote, in the order the config defines them.
    ///
    /// Read from config rather than `git remote -v`: that sorts alphabetically and needs a second
    /// call per remote to resolve `pushurl`, where one `--get-regexp` answers both in definition
    /// order — which is the order the operator wrote and so the order to show back.
    public func remotes() throws -> [GitRemote] {
        let output = try runner.run(["config", "--get-regexp", #"^remote\..*\.(url|pushurl)$"#])
        // Exit 1 means no key matched, which is a repository with no remotes rather than a failure.
        guard output.succeeded || output.exitCode == 1 else {
            throw GitRunner.Failure.commandFailed(
                arguments: ["config", "--get-regexp"],
                exitCode: output.exitCode,
                standardError: output.standardError)
        }

        var order: [String] = []
        var fetchURLs: [String: String] = [:]
        var pushURLs: [String: String] = [:]

        for line in output.text.split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            let key = String(line[line.startIndex..<space])
            let value = String(line[line.index(after: space)...])
                .trimmingCharacters(in: .whitespaces)
            guard value.isEmpty == false else { continue }

            // remote.<name>.url — and a name may itself contain dots, so take the outer fields.
            guard key.hasPrefix("remote.") else { continue }
            let suffix: String
            if key.hasSuffix(".pushurl") {
                suffix = ".pushurl"
            } else if key.hasSuffix(".url") {
                suffix = ".url"
            } else {
                continue
            }
            let name = String(key.dropFirst("remote.".count).dropLast(suffix.count))
            guard !name.isEmpty else { continue }

            if !order.contains(name) { order.append(name) }
            if suffix == ".pushurl" {
                // Several push URLs on one remote is a fan-out git does itself; the first names it.
                if pushURLs[name] == nil { pushURLs[name] = value }
            } else if fetchURLs[name] == nil {
                fetchURLs[name] = value
            }
        }

        return order.map { name in
            let fetch = fetchURLs[name] ?? pushURLs[name] ?? ""
            return GitRemote(name: name, fetchURL: fetch, pushURL: pushURLs[name] ?? fetch)
        }
    }

    /// The remote a plain `git push` would reach for this branch.
    ///
    /// Follows git's own resolution order, so Machline pushes where the command line would. The
    /// last two steps are Machline's: a repository with one remote has an unambiguous answer even
    /// when nothing is configured, and `origin` is the convention when it exists.
    public func pushTarget(for branch: String, remotes known: [GitRemote]? = nil) -> String? {
        let remotes = known ?? ((try? self.remotes()) ?? [])
        let names = Set(remotes.map(\.name))

        for key in [
            "branch.\(branch).pushRemote",
            "remote.pushDefault",
            "branch.\(branch).remote",
        ] {
            if let value = try? configValue(key), names.contains(value) { return value }
        }

        if remotes.count == 1 { return remotes[0].name }
        return names.contains("origin") ? "origin" : nil
    }

    /// How this branch stands against one remote's copy of it, or `nil` when that remote has no
    /// such branch — which is the answer for a branch that has never been pushed there.
    ///
    /// Reads remote-tracking refs only. Whatever they say is as fresh as the last fetch; this does
    /// not go to the network.
    public func divergence(of branch: String, from remote: String) -> GitDivergence? {
        let output = try? runner.run([
            "rev-list", "--left-right", "--count",
            "refs/remotes/\(remote)/\(branch)...refs/heads/\(branch)",
        ])
        guard let output, output.succeeded else { return nil }
        let fields = output.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "\t" || $0 == " " })
        guard fields.count == 2, let behind = Int(fields[0]), let ahead = Int(fields[1]) else {
            return nil
        }
        return GitDivergence(ahead: ahead, behind: behind)
    }

    // MARK: - Push

    /// Publishes one branch to each of these remotes, concurrently.
    ///
    /// Does not throw and does not stop early. The remotes are independent: a branch rejected by
    /// one as non-fast-forward says nothing about the next, and abandoning the run there would
    /// leave the operator both half-published and short of the information to finish. Every remote
    /// gets its own line in the answer, in the order the remotes were given.
    ///
    /// Concurrent because these are network round trips with nothing to share: run in turn, a
    /// mirror on a slow host makes the operator wait for it before the fast one is even attempted,
    /// and the panel sits on a spinner for the sum rather than the slowest. Each `git push` is its
    /// own process touching its own `refs/remotes/<name>/…`, so there is no lock they contend for.
    ///
    /// `setUpstreamOn` may name at most one of them. A branch has a single upstream, so passing
    /// `--set-upstream` to each in turn would let the last remote quietly redefine what the panel's
    /// ahead and behind counts are measured against. That one push runs alone and first: it is the
    /// only one that writes `.git/config`, and a push racing that write can fail on the config lock
    /// having had nothing to say about the branch at all.
    public func push(
        branch: String, to remotes: [GitRemote], setUpstreamOn primary: String?
    ) -> [PushResult] {
        let leader = remotes.firstIndex { $0.name == primary }
        let results = PushResults(count: remotes.count)
        if let leader {
            results.record(push(branch: branch, to: remotes[leader], setsUpstream: true), at: leader)
        }

        let rest = remotes.indices.filter { $0 != leader }
        DispatchQueue.concurrentPerform(iterations: rest.count) { position in
            let index = rest[position]
            results.record(push(branch: branch, to: remotes[index], setsUpstream: false), at: index)
        }

        return results.ordered
    }

    /// One slot per remote, filled by whichever thread finishes that push.
    ///
    /// A lock rather than distinct indices alone: concurrent writes into one `Array` are a data
    /// race whichever elements they land on, since the buffer itself is shared mutable state.
    private final class PushResults: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [PushResult?]

        init(count: Int) {
            values = Array(repeating: nil, count: count)
        }

        func record(_ result: PushResult, at index: Int) {
            lock.lock()
            values[index] = result
            lock.unlock()
        }

        /// The results that arrived, in the order the remotes were given.
        var ordered: [PushResult] {
            lock.lock()
            defer { lock.unlock() }
            return values.compactMap { $0 }
        }
    }

    private func push(
        branch: String, to remote: GitRemote, setsUpstream: Bool
    ) -> PushResult {
        // An explicit refspec rather than the bare branch name: `push.default` is per repository,
        // not per remote, and the operator asked for this branch by name.
        var arguments = ["push", "--porcelain"]
        if setsUpstream { arguments.append("--set-upstream") }
        arguments += [remote.name, "refs/heads/\(branch):refs/heads/\(branch)"]

        guard let output = try? runner.run(arguments) else {
            return PushResult(
                remote: remote.name, url: remote.pushURL,
                outcome: .failed("Could not run git."))
        }
        return PushResult(
            remote: remote.name,
            url: remote.pushURL,
            outcome: Self.outcome(
                porcelain: output.text,
                standardError: output.standardError,
                exitCode: output.exitCode))
    }

    /// Reads `git push --porcelain` output.
    ///
    /// The porcelain form is `<flag>\t<from>:<to>\t<summary>`, one line per ref, and the flag is
    /// the whole verdict: `=` unchanged, `*` newly created, `!` refused, space or `+` moved. Parsed
    /// rather than the human text, which is localised prose written for a terminal.
    static func outcome(
        porcelain text: String, standardError: String, exitCode: Int32
    ) -> PushResult.Outcome {
        var sawUpToDate = false
        var created = false
        var moved = false

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            let summary = String(fields[2])
            switch fields[0] {
            case "!": return .rejected(summary.isEmpty ? "rejected" : summary)
            case "=": sawUpToDate = true
            case "*": created = true
            default: moved = true
            }
        }

        if exitCode != 0 {
            let message = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(message.isEmpty ? "git push exited \(exitCode)" : message)
        }
        if created || moved { return .pushed(isNew: created) }
        if sawUpToDate { return .upToDate }
        // Zero refs reported and a clean exit: nothing was there to send.
        return .upToDate
    }
}
