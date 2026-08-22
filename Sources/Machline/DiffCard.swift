import HarnessCore
import SwiftUI

/// A file edit lifted out of a tool call so it can be rendered as a diff rather than as JSON.
///
/// `Edit` carries a before/after pair, `Write` carries only an after, and `MultiEdit` carries a
/// list of pairs. Anything else is not an edit and falls back to the ordinary tool row.
struct EditPreview {
    let path: String
    let hunks: [[DiffLine]]
    /// A `Write` to a path that did not exist has no before-image to diff against.
    let isWholeFile: Bool

    init?(use: ToolUse) {
        guard let path = use.input["file_path"]?.stringValue else { return nil }
        self.path = path

        switch use.name {
        case "Edit":
            guard let before = use.input["old_string"]?.stringValue,
                  let after = use.input["new_string"]?.stringValue
            else { return nil }
            hunks = [LineDiff.compute(before: before, after: after)]
            isWholeFile = false

        case "Write":
            guard let content = use.input["content"]?.stringValue else { return nil }
            hunks = [content.diffLines.map { DiffLine(kind: .addition, text: $0) }]
            isWholeFile = true

        case "MultiEdit":
            guard let edits = use.input["edits"]?.arrayValue, !edits.isEmpty else { return nil }
            hunks = edits.compactMap { edit in
                guard let before = edit["old_string"]?.stringValue,
                      let after = edit["new_string"]?.stringValue
                else { return nil }
                return LineDiff.compute(before: before, after: after)
            }
            isWholeFile = false

        default:
            return nil
        }

        guard !hunks.isEmpty, hunks.contains(where: { !$0.isEmpty }) else { return nil }
    }

    var additions: Int { hunks.flatMap { $0 }.count { $0.kind == .addition } }
    var deletions: Int { hunks.flatMap { $0 }.count { $0.kind == .deletion } }
}

struct DiffLine: Identifiable, Hashable {
    enum Kind { case context, addition, deletion }

    let id = UUID()
    let kind: Kind
    let text: String
}

/// A line-level diff over the small before/after strings an `Edit` carries.
///
/// This is a longest-common-subsequence diff, not Myers: edit payloads are a handful of lines, so
/// the quadratic table is cheaper than the machinery to avoid it. Git diffs elsewhere in the app
/// come from `git` itself and do not go through here.
enum LineDiff {
    /// Above this many lines on either side the table stops being free, so the two sides are shown
    /// whole instead of aligned.
    private static let alignmentLimit = 400

    static func compute(before: String, after: String) -> [DiffLine] {
        let old = before.diffLines
        let new = after.diffLines

        guard old.count <= alignmentLimit, new.count <= alignmentLimit else {
            return old.map { DiffLine(kind: .deletion, text: $0) }
                + new.map { DiffLine(kind: .addition, text: $0) }
        }

        var table = [[Int]](
            repeating: [Int](repeating: 0, count: new.count + 1),
            count: old.count + 1)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var lines: [DiffLine] = []
        var i = 0, j = 0
        while i < old.count, j < new.count {
            if old[i] == new[j] {
                lines.append(DiffLine(kind: .context, text: old[i]))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                lines.append(DiffLine(kind: .deletion, text: old[i]))
                i += 1
            } else {
                lines.append(DiffLine(kind: .addition, text: new[j]))
                j += 1
            }
        }
        while i < old.count {
            lines.append(DiffLine(kind: .deletion, text: old[i]))
            i += 1
        }
        while j < new.count {
            lines.append(DiffLine(kind: .addition, text: new[j]))
            j += 1
        }
        return lines
    }
}

extension String {
    /// Splits on newlines while keeping blank lines, which are meaningful in a diff.
    var diffLines: [String] {
        split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}

// MARK: - View

/// An inline diff: sticky file header with path and counts, then the aligned lines. Code is never
/// wrapped — alignment is the point — so wide content scrolls horizontally inside the card.
struct DiffCard: View {
    let preview: EditPreview
    let onExpand: () -> Void

    @State private var isCollapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !isCollapsed {
                Hairline(color: Theme.Colors.border)
                body_
            }
        }
        .background(Theme.Colors.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Layout.radius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Layout.radius)
                .strokeBorder(Theme.Colors.border, lineWidth: Theme.Layout.hairline))
        .padding(.bottom, Theme.Space.sm)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.sm) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { isCollapsed.toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.Colors.subtle)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(preview.isWholeFile ? "NEW FILE" : "DIFF")
                .font(Theme.Typography.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(Theme.Colors.muted)

            Text(preview.path)
                .font(Theme.Typography.monoStrong)
                .foregroundStyle(Theme.Colors.text)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: Theme.Space.sm)

            DiffCounts(additions: preview.additions, deletions: preview.deletions)

            Button("Expand", action: onExpand)
                .buttonStyle(.plain)
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.Colors.link)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
    }

    private var body_: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(preview.hunks.enumerated()), id: \.offset) { index, hunk in
                    if index > 0 {
                        Hairline(color: Theme.Colors.border)
                    }
                    ForEach(hunk) { line in
                        DiffLineRow(line: line)
                    }
                }
            }
            .padding(.vertical, Theme.Space.xs)
        }
        .frame(maxHeight: Theme.Layout.embeddedDiffMaxHeight)
    }
}

struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Text(marker)
                .font(Theme.Typography.monoSmall)
                .foregroundStyle(markerColor)
                .frame(width: 10, alignment: .center)

            Text(line.text.isEmpty ? " " : line.text)
                .font(Theme.Typography.monoSmall)
                .foregroundStyle(textColor)
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, 1)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    private var marker: String {
        switch line.kind {
        case .addition: return "+"
        case .deletion: return "−"
        case .context: return " "
        }
    }

    private var markerColor: Color {
        switch line.kind {
        case .addition: return Theme.Colors.diffAddedText
        case .deletion: return Theme.Colors.diffDeletedText
        case .context: return Theme.Colors.subtle
        }
    }

    private var textColor: Color {
        line.kind == .context ? Theme.Colors.muted : Theme.Colors.text
    }

    private var background: Color {
        switch line.kind {
        case .addition: return Theme.Colors.diffAdded
        case .deletion: return Theme.Colors.diffDeleted
        case .context: return .clear
        }
    }
}

struct DiffCounts: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Text("+\(additions)")
                .foregroundStyle(Theme.Colors.diffAddedText)
            Text("−\(deletions)")
                .foregroundStyle(Theme.Colors.diffDeletedText)
        }
        .font(Theme.Typography.monoMeta)
    }
}
