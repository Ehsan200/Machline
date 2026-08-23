import AppKit
import HarnessCore
import Observation
import SwiftUI

/// One line's number and where its fragment sits in the viewport.
struct GutterRow: Identifiable, Equatable {
    var id: Int { number }
    let number: Int
    let top: CGFloat
    let height: CGFloat
}

/// What the gutter draws, published by the editor's coordinator as the viewport moves.
@MainActor
@Observable
final class EditorGutterModel {
    private(set) var rows: [GutterRow] = []
    private(set) var lineCount = 1
    /// What Git says about each line, keyed by line number in the working tree.
    var marks: [Int: GitLineMark] = [:]

    /// Wide enough for the longest line number, and no wider.
    var width: CGFloat {
        let digits = max(2, String(max(lineCount, 1)).count)
        return ceil(CGFloat(digits) * Self.digitWidth) + Theme.Space.lg
    }

    private static let digitWidth = Fonts.nsMono(size: 10.5).maximumAdvancement.width

    /// Writes only on a real change: each one invalidates the `Canvas`, and the coordinator
    /// offers a snapshot on every scroll frame.
    func update(rows: [GutterRow], lineCount: Int) {
        if self.rows != rows { self.rows = rows }
        if self.lineCount != lineCount { self.lineCount = lineCount }
    }
}

/// Line numbers beside the editor.
///
/// SwiftUI, not AppKit, and that is load-bearing. An `NSView` sibling of the scroll view stops the
/// text view's TextKit 2 fragments *and* the surrounding SwiftUI from compositing the moment it
/// draws anything — bisected in a standalone harness: empty `draw(_:)` renders, any drawing blanks
/// the window. Not `isFlipped`, not the scroll view's offset, not fixed by `wantsLayer`. An
/// `NSRulerView` fails differently and just as totally: it never re-tiles, so the clip view's bounds
/// origin goes negative and the viewport lays out against that.
///
/// One number per paragraph — a wrapped line is still one line.
struct GutterView: View {
    let model: EditorGutterModel

    var body: some View {
        Canvas { context, size in
            for row in model.rows {
                if let mark = model.marks[row.number] {
                    context.fill(Self.marker(for: mark, row: row, in: size), with: .color(tint(mark)))
                }
                context.draw(
                    Text("\(row.number)")
                        .font(Theme.Typography.gutter)
                        .foregroundStyle(model.marks[row.number] == nil
                            ? Theme.Colors.subtle : Theme.Colors.muted),
                    at: CGPoint(x: size.width - Theme.Space.sm, y: row.top + row.height / 2),
                    anchor: .trailing)
            }
        }
        .frame(width: model.width)
        .background(Theme.Colors.panel)
        .overlay(alignment: .trailing) { VerticalHairline(color: Theme.Colors.divider) }
        .allowsHitTesting(false)
    }

    /// A bar down the outer edge for a line that is still there, and a wedge at the seam for one
    /// that is not — a removal has no row of its own to colour.
    private static func marker(for mark: GitLineMark, row: GutterRow, in size: CGSize) -> Path {
        let width: CGFloat = 2
        guard mark != .removed else {
            return Path { path in
                path.move(to: CGPoint(x: 0, y: row.top + 3))
                path.addLine(to: CGPoint(x: width * 2, y: row.top))
                path.addLine(to: CGPoint(x: 0, y: row.top - 3))
                path.closeSubpath()
            }
        }
        return Path(CGRect(x: 0, y: row.top, width: width, height: row.height))
    }

    private func tint(_ mark: GitLineMark) -> Color {
        switch mark {
        case .added: return Theme.Colors.diffAddedText
        case .modified: return Theme.Colors.link
        case .removed: return Theme.Colors.diffDeletedText
        }
    }
}
