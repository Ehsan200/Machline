import Foundation

/// Looks for a newer release on GitHub.
///
/// Deliberately a *check*, not an updater. Sparkle-style self-replacement is only safe when the
/// downloaded bundle can be verified against an identity the operating system trusts, and Machline
/// is ad-hoc signed — so an updater here would swap the running app for a download nothing
/// vouched for. This reports what exists and hands the operator the release page.
///
/// It is also the only outbound network request the app makes, which is why it is opt-in rather
/// than on by default.
public struct UpdateCheck: Sendable {

    public struct Release: Sendable, Hashable {
        public let version: String
        public let url: URL
        public let notes: String?
    }

    public enum Outcome: Sendable, Hashable {
        case upToDate
        case available(Release)
        /// No repository configured, or the check could not be made.
        case unavailable(String)
    }

    /// `owner/name`, read from the bundle so a fork points at its own releases.
    public let repository: String?
    public let currentVersion: String

    public init(repository: String?, currentVersion: String) {
        self.repository = repository
        self.currentVersion = currentVersion
    }

    public func run() async -> Outcome {
        guard let repository, !repository.isEmpty else {
            return .unavailable("No update repository is configured for this build.")
        }
        guard let url = URL(
            string: "https://api.github.com/repos/\(repository)/releases/latest")
        else {
            return .unavailable("The configured repository name is not usable.")
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unavailable("No response from GitHub.")
            }
            // A repository with no releases yet answers 404, which is an answer rather than a fault.
            guard http.statusCode != 404 else { return .upToDate }
            guard http.statusCode == 200 else {
                return .unavailable("GitHub answered \(http.statusCode).")
            }

            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = object["tag_name"] as? String,
                  let page = (object["html_url"] as? String).flatMap(URL.init(string:))
            else {
                return .unavailable("Could not read the release from GitHub.")
            }

            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard Self.isNewer(latest, than: currentVersion) else { return .upToDate }
            return .available(Release(
                version: latest, url: page, notes: object["body"] as? String))
        } catch {
            return .unavailable("Could not reach GitHub.")
        }
    }

    /// Numeric comparison, component by component.
    ///
    /// String comparison is wrong in the case that matters: `"0.10.0" < "0.9.0"` lexically, which
    /// would hide exactly the update an operator on 0.9 needs. A non-numeric suffix — `1.0.0-beta`
    /// — orders below the same version without one.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = components(of: candidate)
        let right = components(of: current)

        for index in 0..<max(left.numbers.count, right.numbers.count) {
            let a = index < left.numbers.count ? left.numbers[index] : 0
            let b = index < right.numbers.count ? right.numbers[index] : 0
            if a != b { return a > b }
        }
        // Equal numbers: a release is newer than the pre-release of the same version.
        return left.suffix.isEmpty && !right.suffix.isEmpty
    }

    private static func components(of version: String) -> (numbers: [Int], suffix: String) {
        let core = version.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = core[0].split(separator: ".").map { Int($0) ?? 0 }
        return (numbers, core.count > 1 ? String(core[1]) : "")
    }
}
