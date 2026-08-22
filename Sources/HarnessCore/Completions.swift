import Foundation

/// One suggestion in the composer's autocomplete.
public struct Completion: Identifiable, Hashable {
    public enum Kind: Sendable { case slashCommand, file, directory }

    public let kind: Kind
    /// The text that replaces the token being typed.
    public let insert: String
    public let label: String
    public var detail: String?

    public var id: String { "\(kind)-\(insert)" }

    public init(kind: Kind, insert: String, label: String, detail: String? = nil) {
        self.kind = kind
        self.insert = insert
        self.label = label
        self.detail = detail
    }
}

/// The token the caret is sitting in, if it can trigger a completion.
///
/// The trigger is read from the end of the draft rather than from a caret offset: SwiftUI's
/// `TextEditor` does not publish its selection, and typing happens at the end in practice. A token
/// is only a trigger while it is the last thing in the draft, which also means the popover closes
/// as soon as the operator moves on.
public struct CompletionTrigger: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case slashCommand, file }

    public let kind: Kind
    /// What follows the `/` or `@`.
    public let query: String
    /// Where the trigger character sits, so accepting can replace from there.
    public let start: String.Index

    public static func detect(in draft: String) -> CompletionTrigger? {
        guard !draft.isEmpty, let last = draft.last, !last.isWhitespace else { return nil }

        // The token under the caret: everything back to the last whitespace.
        let tokenStart = draft.lastIndex(where: \.isWhitespace)
            .map { draft.index(after: $0) } ?? draft.startIndex
        let token = draft[tokenStart...]
        guard let marker = token.first else { return nil }

        switch marker {
        case "/":
            // A slash command is only a command at the very start of the message; anywhere else
            // it is a path, a date, or a regex.
            guard tokenStart == draft.startIndex else { return nil }
            return CompletionTrigger(
                kind: .slashCommand, query: String(token.dropFirst()), start: tokenStart)
        case "@":
            return CompletionTrigger(
                kind: .file, query: String(token.dropFirst()), start: tokenStart)
        default:
            return nil
        }
    }
}

/// Ranks candidates against what has been typed.
public enum CompletionMatcher {
    public static let limit = 12

    /// Subsequence matching, the shape operators expect from a fuzzy finder: `csv` finds
    /// `Components/SessionView.swift`.
    ///
    /// Ranking favours a prefix match, then an early first hit, then a short candidate — so the
    /// exact thing being typed does not sit below a longer path that happens to contain it.
    public static func rank(_ candidates: [String], query: String) -> [String] {
        rank(candidates, query: query, key: { $0 })
    }

    /// Ranks any candidate by a string drawn from it.
    public static func rank<T>(
        _ candidates: [T], query: String, key: (T) -> String
    ) -> [T] {
        guard !query.isEmpty else { return Array(candidates.prefix(limit)) }
        let needle = Array(query.lowercased())

        var scored: [(candidate: T, text: String, score: Int)] = []
        for candidate in candidates {
            let text = key(candidate)
            let haystack = Array(text.lowercased())
            var index = 0
            var firstHit: Int?
            for (position, character) in haystack.enumerated() where index < needle.count {
                if character == needle[index] {
                    if firstHit == nil { firstHit = position }
                    index += 1
                }
            }
            guard index == needle.count, let firstHit else { continue }

            var score = firstHit * 4 + text.count
            if text.lowercased().hasPrefix(query.lowercased()) { score -= 1000 }
            // The filename matters more than the directories above it.
            if let name = text.split(separator: "/").last,
               name.lowercased().hasPrefix(query.lowercased()) {
                score -= 500
            }
            scored.append((candidate, text, score))
        }

        return scored
            .sorted { $0.score == $1.score ? $0.text < $1.text : $0.score < $1.score }
            .prefix(limit)
            .map(\.candidate)
    }
}

/// The files and folders a project offers to `@` mentions.
///
/// Built once when a project opens and held in memory: the alternative is walking the tree on every
/// keystroke. Heavy directories are skipped outright rather than walked and filtered, because on a
/// real project `node_modules` alone is most of the tree.
public struct FileIndex: Sendable {
    /// Enough to cover a large project without letting a pathological tree stall the walk.
    public static let limit = 20_000

    public static let skippedDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", "node_modules", "DerivedData", ".next", "dist", "build",
        "target", "vendor", "Pods", "__pycache__", ".venv", "venv", ".gradle", ".idea", ".cache"
    ]

    /// One entry. Directories carry a trailing slash, which is both how they are told apart and
    /// what the agent needs in the mention to read a whole folder.
    public struct Entry: Sendable, Hashable {
        public let path: String
        public let isDirectory: Bool

        public init(path: String, isDirectory: Bool) {
            self.path = path
            self.isDirectory = isDirectory
        }

        /// What goes into the message after the `@`.
        public var mention: String { isDirectory ? path + "/" : path }
        public var name: String {
            path.split(separator: "/").last.map(String.init) ?? path
        }
    }

    public static func build(for workspace: URL) -> [Entry] {
        let root = workspace.standardizedFileURL
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var entries: [Entry] = []
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"

        for case let url as URL in walker {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory)
                ?? false
            if isDirectory, skippedDirectories.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }

            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            entries.append(Entry(path: String(path.dropFirst(prefix.count)), isDirectory: isDirectory))
            if entries.count >= limit { break }
        }
        return entries
    }
}
