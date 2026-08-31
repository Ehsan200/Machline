import Foundation

/// Replaces the running application bundle with a downloaded build, then relaunches it.
///
/// A running process cannot overwrite its own bundle and survive it, so the swap is done by a small
/// shell script that is started detached, waits for this process to exit, and only then moves the
/// new bundle into place. That is the same shape em-wall uses, and the reason for every step in it:
/// the old bundle is moved aside rather than deleted, the copy has to succeed before the old one
/// goes, and a failed copy puts the previous bundle back and reopens it.
///
/// What makes this safe to do at all is `ReleaseDownload`: the file handed here has already been
/// checked against the digest GitHub published, over TLS, before it reached disk. Without that
/// check this would be a self-inflicted supply chain — with it, the bytes are the ones the release
/// workflow produced.
public struct UpdateInstaller: Sendable {

    public enum Failure: Error, Sendable, Equatable {
        /// Running from `swift run` or a bare binary — there is no bundle to replace.
        case notBundled(String)
        case unpack(String)
        /// The disk image or archive held no application.
        case noApplication(String)
        case launch(String)
    }

    /// The bundle to be replaced — the one this process is running from.
    public let bundle: URL

    /// - Parameter bundle: overridable for tests; the running bundle otherwise.
    public init(bundle: URL? = nil) throws {
        if let bundle {
            self.bundle = bundle
        } else {
            self.bundle = try Self.runningBundle()
        }
    }

    /// Whether this build can replace itself at all, so the interface can offer installing rather
    /// than only revealing the download.
    public static var isInstallable: Bool { (try? runningBundle()) != nil }

    /// The bundle this process *is*, which is a stricter question than the nearest `.app` above the
    /// executable.
    ///
    /// Walking up for an `.app` suffix answers with somebody else's bundle whenever this code is
    /// hosted by another app — under `xctest` it reports `/Applications/Xcode.app`, and an updater
    /// that believed it would have replaced Xcode with Machline. So the bundle has to be the main
    /// bundle itself, with the running executable inside it; anything else is not a bundle this
    /// process may replace.
    public static func runningBundle() throws -> URL {
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard bundle.pathExtension == "app" else { throw Failure.notBundled(bundle.path) }

        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath(),
              executable.path.hasPrefix(bundle.path + "/")
        else {
            throw Failure.notBundled(bundle.path)
        }
        return bundle
    }

    /// Stages the downloaded build and hands the swap to a detached script.
    ///
    /// Returns as soon as the script is running. **The caller must quit immediately afterwards**:
    /// the script is already waiting on this process id and will wait about thirty seconds before
    /// giving up on it.
    public func install(from file: URL) throws {
        let staged = try stage(file)
        let scratch = try scratchDirectory()
        let script = scratch.appendingPathComponent("swap.sh")

        do {
            try Self.swapScript(
                pid: ProcessInfo.processInfo.processIdentifier,
                source: staged.application,
                destination: bundle,
                device: staged.device,
                scratch: scratch)
                .write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            staged.discard()
            throw Failure.unpack(String(describing: error))
        }

        do {
            try Self.launchDetached(script)
        } catch {
            staged.discard()
            throw Failure.launch(String(describing: error))
        }
    }

    // MARK: Staging

    /// Where the new application is readable from, and how to undo that if the swap never starts.
    struct Staged {
        let application: URL
        /// The mounted image's `/dev/diskN`, empty for an archive.
        let device: String
        let discard: () -> Void
    }

    func stage(_ file: URL) throws -> Staged {
        switch file.pathExtension.lowercased() {
        case "dmg": return try mount(file)
        case "zip": return try unzip(file)
        default: throw Failure.unpack("\(file.lastPathComponent) is not a disk image or archive.")
        }
    }

    /// Mounts the image without showing it in Finder or opening anything from it.
    private func mount(_ image: URL) throws -> Staged {
        let output = try Self.run(
            "/usr/bin/hdiutil",
            ["attach", "-nobrowse", "-noverify", "-noautoopen", image.path])

        // `hdiutil` prints tab-separated columns, but a volume name may contain spaces, so the
        // mount point is everything from the `/Volumes/` marker rather than the last field.
        var device = ""
        var mountPoint: String?
        for line in output.split(separator: "\n") where line.hasPrefix("/dev/") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: true)
            if device.isEmpty, let first = fields.first {
                device = first.trimmingCharacters(in: .whitespaces)
            }
            if let marker = line.range(of: "/Volumes/") {
                mountPoint = String(line[marker.lowerBound...])
                    .trimmingCharacters(in: .whitespaces)
                break
            }
        }

        func detach() {
            guard !device.isEmpty else { return }
            _ = try? Self.run("/usr/bin/hdiutil", ["detach", device, "-force"])
        }

        guard let mountPoint else {
            detach()
            throw Failure.unpack("The disk image mounted no volume.")
        }
        guard let application = Self.application(in: URL(fileURLWithPath: mountPoint)) else {
            detach()
            throw Failure.noApplication("No application inside \(image.lastPathComponent).")
        }
        return Staged(application: application, device: device, discard: detach)
    }

    /// Expands the archive with `ditto`, which keeps the bundle's symlinks and extended attributes.
    ///
    /// `unzip` flattens those, and a bundle whose framework symlinks became copies is a bundle that
    /// no longer launches.
    private func unzip(_ archive: URL) throws -> Staged {
        let directory = try scratchDirectory()
        func remove() { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
        } catch {
            remove()
            throw Failure.unpack(String(describing: error))
        }
        guard let application = Self.application(in: directory) else {
            remove()
            throw Failure.noApplication("No application inside \(archive.lastPathComponent).")
        }
        return Staged(application: application, device: "", discard: remove)
    }

    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("machline-install-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            throw Failure.unpack(String(describing: error))
        }
        return directory
    }

    /// The first `.app` at the top level of a mounted image or an expanded archive.
    static func application(in directory: URL) -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return entries.first { $0.pathExtension == "app" }
    }

    // MARK: The swap

    /// Starts the script in a session of its own.
    ///
    /// `nohup … &` inside a shell that exits immediately leaves the script parented to `launchd`
    /// rather than to this app, so quitting — the very next thing that happens — does not take the
    /// script with it.
    private static func launchDetached(_ script: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "nohup /bin/bash \(script.path.shellQuoted) >/dev/null 2>&1 &",
        ]
        try process.run()
        process.waitUntilExit()
    }

    /// Waits for this process to go, swaps the bundles, and reopens the app.
    ///
    /// Every path ends with the app open again: an operator who asked for an update and got a
    /// closed app with no explanation has lost their session for nothing.
    static func swapScript(
        pid: Int32, source: URL, destination: URL, device: String, scratch: URL
    ) -> String {
        """
        #!/usr/bin/env bash
        set -uo pipefail

        PID=\(pid)
        SRC=\(source.path.shellQuoted)
        DST=\(destination.path.shellQuoted)
        DEVICE=\(device.shellQuoted)
        SCRATCH=\(scratch.path.shellQuoted)

        # Wait up to ~30s for the app to quit. Replacing a bundle out from under a running process
        # is what leaves it half-updated, so this gives up rather than forcing it.
        for _ in $(seq 1 100); do
            kill -0 "$PID" 2>/dev/null || break
            sleep 0.3
        done
        if kill -0 "$PID" 2>/dev/null; then
            [ -n "$DEVICE" ] && /usr/bin/hdiutil detach "$DEVICE" -force >/dev/null 2>&1
            rm -rf "$SCRATCH"
            exit 1
        fi

        cleanup() {
            [ -n "$DEVICE" ] && /usr/bin/hdiutil detach "$DEVICE" -force >/dev/null 2>&1
            rm -rf "$SCRATCH"
        }

        rm -rf "$DST.old"
        if [ -d "$DST" ]; then
            mv "$DST" "$DST.old" || { cleanup; /usr/bin/open "$DST" >/dev/null 2>&1; exit 1; }
        fi

        # ditto rather than cp -R: a bundle's symlinks and extended attributes have to survive.
        if ! /usr/bin/ditto "$SRC" "$DST"; then
            rm -rf "$DST"
            [ -d "$DST.old" ] && mv "$DST.old" "$DST"
            cleanup
            /usr/bin/open "$DST" >/dev/null 2>&1
            exit 1
        fi

        # The build is ad-hoc signed, so a quarantine flag carried in from the download would put
        # Gatekeeper in front of a bundle the operator already has running.
        xattr -dr com.apple.quarantine "$DST" >/dev/null 2>&1
        rm -rf "$DST.old"
        cleanup
        /usr/bin/open "$DST" >/dev/null 2>&1
        """
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw Failure.unpack(String(describing: error))
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.unpack("\(tool) exited \(process.terminationStatus).")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
