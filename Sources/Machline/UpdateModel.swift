import AppKit
import HarnessCore
import SwiftUI

/// Checking for a new build, fetching it, and swapping this one out for it.
///
/// Held by `AppModel` but kept apart from it: none of this is about a session, and a model that
/// owns both was carrying the whole update lifecycle in the middle of the conversation state.
/// The one thing it needs from its host is whether quitting right now would cost a turn.
@MainActor
@Observable
final class UpdateModel {

    /// This build's version, as stamped by the release workflow.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private static var repository: String? {
        Bundle.main.object(forInfoDictionaryKey: "MachlineUpdateRepository") as? String
    }

    /// Whether quitting now would throw away work. Set by the host; installing means quitting.
    @ObservationIgnored var isHostBusy: () -> Bool = { false }

    private(set) var outcome: UpdateCheck.Outcome?
    private(set) var isChecking = false

    // MARK: Checking

    /// Asks GitHub whether there is a newer release.
    ///
    /// This is the app's single outbound network request. It runs when asked — the menu item, the
    /// version badge — and, unless the operator turns that off, once a day on its own; the daily
    /// one comes through here rather than through a path of its own, so an unattended answer can
    /// install nothing an asked-for one would not. See `UpdateScheduler` for when it fires.
    func check() {
        guard !isChecking else { return }
        // A transfer belongs to the offer that started it. Re-checking mid-download would replace
        // that offer underneath it and take its Cancel button off the banner, leaving a transfer
        // running with nothing able to stop it; the badge waits instead.
        if case .running = download { return }
        // A finished or failed transfer belonged to the previous answer, so the new one starts clean.
        download = .idle
        isChecking = true
        let check = UpdateCheck(repository: Self.repository, currentVersion: Self.appVersion)
        Task { [weak self] in
            let outcome = await check.run()
            guard let self else { return }
            self.outcome = outcome
            self.isChecking = false
            // The answer to "is there a new version" is only ever followed by "then get it", so
            // the transfer starts itself. Nothing is replaced until it has arrived and matched its
            // digest, and the banner can still cancel it.
            if case .available(let release) = outcome, release.asset != nil {
                self.startDownload(release)
            }
        }
    }

    func dismissNotice() {
        outcome = nil
        cancelDownload()
        download = .idle
    }

    // MARK: Downloading a release

    /// Where the new build has got to.
    ///
    /// Downloading it here rather than in a browser is the whole point: the operator asked for an
    /// update, and being handed a web page instead is an errand. `finished` is the same errand one
    /// step later, so it is only where a build stops when the app cannot replace itself — see
    /// `UpdateInstaller`.
    enum Download: Equatable {
        case idle
        case running(Double)
        case finished(URL)
        /// The swap script is running and the app is quitting; it comes back on the new version.
        case installing
        case failed(String)
    }

    private(set) var download: Download = .idle
    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    /// The release currently on offer, when it has a build attached to download.
    var downloadableRelease: UpdateCheck.Release? {
        guard case .available(let release) = outcome, release.asset != nil else { return nil }
        return release
    }

    func startDownload(_ release: UpdateCheck.Release) {
        guard let asset = release.asset else { return }
        guard downloadTask == nil else { return }

        download = .running(0)
        // Progress arrives on whatever thread the transfer is running on, so it is funnelled
        // through a stream and applied here. The newest value is the only one worth keeping — a
        // buffer of stale percentages would just animate the bar through the past.
        let (progress, publish) = AsyncStream<Double>.makeStream(bufferingPolicy: .bufferingNewest(1))

        downloadTask = Task { [weak self] in
            let reader = Task { @MainActor [weak self] in
                for await fraction in progress {
                    guard let self, case .running = self.download else { continue }
                    self.download = .running(fraction)
                }
            }
            defer { reader.cancel() }

            let transfer = ReleaseDownload(asset: asset)
            do {
                let file = try await transfer.run { publish.yield($0) }
                publish.finish()
                await MainActor.run {
                    self?.download = .finished(file)
                    self?.downloadTask = nil
                    self?.installIfUnattended()
                }
            } catch {
                publish.finish()
                let message = Self.describe(downloadError: error)
                await MainActor.run {
                    // A cancelled download is not a failure to report; it is what was asked for.
                    self?.download = Task.isCancelled ? .idle : .failed(message)
                    self?.downloadTask = nil
                }
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        if case .running = download { download = .idle }
    }

    /// Retry is a fresh attempt, not a resumed one: the partial file was already discarded.
    func retryDownload() {
        guard let release = downloadableRelease else { return }
        download = .idle
        startDownload(release)
    }

    func revealDownload() {
        guard case .finished(let file) = download else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    /// Opens the disk image, for the build that cannot replace itself — the operator drags it over.
    func openDownload() {
        guard case .finished(let file) = download else { return }
        NSWorkspace.shared.open(file)
    }

    // MARK: Installing it

    /// Whether this build is running from a bundle it can replace.
    ///
    /// False under `swift run` and for a bare binary, where there is no `.app` to swap and the
    /// download is only ever something to hand over.
    var canInstall: Bool { UpdateInstaller.isInstallable }

    /// Installs as soon as the download lands, unless a session is mid-turn.
    ///
    /// Installing means quitting, and quitting on top of a running agent throws away the turn it
    /// was in the middle of. So the automatic path is for an idle app; a busy one holds the build
    /// and puts the decision on the banner, where the operator can see what it costs.
    private func installIfUnattended() {
        guard canInstall, !isHostBusy() else { return }
        install()
    }

    /// Replaces this bundle with the downloaded build and relaunches.
    ///
    /// The swap itself happens after this process exits — see `UpdateInstaller` — so the quit is
    /// part of the operation rather than something that follows it. A build that cannot replace
    /// itself falls back to opening the disk image.
    func install() {
        guard case .finished(let file) = download else { return }
        guard let installer = try? UpdateInstaller() else {
            openDownload()
            return
        }

        do {
            try installer.install(from: file)
        } catch {
            download = .failed(Self.describe(installError: error))
            return
        }

        download = .installing
        // The script is already counting this process down, so nothing may delay the quit — a
        // confirmation sheet here would be a dialog the update is waiting on.
        NSApplication.shared.terminate(nil)
    }

    // MARK: Failure prose

    static func describe(installError error: Error) -> String {
        guard let failure = error as? UpdateInstaller.Failure else {
            return "The update could not be installed."
        }
        switch failure {
        case .notBundled:
            return "This build is not running from an app bundle, so it cannot replace itself."
        case .unpack(let message):
            return "Could not open the downloaded build: \(message)"
        case .noApplication(let message):
            return message
        case .launch(let message):
            return "Could not start the installer: \(message)"
        }
    }

    static func describe(downloadError error: Error) -> String {
        guard let failure = error as? ReleaseDownload.Failure else {
            return "The download did not finish."
        }
        switch failure {
        case .http(let status):
            return "GitHub answered \(status) for the download."
        case .unreachable:
            return "Could not reach GitHub to download the release."
        case .digestMismatch:
            return "The download did not match the checksum GitHub published, so it was discarded."
        case .write(let message):
            return "Could not save the download: \(message)"
        }
    }
}
