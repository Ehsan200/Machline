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

    // MARK: Downloadable asset

    private func assets(_ json: String) throws -> [[String: Any]] {
        try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] ?? []
    }

    /// This project publishes a disk image, so that is what the button must offer — not the first
    /// file that happens to be attached.
    @Test("The disk image is preferred over anything else attached")
    func picksDiskImage() throws {
        let raw = try assets(#"""
        [{"name":"checksums.txt","browser_download_url":"https://e/c.txt","size":10},
         {"name":"Machline-1.2.0.dmg","browser_download_url":"https://e/m.dmg","size":41000000,
          "digest":"sha256:aaaa"},
         {"name":"Machline.zip","browser_download_url":"https://e/m.zip","size":40000000}]
        """#)

        let asset = UpdateCheck.installer(in: raw)
        #expect(asset?.name == "Machline-1.2.0.dmg")
        #expect(asset?.byteCount == 41_000_000)
        #expect(asset?.digest == "sha256:aaaa")
    }

    @Test("An archive is the fallback when no disk image is attached")
    func fallsBackToArchive() throws {
        let raw = try assets(#"""
        [{"name":"notes.txt","browser_download_url":"https://e/n.txt","size":1},
         {"name":"Machline.zip","browser_download_url":"https://e/m.zip","size":40}]
        """#)
        #expect(UpdateCheck.installer(in: raw)?.name == "Machline.zip")
    }

    /// A release cut without a build attached still has a page worth opening, so this is `nil`
    /// rather than an error — the banner falls back to the link.
    @Test("A release with nothing installable attached offers no download")
    func noInstallableAsset() throws {
        let raw = try assets(#"[{"name":"notes.txt","browser_download_url":"https://e/n.txt","size":1}]"#)
        #expect(UpdateCheck.installer(in: raw) == nil)
        #expect(UpdateCheck.installer(in: []) == nil)
    }

    @Test("An asset missing its download URL is skipped rather than half-built")
    func malformedAsset() throws {
        let raw = try assets(#"[{"name":"Machline.dmg","size":40}]"#)
        #expect(UpdateCheck.installer(in: raw) == nil)
    }

    // MARK: Digest handling

    @Test("Both digest spellings reduce to the same hex")
    func digestNormalisation() {
        let hex = String(repeating: "a", count: 64)
        #expect(ReleaseDownload.normalised(digest: "sha256:\(hex)") == hex)
        #expect(ReleaseDownload.normalised(digest: hex.uppercased()) == hex)
    }

    /// An unverifiable digest leaves the download unverified; it must not fail a good file. A
    /// wrong-length or non-hex value is exactly that case.
    @Test("An unusable digest is ignored rather than treated as a mismatch")
    func unusableDigest() {
        #expect(ReleaseDownload.normalised(digest: nil) == nil)
        #expect(ReleaseDownload.normalised(digest: "") == nil)
        #expect(ReleaseDownload.normalised(digest: "md5:abc") == nil)
        #expect(ReleaseDownload.normalised(digest: "sha256:not-hex") == nil)
    }

    /// A second download of the same release must not overwrite the first, which may be the one
    /// the operator is part-way through installing.
    @Test("A download never overwrites a file already sitting there")
    func placementIsNonDestructive() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("machline-place-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let asset = UpdateCheck.Asset(
            name: "Machline-1.2.0.dmg", url: URL(string: "https://e/m.dmg")!,
            byteCount: 4, digest: nil)
        let download = ReleaseDownload(asset: asset, directory: root)

        func source(_ contents: String) throws -> URL {
            let url = root.appendingPathComponent("src-\(UUID().uuidString)")
            try Data(contents.utf8).write(to: url)
            return url
        }

        let first = try download.place(try source("one"), as: asset.name)
        let second = try download.place(try source("two"), as: asset.name)

        #expect(first.lastPathComponent == "Machline-1.2.0.dmg")
        #expect(second.lastPathComponent == "Machline-1.2.0 2.dmg")
        #expect(try String(contentsOf: first, encoding: .utf8) == "one")
        #expect(try String(contentsOf: second, encoding: .utf8) == "two")
    }

    @Test("Downloads land in Downloads unless told otherwise")
    func destinationDefaults() {
        let asset = UpdateCheck.Asset(
            name: "Machline.dmg", url: URL(string: "https://e/m.dmg")!, byteCount: 1, digest: nil)
        let expected = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        #expect(ReleaseDownload(asset: asset).directory == expected)

        let custom = URL(fileURLWithPath: "/tmp/machline-test")
        #expect(ReleaseDownload(asset: asset, directory: custom).directory == custom)
    }
}
