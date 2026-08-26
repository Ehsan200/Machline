import Foundation

/// A project-less place to work with the agent.
///
/// Every session needs a working directory — it is what the CLI files the transcript under and
/// what the agent's own commands run in. That makes "just ask it something" awkward: opening a real
/// project to ask an unrelated question puts the conversation in that project's history and points
/// a tool-using agent at code it has no business touching.
///
/// So there is one scratch directory, kept rather than discarded: its conversations accumulate in
/// the CLI's store like any project's, which is what makes yesterday's throwaway question findable
/// today. A session here has its ordinary tools; this directory is what they are pointed at.
public struct ScratchWorkspace: Sendable {

    public let url: URL

    public init(root: URL? = nil) {
        self.url = root ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".machline/scratch", isDirectory: true)
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Creates the directory if it is not there, and returns it.
    ///
    /// The note inside is for whoever finds this directory later and wonders what wrote it —
    /// including the agent, which may well `ls` its own working directory.
    @discardableResult
    public func prepare() throws -> URL {
        let manager = FileManager.default
        if !exists {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let note = url.appendingPathComponent("README.md")
        if !manager.fileExists(atPath: note.path) {
            try? """
                # Scratch

                Machline's scratch workspace: a working directory for sessions that do not belong
                to any project. Nothing here is precious — it exists so a question can be asked, or
                a throwaway script run, without opening a repository and without the answer landing
                in that repository's history.

                Files the agent writes here are safe to delete.
                """.write(to: note, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// Removes everything in the scratch directory, keeping the directory itself.
    ///
    /// Deliberately not "delete the folder": the transcripts live in the CLI's own store, not
    /// here, so this clears working files without touching the conversations.
    public func empty() throws {
        let manager = FileManager.default
        guard exists else { return }
        for entry in try manager.contentsOfDirectory(atPath: url.path) {
            try? manager.removeItem(at: url.appendingPathComponent(entry))
        }
        try prepare()
    }
}
