import Foundation

/// The CLI's own view of who is signed in.
///
/// `claude auth status` prints JSON and does not start a session, so this is a cheap read rather
/// than something to cache aggressively. Nothing here is inferred: every field is the CLI's.
public struct AccountStatus: Sendable, Codable, Hashable {
    public let loggedIn: Bool
    public let authMethod: String?
    public let apiProvider: String?
    public let email: String?
    public let orgName: String?
    public let subscriptionType: String?

    enum CodingKeys: String, CodingKey {
        case loggedIn, authMethod, apiProvider, email, orgName, subscriptionType
    }

    /// Runs `claude auth status`. Returns `nil` when the CLI cannot be found or does not answer.
    ///
    /// Blocking, and meant to be called off the main actor.
    public static func read(executable: String = "claude") -> AccountStatus? {
        guard let url = try? SessionSupervisor.resolve(executable: executable) else { return nil }

        let process = Process()
        process.executableURL = url
        process.arguments = ["auth", "status"]
        process.environment = SessionSupervisor.inheritedEnvironment()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        return try? JSONDecoder().decode(AccountStatus.self, from: data)
    }
}
