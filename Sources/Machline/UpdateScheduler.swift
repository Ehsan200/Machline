import Foundation
import Observation

/// Decides when the app asks GitHub whether there is a newer release.
///
/// The check is this app's only outbound request, so putting it on a schedule is a change of
/// character rather than a convenience: something now happens over the network that the operator
/// did not press. Three things keep it honest — at most one request a day however often the app is
/// launched, a menu toggle that turns it off for good, and the same code path as the manual check,
/// so an automatic answer cannot install anything a asked-for one would not.
///
/// One instance for the process. Every window and tab has its own `AppModel`, and each of them can
/// run the check; without a single owner, opening four windows would ask four times.
@MainActor
@Observable
final class UpdateScheduler {
    static let shared = UpdateScheduler()

    private static let enabledKey = "automaticUpdateChecks"
    private static let lastCheckKey = "lastAutomaticUpdateCheck"

    /// The most often the app will ask, however long it stays open or how often it is relaunched.
    private static let interval: TimeInterval = 24 * 60 * 60
    /// How often the schedule wakes to see whether the interval has passed. A long-running app has
    /// to notice the day turning over without the operator quitting it.
    private static let wake: TimeInterval = 60 * 60

    private let defaults: UserDefaults
    // Bookkeeping rather than interface, and deliberately outside observation. Every `AppModel`
    // registers itself from its own initialiser, so an observed `models` made that registration
    // an invalidation — and a model built while the window was updating then invalidated the very
    // update that had built it. The window rebuilt, built another model, registered it, and the
    // main thread went round that loop forever.
    @ObservationIgnored private var models: [WeakModel] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // On by default, so a build that can update itself does. `bool(forKey:)` is `false` for a
        // key that was never written, which would make the default off by accident rather than by
        // decision.
        defaults.register(defaults: [Self.enabledKey: true])
        isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            // Turning it on mid-run should not wait for the next wake-up.
            if isEnabled { checkIfDue() }
        }
    }

    /// When the app last asked on its own. The manual check deliberately does not reset this: an
    /// operator who checks by hand has not asked to be checked *for*.
    var lastAutomaticCheck: Date? { defaults.object(forKey: Self.lastCheckKey) as? Date }

    /// Adopts a model as somewhere to run a check and show its answer.
    ///
    /// Held weakly: a closed window's model must not be kept alive by the schedule, and must not be
    /// the one a check is handed to once its banner can no longer be seen.
    func register(_ model: AppModel) {
        models.removeAll { $0.value == nil }
        guard !models.contains(where: { $0.value === model }) else { return }
        models.append(WeakModel(value: model))
    }

    /// Starts the schedule. Called once, at launch.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.checkIfDue()
                try? await Task.sleep(for: .seconds(Self.wake))
            }
        }
    }

    /// Runs the check if it is enabled, due, and there is a window to show the answer in.
    ///
    /// A window is required rather than optional: the answer to "is there a new version" is a
    /// banner, and a check whose answer nothing can present is a request made for no one. The first
    /// window that opens picks it up on the next wake-up.
    func checkIfDue() {
        guard isEnabled else { return }
        guard let model = models.compactMap(\.value).first else { return }
        if let last = lastAutomaticCheck, Date().timeIntervalSince(last) < Self.interval { return }

        // Recorded before the check rather than after it: a check that fails should not have the
        // app retrying every wake-up for the rest of the day.
        defaults.set(Date(), forKey: Self.lastCheckKey)
        model.updates.check()
    }

    private struct WeakModel {
        weak var value: AppModel?
    }
}
