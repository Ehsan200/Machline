import AppKit
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
                context.draw(
                    Text("\(row.number)")
                        .font(Theme.Typography.gutter)
                        .foregroundStyle(Theme.Colors.subtle),
                    at: CGPoint(x: size.width - Theme.Space.sm, y: row.top + row.height / 2),
                    anchor: .trailing)
            }
        }
        .frame(width: model.width)
        .background(Theme.Colors.panel)
        .overlay(alignment: .trailing) { VerticalHairline(color: Theme.Colors.divider) }
        .allowsHitTesting(false)
    }
}
