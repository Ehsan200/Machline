import Foundation
import Testing
@testable import HarnessCore

/// Which remotes a push reaches, and what each of them said about it.
///
/// Driven against real repositories and real bare remotes on disk rather than mocked: the whole
/// point of the feature is that pushing to two places is two independent conversations, and only
/// git can be trusted to reproduce what a second one does when the first has already succeeded.
struct PushTargetTests {

    // MARK: - Remotes

    @Test("Remotes come back in config order, not alphabetically")
    func remotesKeepConfigOrder() throws {
        let repository = try GitTestRepository()
        try repository.manager.runner.check(["remote", "add", "zeta", "https://host/me/zeta.git"])
        try repository.manager.runner.check(["remote", "add", "alpha", "https://host/me/alpha.git"])

        #expect(try repository.manager.remotes().map(\.name) == ["zeta", "alpha"])
    }

    /// `pushurl` exists so fetch and push can differ, and it is the push URL that decides who sees
    /// the branch — so it is the one the panel shows.
    @Test("A pushurl overrides the fetch URL for pushing, and only for pushing")
    func pushURLOverridesFetchURL() throws {
        let repository = try GitTestRepository()
        try repository.manager.runner.check(["remote", "add", "origin", "https://host/me/x.git"])
        try repository.manager.runner.check([
            "config", "remote.origin.pushurl", "git@host:me/mirror.git",
        ])

        let remote = try #require(try repository.manager.remotes().first)
        #expect(remote.fetchURL == "https://host/me/x.git")
        #expect(remote.pushURL == "git@host:me/mirror.git")
    }

    @Test("A repository with no remotes reports none rather than failing")
    func noRemotes() throws {
        // Bound to a local on purpose: the fixture deletes its directory in `deinit`, so a
        // temporary would be gone before git was asked anything.
        let repository = try GitTestRepository()
        #expect(try repository.manager.remotes().isEmpty)
    }

    // MARK: - Owner

    /// Drives the "not your account" warning, which is what separates pushing to your fork from
    /// publishing work-in-progress to the project you forked.
    @Test("An owner is read from every URL form git accepts")
    func ownerParsing() {
        #expect(GitRemote.owner(ofURL: "git@github.com:vendor/product.git") == "vendor")
        #expect(GitRemote.owner(ofURL: "https://github.com/vendor/product.git") == "vendor")
        #expect(GitRemote.owner(ofURL: "https://github.com/vendor/product") == "vendor")
        #expect(GitRemote.owner(ofURL: "ssh://git@github.com/vendor/product.git") == "vendor")
        #expect(GitRemote.owner(ofURL: "https://host/team/group/product.git") == "group")
    }

    /// A local path names a directory, not an account. Guessing an owner there would warn about
    /// every ordinary local remote.
    @Test("A local path has no owner")
    func localPathHasNoOwner() {
        #expect(GitRemote.owner(ofURL: "/Users/me/mirrors/product.git") == nil)
        #expect(GitRemote.owner(ofURL: "../sibling.git") == nil)
    }

    // MARK: - Push target resolution

    @Test("A single remote is the target whatever it is called")
    func singleRemoteWins() throws {
        let repository = try GitTestRepository()
        try repository.manager.runner.check(["remote", "add", "upstream", "https://host/v/p.git"])

        #expect(repository.manager.pushTarget(for: "main") == "upstream")
    }

    /// The old behaviour pushed to the literal `origin`, which a fork calling its remotes
    /// `upstream` and `fork` does not have.
    @Test("With several remotes and no configuration, origin is the convention")
    func originIsTheDefault() throws {
        let repository = try GitTestRepository()
        try repository.manager.runner.check(["remote", "add", "upstream", "https://host/v/p.git"])
        try repository.manager.runner.check(["remote", "add", "origin", "https://host/me/p.git"])

        #expect(repository.manager.pushTarget(for: "main") == "origin")
    }

    @Test("Several remotes with no origin and no configuration have no answer")
    func noAnswerWithoutOrigin() throws {
        let repository = try GitTestRepository()
        try repository.manager.runner.check(["remote", "add", "upstream", "https://host/v/p.git"])
        try repository.manager.runner.check(["remote", "add", "fork", "https://host/me/p.git"])

        #expect(repository.manager.pushTarget(for: "main") == nil)
    }

    /// Git's own order, so Machline pushes where the command line would.
    @Test("pushRemote beats pushDefault beats the tracking remote")
    func resolutionOrder() throws {
        let repository = try GitTestRepository()
        for name in ["origin", "mirror", "elsewhere"] {
            try repository.manager.runner.check(["remote", "add", name, "https://host/me/\(name)"])
        }

        try repository.manager.runner.check(["config", "branch.main.remote", "elsewhere"])
        #expect(repository.manager.pushTarget(for: "main") == "elsewhere")

        try repository.manager.runner.check(["config", "remote.pushDefault", "mirror"])
        #expect(repository.manager.pushTarget(for: "main") == "mirror")

        try repository.manager.runner.check(["config", "branch.main.pushRemote", "origin"])
        #expect(repository.manager.pushTarget(for: "main") == "origin")
    }

    /// A stale config key naming a deleted remote is not a target; falling through beats failing.
    @Test("A configured remote that no longer exists is ignored")
    func staleConfigurationIgnored() throws {
        let repository = try GitTestRepository()
        try repository.manager.runner.check(["remote", "add", "origin", "https://host/me/p.git"])
        try repository.manager.runner.check(["remote", "add", "mirror", "https://host/me/m.git"])
        try repository.manager.runner.check(["config", "remote.pushDefault", "deleted"])

        #expect(repository.manager.pushTarget(for: "main") == "origin")
    }

    // MARK: - Policy

    private func remotes(_ names: String...) -> [GitRemote] {
        names.map { GitRemote(name: $0, fetchURL: "https://host/\($0)", pushURL: "https://host/\($0)") }
    }

    @Test("All means every remote, primary first")
    func allPutsPrimaryFirst() {
        let targets = PushPlan.targets(
            for: .all, remotes: remotes("upstream", "origin", "mirror"), primary: "origin")
        #expect(targets.map(\.name) == ["origin", "upstream", "mirror"])
    }

    @Test("Primary only is the one remote, even among several")
    func primaryOnly() {
        let targets = PushPlan.targets(
            for: .primaryOnly, remotes: remotes("upstream", "origin"), primary: "origin")
        #expect(targets.map(\.name) == ["origin"])
    }

    @Test("A selection keeps config order behind the primary")
    func selectionOrder() {
        let targets = PushPlan.targets(
            for: .selected(["mirror", "upstream", "origin"]),
            remotes: remotes("upstream", "origin", "mirror"),
            primary: "origin")
        #expect(targets.map(\.name) == ["origin", "upstream", "mirror"])
    }

    /// A remote deleted since the policy was written simply is not there any more.
    @Test("A selection naming a remote that has gone skips it")
    func selectionSkipsMissingRemote() {
        let targets = PushPlan.targets(
            for: .selected(["origin", "deleted"]), remotes: remotes("origin"), primary: "origin")
        #expect(targets.map(\.name) == ["origin"])
    }

    /// Nothing to decide, so nothing to ask.
    @Test("One remote never opens the panel")
    func singleRemoteNeverAsks() {
        #expect(!PushPlan.needsReview(settings: nil, remotes: remotes("origin")))
    }

    @Test("Several remotes and no stored answer opens the panel")
    func unconfiguredAsks() {
        #expect(PushPlan.needsReview(settings: nil, remotes: remotes("origin", "mirror")))
    }

    /// The drift rule: `all` must not quietly grow to include a remote added a year later.
    @Test("A remote added since the answer reopens the panel, and is named")
    func driftReopensThePanel() {
        let settings = RepositoryPushSettings(policy: .all, knownRemotes: ["origin", "mirror"])
        let now = remotes("origin", "mirror", "vendor")

        #expect(PushPlan.needsReview(settings: settings, remotes: now))
        #expect(PushPlan.unreviewedRemotes(settings: settings, remotes: now) == ["vendor"])
    }

    @Test("An unchanged remote set does not ask again")
    func stableSetDoesNotAsk() {
        let settings = RepositoryPushSettings(policy: .all, knownRemotes: ["mirror", "origin"])
        #expect(!PushPlan.needsReview(settings: settings, remotes: remotes("origin", "mirror")))
    }

    /// A removal is a stale stored set too, so the panel confirms it once — but only while there
    /// is still a choice. Down to one remote there is nothing to decide and nothing to ask.
    @Test("A removed remote reopens the panel, naming nothing new")
    func removalReopensThePanel() {
        let settings = RepositoryPushSettings(
            policy: .all, knownRemotes: ["origin", "mirror", "vendor"])
        let now = remotes("origin", "mirror")
        #expect(PushPlan.needsReview(settings: settings, remotes: now))
        #expect(PushPlan.unreviewedRemotes(settings: settings, remotes: now).isEmpty)
    }

    @Test("A repository down to one remote stops asking, whatever it used to have")
    func removalDownToOneRemoteNeverAsks() {
        let settings = RepositoryPushSettings(policy: .all, knownRemotes: ["origin", "mirror"])
        #expect(!PushPlan.needsReview(settings: settings, remotes: remotes("origin")))
    }

    @Test("A policy survives a round trip through JSON")
    func policyRoundTrips() throws {
        let original = RepositoryPushSettings(
            policy: .selected(["origin", "mirror"]), knownRemotes: ["origin", "mirror", "vendor"])
        let decoded = try JSONDecoder().decode(
            RepositoryPushSettings.self, from: try JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    // MARK: - Porcelain parsing

    @Test("A fast-forward reads as pushed")
    func porcelainFastForward() {
        let outcome = GitManager.outcome(
            porcelain: "To git@host:me/x.git\n \trefs/heads/main:refs/heads/main\tabc123..def456\nDone\n",
            standardError: "", exitCode: 0)
        #expect(outcome == .pushed(isNew: false))
    }

    @Test("A branch the remote did not have reads as created")
    func porcelainNewBranch() {
        let outcome = GitManager.outcome(
            porcelain: "To git@host:me/x.git\n*\trefs/heads/main:refs/heads/main\t[new branch]\nDone\n",
            standardError: "", exitCode: 0)
        #expect(outcome == .pushed(isNew: true))
    }

    @Test("Nothing to send reads as up to date")
    func porcelainUpToDate() {
        let outcome = GitManager.outcome(
            porcelain: "To git@host:me/x.git\n=\trefs/heads/main:refs/heads/main\t[up to date]\nDone\n",
            standardError: "", exitCode: 0)
        #expect(outcome == .upToDate)
    }

    /// The remote's own words. "non-fast-forward" and "protected branch" need different fixes and
    /// only the remote knows which it was.
    @Test("A refusal keeps the remote's reason")
    func porcelainRejected() {
        let outcome = GitManager.outcome(
            porcelain: "To git@host:me/x.git\n!\trefs/heads/main:refs/heads/main\t[rejected] (non-fast-forward)\nDone\n",
            standardError: "hint: Updates were rejected\n", exitCode: 1)
        #expect(outcome == .rejected("[rejected] (non-fast-forward)"))
    }

    /// Never got as far as a verdict: no host, no credentials, no permission.
    @Test("A failure with no ref lines falls back to what git said")
    func porcelainFailedBeforeAnyRef() {
        let outcome = GitManager.outcome(
            porcelain: "", standardError: "fatal: could not read from remote repository\n",
            exitCode: 128)
        #expect(outcome == .failed("fatal: could not read from remote repository"))
    }

    // MARK: - Pushing for real

    /// Two bare repositories on disk, one push, two independent answers.
    @Test("A push to two remotes reaches both, and sets upstream on one")
    func pushesToEveryRemote() throws {
        let repository = try GitTestRepository()
        try repository.write("hello", to: "file.txt")
        try repository.commit("initial")

        let first = try Self.bareRemote(named: "first")
        let second = try Self.bareRemote(named: "second")
        defer { try? FileManager.default.removeItem(at: first) }
        defer { try? FileManager.default.removeItem(at: second) }
        try repository.manager.runner.check(["remote", "add", "origin", first.path])
        try repository.manager.runner.check(["remote", "add", "mirror", second.path])

        let remotes = try repository.manager.remotes()
        let results = repository.manager.push(
            branch: "main", to: remotes, setUpstreamOn: "origin")

        #expect(results.map(\.remote) == ["origin", "mirror"])
        #expect(results.allSatisfy { $0.outcome == .pushed(isNew: true) })

        // Exactly one upstream, on the remote that was named.
        let upstream = try repository.manager.runner.run(
            ["rev-parse", "--abbrev-ref", "main@{upstream}"]).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(upstream == "origin/main")

        for remote in [first, second] {
            let bare = GitManager(workingDirectory: remote)
            let head = try bare.runner.check(["rev-parse", "refs/heads/main"]).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(!head.isEmpty)
        }
    }

    /// The reason the result is a list. One remote refusing says nothing about the next, and
    /// stopping there would leave the operator half-published and short of the information to
    /// finish.
    @Test("One remote refusing does not stop the others")
    func rejectionDoesNotStopTheRun() throws {
        let repository = try GitTestRepository()
        try repository.write("hello", to: "file.txt")
        try repository.commit("initial")

        let good = try Self.bareRemote(named: "good")
        let diverged = try Self.bareRemote(named: "diverged")
        defer { try? FileManager.default.removeItem(at: good) }
        defer { try? FileManager.default.removeItem(at: diverged) }

        // Give the second remote a `main` this repository knows nothing about, so the push to it
        // is a non-fast-forward while the first remote takes the branch happily.
        let seed = try GitTestRepository()
        try seed.write("theirs", to: "other.txt")
        try seed.commit("unrelated")
        try seed.manager.runner.check(["push", diverged.path, "main"])

        try repository.manager.runner.check(["remote", "add", "rejects", diverged.path])
        try repository.manager.runner.check(["remote", "add", "accepts", good.path])

        let results = repository.manager.push(
            branch: "main",
            to: try repository.manager.remotes(),
            setUpstreamOn: "accepts")

        let byName = Dictionary(uniqueKeysWithValues: results.map { ($0.remote, $0.outcome) })
        #expect(results.count == 2)
        if case .rejected = byName["rejects"] {} else {
            Issue.record("expected a rejection from the diverged remote, got \(byName["rejects"]!)")
        }
        #expect(byName["accepts"] == .pushed(isNew: true))
    }

    /// The counts the panel shows are per remote, which is the whole reason a fork needs the panel:
    /// three ahead of your own remote and forty behind the one you forked.
    @Test("Divergence is measured against each remote separately")
    func divergencePerRemote() throws {
        let repository = try GitTestRepository()
        try repository.write("one", to: "file.txt")
        try repository.commit("first")

        let ahead = try Self.bareRemote(named: "ahead")
        defer { try? FileManager.default.removeItem(at: ahead) }
        try repository.manager.runner.check(["remote", "add", "origin", ahead.path])
        try repository.manager.runner.check(["push", "origin", "main"])

        // A commit the remote has not seen.
        try repository.write("two", to: "file.txt")
        try repository.commit("second")
        try repository.manager.runner.check(["fetch", "origin"])

        let divergence = try #require(repository.manager.divergence(of: "main", from: "origin"))
        #expect(divergence.ahead == 1)
        #expect(divergence.behind == 0)
    }

    /// A branch never pushed to a remote has no copy there to compare against, which the panel says
    /// rather than showing a misleading zero.
    @Test("A remote with no copy of the branch has no divergence")
    func divergenceMissingRemoteBranch() throws {
        let repository = try GitTestRepository()
        try repository.write("one", to: "file.txt")
        try repository.commit("first")
        try repository.manager.runner.check(["remote", "add", "origin", "https://host/me/x.git"])

        #expect(repository.manager.divergence(of: "main", from: "origin") == nil)
    }

    private static func bareRemote(named name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("harness-remote-\(name)-\(UUID().uuidString.prefix(8)).git")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try GitRunner(workingDirectory: url).check(["init", "--bare", "--initial-branch=main"])
        return url
    }
}
