import Foundation

/// What Push does in one repository.
///
/// Per git tree, not per workspace: a projects folder holds repositories with entirely different
/// remote arrangements, and "push everywhere" is a sane answer for a personal repo mirrored to two
/// hosts and a dangerous one for a fork of somebody else's project.
public enum PushPolicy: Codable, Sendable, Equatable {
    /// Every remote the tree has — including ones added after this was chosen, which is why the
    /// stored settings also remember the remotes that existed at the time.
    case all
    /// Only the remote a plain `git push` would reach.
    case primaryOnly
    /// Named remotes. Names rather than URLs: a remote that is re-pointed is still that remote.
    case selected([String])
}

/// A repository's answer, and what it was answering about.
public struct RepositoryPushSettings: Codable, Sendable, Equatable {
    public var policy: PushPolicy
    /// The remotes that existed when the operator chose.
    ///
    /// Without this, `all` grows silently: add a company mirror a year later and the next push
    /// publishes to it having never been asked. A change here reopens the panel once.
    public var knownRemotes: [String]

    public init(policy: PushPolicy, knownRemotes: [String]) {
        self.policy = policy
        self.knownRemotes = knownRemotes
    }
}

/// Turns a policy and a set of remotes into the list of remotes a push will actually reach.
///
/// Pure, and separate from where the policy is stored: the decision of what "all" means today is
/// the part worth testing, and it should not need a `UserDefaults` to exercise.
public enum PushPlan {

    /// The remotes a policy resolves to, primary first.
    ///
    /// Primary leads so `--set-upstream` runs before anything else: if a later remote fails, the
    /// branch is still tracking the one it should be, and the counts in the panel still mean what
    /// they say.
    public static func targets(
        for policy: PushPolicy, remotes: [GitRemote], primary: String?
    ) -> [GitRemote] {
        let chosen: [GitRemote]
        switch policy {
        case .all:
            chosen = remotes
        case .primaryOnly:
            chosen = remotes.filter { $0.name == primary }
        case .selected(let names):
            let wanted = Set(names)
            // Filtered from `remotes` rather than mapped from `names`: a remote deleted since the
            // policy was written simply is not there any more, and skipping it beats failing.
            chosen = remotes.filter { wanted.contains($0.name) }
        }
        // Partitioned rather than sorted: "primary first, everything else in config order" is not
        // a total ordering, and `sorted(by:)` given a predicate that isn't one may shuffle the rest.
        return chosen.filter { $0.name == primary } + chosen.filter { $0.name != primary }
    }

    /// Whether a push has to stop and ask.
    ///
    /// Three reasons: never configured, the set of remotes has changed since it was, or there is
    /// only one remote — in which case there is nothing to decide and the caller skips the panel
    /// rather than showing one with a single locked row.
    public static func needsReview(
        settings: RepositoryPushSettings?, remotes: [GitRemote]
    ) -> Bool {
        guard remotes.count > 1 else { return false }
        guard let settings else { return true }
        return Set(settings.knownRemotes) != Set(remotes.map(\.name))
    }

    /// Remotes present now that were not there when the policy was set.
    public static func unreviewedRemotes(
        settings: RepositoryPushSettings?, remotes: [GitRemote]
    ) -> [String] {
        guard let settings else { return [] }
        let known = Set(settings.knownRemotes)
        return remotes.map(\.name).filter { !known.contains($0) }
    }
}
