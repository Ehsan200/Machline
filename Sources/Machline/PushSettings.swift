import Foundation
import HarnessCore
import Observation

/// Per-repository push policies, for the process.
///
/// Kept in `UserDefaults` rather than in each repository's `.git/config`. A `machline.pushPolicy`
/// key would travel with the tree and survive a move, but it writes a Machline preference into a
/// file that is shared, diffed, and not Machline's to edit. The cost of keying by path is one extra
/// panel after a repository moves.
///
/// The store only remembers; `PushPlan` in HarnessCore decides what a remembered answer means for
/// the remotes a repository has today.
@MainActor
@Observable
final class PushSettings {
    static let shared = PushSettings()

    private static let defaultsKey = "pushPolicies"

    private let defaults: UserDefaults
    private(set) var byRepository: [String: RepositoryPushSettings]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode(
               [String: RepositoryPushSettings].self, from: data) {
            byRepository = stored
        } else {
            byRepository = [:]
        }
    }

    func settings(for repository: URL) -> RepositoryPushSettings? {
        byRepository[Self.key(repository)]
    }

    func store(_ policy: PushPolicy, remotes: [String], for repository: URL) {
        byRepository[Self.key(repository)] = RepositoryPushSettings(
            policy: policy, knownRemotes: remotes)
        persist()
    }

    func forget(_ repository: URL) {
        guard byRepository.removeValue(forKey: Self.key(repository)) != nil else { return }
        persist()
    }

    func needsReview(for repository: URL, remotes: [GitRemote]) -> Bool {
        PushPlan.needsReview(settings: settings(for: repository), remotes: remotes)
    }

    func unreviewedRemotes(for repository: URL, remotes: [GitRemote]) -> [String] {
        PushPlan.unreviewedRemotes(settings: settings(for: repository), remotes: remotes)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(byRepository) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func key(_ repository: URL) -> String {
        repository.standardizedFileURL.path
    }
}
