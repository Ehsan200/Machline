import Foundation
import Observation

/// Projects the operator has removed from the app's lists, for good.
///
/// Forgetting a recent entry does not remove anything for long: the project menu is the union of
/// what this app has opened and every project the CLI holds a transcript for, so the next scan of
/// `~/.claude/projects` puts a forgotten project straight back. This is the half that sticks — a
/// removed path stays out of every list until it is restored, or until the operator opens that
/// directory deliberately, which counts as asking for it back.
///
/// Stored as standardized paths, not bookmarks. A bookmark to a directory that has since been
/// deleted or renamed stops resolving, and a removal that cannot be resolved is a removal that
/// quietly undoes itself — while the common reason to remove a project is precisely that the
/// directory is gone. A path still names it.
///
/// One instance for the process. Every window and tab has its own `AppModel`, and a removal made in
/// one of them has to be a removal in all of them rather than in whichever one was in front.
@MainActor
@Observable
final class HiddenProjects {
    static let shared = HiddenProjects()

    private static let defaultsKey = "hiddenProjects"

    private let defaults: UserDefaults
    private(set) var paths: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        paths = Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    var count: Int { paths.count }

    func contains(_ url: URL) -> Bool { paths.contains(Self.path(of: url)) }

    func hide(_ url: URL) {
        paths.insert(Self.path(of: url))
        persist()
    }

    func show(_ url: URL) {
        guard paths.remove(Self.path(of: url)) != nil else { return }
        persist()
    }

    func showAll() {
        guard !paths.isEmpty else { return }
        paths = []
        persist()
    }

    private func persist() {
        defaults.set(paths.sorted(), forKey: Self.defaultsKey)
    }

    private static func path(of url: URL) -> String { url.standardizedFileURL.path }
}
