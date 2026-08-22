import Foundation

/// A single path's status, from `git status --porcelain=v2 -z`.
public struct GitFileStatus: Sendable, Hashable, Identifiable {
    public enum Change: String, Sendable, Hashable {
        case unmodified = "."
        case modified = "M"
        case added = "A"
        case deleted = "D"
        case renamed = "R"
        case copied = "C"
        case typeChanged = "T"
        case updatedButUnmerged = "U"
        case untracked = "?"
        case ignored = "!"
    }

    public var id: String { path }
    public let path: String
    /// Change between HEAD and the index — what a commit would record.
    public let indexChange: Change
    /// Change between the index and the working tree — what is not yet staged.
    public let worktreeChange: Change
    /// Source path for a rename or copy.
    public let originalPath: String?
    public let isUnmerged: Bool

    public var isStaged: Bool { indexChange != .unmodified && indexChange != .untracked }
    public var hasUnstagedChanges: Bool {
        worktreeChange != .unmodified || indexChange == .untracked
    }
    public var isUntracked: Bool { indexChange == .untracked }

    /// Untracked files have no diff against the index, so they are staged wholesale rather than by
    /// hunk.
    public var supportsHunkStaging: Bool { !isUntracked && !isUnmerged }
}

/// Branch and upstream state, from the `# branch.*` headers.
public struct GitBranchStatus: Sendable, Hashable {
    public let head: String?
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let commitOID: String?

    public var isDetached: Bool { head == "(detached)" }
    public var hasUpstream: Bool { upstream != nil }
    /// True before the first commit, where `HEAD` resolves to nothing.
    public var isUnborn: Bool { commitOID == "(initial)" }
}

public struct GitStatus: Sendable, Hashable {
    public let branch: GitBranchStatus
    public let files: [GitFileStatus]

    public var staged: [GitFileStatus] { files.filter(\.isStaged) }
    public var unstaged: [GitFileStatus] { files.filter(\.hasUnstagedChanges) }
    public var unmerged: [GitFileStatus] { files.filter(\.isUnmerged) }
    public var isClean: Bool { files.isEmpty }
}

extension GitStatus {
    /// Parses `git status --porcelain=v2 -z --untracked-files=all --branch`.
    ///
    /// Records are NUL-separated, and rename/copy entries spend an **extra** record on their source
    /// path — so the parser consumes records by index rather than iterating them uniformly.
    /// Splitting naively on NUL and treating every field as one entry silently mis-assigns every
    /// path after the first rename.
    public static func parse(porcelainV2 data: Data) -> GitStatus {
        let records = data
            .split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }

        var head: String?
        var upstream: String?
        var ahead = 0, behind = 0
        var commitOID: String?
        var files: [GitFileStatus] = []

        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard !record.isEmpty else { continue }

            switch record.first {
            case "#":
                // Records look like `# branch.oid (initial)`, so the marker, the key, and the
                // value are three separate space-delimited fields.
                let parts = record.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count >= 3 else { break }
                let value = parts[2]
                switch parts[1] {
                case "branch.oid": commitOID = value
                case "branch.head": head = value
                case "branch.upstream": upstream = value
                case "branch.ab":
                    // "+3 -1"
                    for count in value.split(separator: " ") {
                        let magnitude = Int(count.dropFirst()) ?? 0
                        if count.hasPrefix("+") { ahead = magnitude }
                        if count.hasPrefix("-") { behind = magnitude }
                    }
                default: break
                }

            case "1":
                // 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
                let fields = record.split(separator: " ", maxSplits: 8).map(String.init)
                guard fields.count == 9 else { break }
                files.append(makeStatus(xy: fields[1], path: fields[8], originalPath: nil))

            case "2":
                // 2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>  then <origPath>
                let fields = record.split(separator: " ", maxSplits: 9).map(String.init)
                guard fields.count == 10 else { break }
                let originalPath = index < records.count ? records[index] : nil
                index += 1  // consume the source-path record
                files.append(makeStatus(xy: fields[1], path: fields[9], originalPath: originalPath))

            case "u":
                // u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
                let fields = record.split(separator: " ", maxSplits: 10).map(String.init)
                guard fields.count == 11 else { break }
                files.append(GitFileStatus(
                    path: fields[10],
                    indexChange: .updatedButUnmerged,
                    worktreeChange: .updatedButUnmerged,
                    originalPath: nil,
                    isUnmerged: true))

            case "?":
                let path = String(record.dropFirst(2))
                files.append(GitFileStatus(
                    path: path, indexChange: .untracked, worktreeChange: .untracked,
                    originalPath: nil, isUnmerged: false))

            case "!":
                let path = String(record.dropFirst(2))
                files.append(GitFileStatus(
                    path: path, indexChange: .ignored, worktreeChange: .ignored,
                    originalPath: nil, isUnmerged: false))

            default:
                break
            }
        }

        return GitStatus(
            branch: GitBranchStatus(
                head: head, upstream: upstream, ahead: ahead, behind: behind, commitOID: commitOID),
            files: files.sorted { $0.path < $1.path })
    }

    private static func makeStatus(xy: String, path: String, originalPath: String?) -> GitFileStatus {
        let characters = Array(xy)
        let index = characters.count > 0
            ? GitFileStatus.Change(rawValue: String(characters[0])) ?? .unmodified : .unmodified
        let worktree = characters.count > 1
            ? GitFileStatus.Change(rawValue: String(characters[1])) ?? .unmodified : .unmodified
        return GitFileStatus(
            path: path, indexChange: index, worktreeChange: worktree,
            originalPath: originalPath, isUnmerged: false)
    }
}
