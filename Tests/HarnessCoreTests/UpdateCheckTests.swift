import Foundation
import Testing
@testable import HarnessCore

/// Version comparison, which is the whole correctness surface of the update check.
struct UpdateCheckTests {

    /// The case that makes string comparison wrong: lexically `"0.10.0" < "0.9.0"`, which would
    /// hide exactly the update an operator on 0.9 needs.
    @Test("Components are compared numerically, not as text")
    func numericComparison() {
        #expect(UpdateCheck.isNewer("0.10.0", than: "0.9.0"))
        #expect(!UpdateCheck.isNewer("0.9.0", than: "0.10.0"))
        #expect(UpdateCheck.isNewer("1.0.0", than: "0.99.99"))
    }

    @Test("An identical version is not newer")
    func identicalIsNotNewer() {
        #expect(!UpdateCheck.isNewer("1.2.3", than: "1.2.3"))
    }

    @Test("Missing components count as zero")
    func missingComponents() {
        #expect(UpdateCheck.isNewer("1.1", than: "1.0.9"))
        #expect(!UpdateCheck.isNewer("1.0", than: "1.0.0"))
        #expect(UpdateCheck.isNewer("2", than: "1.9.9"))
    }

    /// A release supersedes the pre-release of the same version, and never the other way round.
    @Test("A release outranks a pre-release of the same version")
    func preReleaseOrdering() {
        #expect(UpdateCheck.isNewer("1.0.0", than: "1.0.0-beta"))
        #expect(!UpdateCheck.isNewer("1.0.0-beta", than: "1.0.0"))
        #expect(UpdateCheck.isNewer("1.0.1-beta", than: "1.0.0"))
    }

    /// A build with no repository configured must say so rather than fail silently or reach out.
    @Test("No configured repository reports unavailable without a request")
    func noRepositoryConfigured() async {
        let outcome = await UpdateCheck(repository: nil, currentVersion: "1.0.0").run()
        guard case .unavailable = outcome else {
            Issue.record("expected .unavailable, got \(outcome)")
            return
        }
    }

    @Test("An empty repository name is treated as unconfigured")
    func emptyRepository() async {
        let outcome = await UpdateCheck(repository: "", currentVersion: "1.0.0").run()
        guard case .unavailable = outcome else {
            Issue.record("expected .unavailable, got \(outcome)")
            return
        }
    }
}
