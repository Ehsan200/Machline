import Foundation
import Testing

@testable import HarnessCore

@Suite("Installing a downloaded release")
struct UpdateInstallerTests {

    // MARK: Finding what to replace

    /// The test runner is not a `.app`, which is the same shape as `swift run` — and under
    /// `xctest` it is hosted by one, `/Applications/Xcode.app`. Both must refuse: the installer
    /// replaces the bundle this process is, never the nearest `.app` above its executable.
    @Test("A non-bundled process has nothing to replace")
    func nonBundledProcess() {
        #expect(throws: (any Error).self) { try UpdateInstaller.runningBundle() }
        #expect(!UpdateInstaller.isInstallable)
    }

    // MARK: Staging

    @Test("The application inside an expanded archive is found")
    func applicationInDirectory() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Machline.app"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("README.txt"))

        #expect(UpdateInstaller.application(in: root)?.lastPathComponent == "Machline.app")
    }

    @Test("A payload with no application in it is not staged")
    func noApplicationInDirectory() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("Machline.dmg"))

        #expect(UpdateInstaller.application(in: root) == nil)
    }

    /// `ditto` rather than `unzip`, so a bundle's symlinks survive the round trip — a framework
    /// symlink that came back as a copy is a bundle that no longer launches.
    @Test("A zipped bundle is expanded with its symlinks intact")
    func stagingAnArchive() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let bundle = root.appendingPathComponent("Machline.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: bundle.appendingPathComponent("Machline"))
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("Machline.app/Contents/Current").path,
            withDestinationPath: "MacOS")

        let archive = root.appendingPathComponent("Machline.zip")
        try ditto(["-c", "-k", "--keepParent",
                   root.appendingPathComponent("Machline.app").path, archive.path])

        let installer = try UpdateInstaller(bundle: root.appendingPathComponent("Installed.app"))
        let staged = try installer.stage(archive)
        defer { staged.discard() }

        #expect(staged.device.isEmpty)
        #expect(staged.application.lastPathComponent == "Machline.app")
        let link = staged.application.appendingPathComponent("Contents/Current")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "MacOS")

        staged.discard()
        #expect(!FileManager.default.fileExists(atPath: staged.application.path))
    }

    @Test("Anything that is not a disk image or archive is refused")
    func unknownPayload() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Machline.pkg")
        try Data().write(to: file)

        let installer = try UpdateInstaller(bundle: root.appendingPathComponent("Installed.app"))
        #expect(throws: (any Error).self) { try installer.stage(file) }
    }

    // MARK: The swap script

    /// A volume name is chosen by whoever built the image, and a bundle path by whoever installed
    /// the app. Neither is trusted to be free of quotes or spaces.
    @Test("Paths reach the script quoted")
    func quoting() {
        #expect("/Volumes/Machline 1.2".shellQuoted == "'/Volumes/Machline 1.2'")
        #expect("it's".shellQuoted == "'it'\\''s'")
    }

    @Test("The script waits, swaps non-destructively, and reopens the app")
    func scriptShape() {
        let script = UpdateInstaller.swapScript(
            pid: 4242,
            source: URL(fileURLWithPath: "/Volumes/Machline 1.2/Machline.app"),
            destination: URL(fileURLWithPath: "/Applications/Machline.app"),
            device: "/dev/disk9",
            scratch: URL(fileURLWithPath: "/tmp/machline-install-x"))

        #expect(script.contains("PID=4242"))
        #expect(script.contains("'/Volumes/Machline 1.2/Machline.app'"))
        // The old bundle is moved aside, not deleted, and only removed after the copy succeeds.
        #expect(script.contains(#"mv "$DST" "$DST.old""#))
        #expect(script.contains(#"/usr/bin/ditto "$SRC" "$DST""#))
        #expect(script.contains(#"[ -d "$DST.old" ] && mv "$DST.old" "$DST""#))
        // Every exit path leaves the app open again, and the mount detached.
        #expect(script.contains(#"/usr/bin/open "$DST""#))
        #expect(script.contains("hdiutil detach"))
        #expect(script.contains("com.apple.quarantine"))
    }

    /// The script must give up rather than replace a bundle whose process is still running.
    @Test("A process that never quits stops the swap")
    func refusesToSwapUnderARunningApp() {
        let script = UpdateInstaller.swapScript(
            pid: 1, source: URL(fileURLWithPath: "/tmp/a.app"),
            destination: URL(fileURLWithPath: "/tmp/b.app"), device: "",
            scratch: URL(fileURLWithPath: "/tmp/s"))
        let guardIndex = script.range(of: #"if kill -0 "$PID" 2>/dev/null; then"#)
        let swapIndex = script.range(of: #"mv "$DST" "$DST.old""#)
        #expect(guardIndex != nil)
        #expect(swapIndex != nil)
        if let guardIndex, let swapIndex { #expect(guardIndex.upperBound < swapIndex.lowerBound) }
    }

    // MARK: Helpers

    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("machline-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func ditto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
