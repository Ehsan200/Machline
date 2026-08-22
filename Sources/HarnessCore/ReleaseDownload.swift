import CryptoKit
import Foundation

/// Fetches a release's build without sending the operator to a browser.
///
/// Still not an updater, and for the same reason `UpdateCheck` is not one: this app is ad-hoc
/// signed, so nothing here may replace the running bundle with a download the system has not
/// vouched for. What it does is remove the errand — the disk image lands in Downloads, verified
/// against the digest GitHub published, and the operator installs it themselves.
public struct ReleaseDownload: Sendable {

    public enum Failure: Error, Sendable, Equatable {
        case http(Int)
        case unreachable(String)
        /// The bytes that arrived are not the bytes GitHub published.
        case digestMismatch(expected: String, actual: String)
        case write(String)
    }

    public let asset: UpdateCheck.Asset
    /// Where the finished file is put. Downloads, because that is where a downloaded thing goes
    /// and where the operator will look for it afterwards.
    public let directory: URL

    public init(asset: UpdateCheck.Asset, directory: URL? = nil) {
        self.asset = asset
        self.directory = directory ?? FileManager.default.urls(
            for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// Downloads to a temporary file, verifies it, then moves it into place.
    ///
    /// A `URLSessionDownloadTask` rather than a byte stream: the payload is tens of megabytes, and
    /// iterating it a byte at a time in Swift costs more than the transfer does. The task also
    /// publishes its own `Progress`, which is what the bar is bound to, and cancels cleanly.
    ///
    /// - Parameter progress: fraction complete, `0...1`. Called from a background thread, often.
    /// - Returns: where the file was written.
    public func run(progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        var request = URLRequest(url: asset.url)
        request.timeoutInterval = 30
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let downloaded = try await withTaskCancellationHandler {
            try await transfer(request, progress: progress)
        } onCancel: {
            // The task is cancelled by the handler installed inside `transfer`.
        }

        defer { try? FileManager.default.removeItem(at: downloaded) }
        try verifyDigest(of: downloaded)
        return try place(downloaded, as: asset.name)
    }

    /// The transfer itself, bridged to `async` and reporting progress as it goes.
    ///
    /// The delivered file is moved out of the session's temporary location immediately: URLSession
    /// deletes it as soon as the completion handler returns.
    private func transfer(
        _ request: URLRequest, progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        final class Box: @unchecked Sendable {
            var task: URLSessionDownloadTask?
            var observation: NSKeyValueObservation?
        }
        let box = Box()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let task = URLSession.shared.downloadTask(with: request) { file, response, error in
                    box.observation?.invalidate()

                    if let error {
                        let failure = (error as NSError).code == NSURLErrorCancelled
                            ? CancellationError() as Error
                            : Failure.unreachable(String(describing: error))
                        continuation.resume(throwing: failure)
                        return
                    }
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        continuation.resume(throwing: Failure.http(http.statusCode))
                        return
                    }
                    guard let file else {
                        continuation.resume(throwing: Failure.unreachable("No file was delivered."))
                        return
                    }

                    // Moved now: this file is deleted the moment this handler returns.
                    let scratch = FileManager.default.temporaryDirectory
                        .appendingPathComponent("machline-update-\(UUID().uuidString)")
                    do {
                        try FileManager.default.moveItem(at: file, to: scratch)
                        continuation.resume(returning: scratch)
                    } catch {
                        continuation.resume(throwing: Failure.write(String(describing: error)))
                    }
                }

                box.task = task
                box.observation = task.progress.observe(\.fractionCompleted) { value, _ in
                    progress(min(1, max(0, value.fractionCompleted)))
                }
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    /// Refuses a file that is not what GitHub published.
    ///
    /// Read in chunks rather than loaded whole: verifying a download must not need as much memory
    /// as the download itself. A release with no digest — an older one, or a host that does not
    /// report one — is left unverified rather than wrongly rejected.
    private func verifyDigest(of file: URL) throws {
        guard let expected = Self.normalised(digest: asset.digest) else { return }

        guard let handle = try? FileHandle(forReadingFrom: file) else {
            throw Failure.write("Could not read the downloaded file.")
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw Failure.digestMismatch(expected: expected, actual: actual)
        }
    }

    /// Moves the finished file in beside whatever is already there, rather than over it.
    func place(_ file: URL, as name: String) throws -> URL {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)

        var destination = directory.appendingPathComponent(name)
        if manager.fileExists(atPath: destination.path) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            var index = 2
            repeat {
                let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
                destination = directory.appendingPathComponent(candidate)
                index += 1
            } while manager.fileExists(atPath: destination.path) && index < 1000
        }

        do {
            try manager.copyItem(at: file, to: destination)
        } catch {
            throw Failure.write(String(describing: error))
        }
        return destination
    }

    /// `sha256:abc…` and a bare hex digest both reduce to the same lowercase hex.
    static func normalised(digest: String?) -> String? {
        guard let digest, !digest.isEmpty else { return nil }
        let value = digest.contains(":")
            ? String(digest.split(separator: ":", maxSplits: 1)[1])
            : digest
        let hex = value.lowercased()
        // Only SHA-256 is understood; anything else is left unverified rather than wrongly failed.
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }

    private static let chunkSize = 1024 * 1024
}
