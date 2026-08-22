import AppKit
import SwiftUI

/// The small pieces more than one screen needs.
///
/// Anything drawn twice belongs here rather than in both places: a pill, a countdown, the surface
/// under a hoverable row. Screens compose these; they do not re-implement them.

/// A capsule-shaped button: a project chip, a jump-to-latest affordance, a filter tag.
struct Pill: View {
    let title: String
    var systemImage: String?
    /// Filled in the accent colour rather than the panel colour, for a pill that is an action
    /// rather than a choice among many.
    var isProminent = false
    var help: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: isProminent ? .semibold : .regular))
                        .foregroundStyle(isProminent ? Theme.Colors.textStrong : Theme.Colors.subtle)
                }
                Text(title)
                    .font(isProminent ? Theme.Typography.meta : Theme.Typography.control)
                    .foregroundStyle(isProminent ? Theme.Colors.textStrong : Theme.Colors.text)
                    .lineLimit(1)
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.xs + 1)
            .background(Capsule().fill(background))
            .overlay(Capsule().strokeBorder(Theme.Colors.border, lineWidth: Theme.Layout.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .modifier(OptionalHelp(text: help))
    }

    private var background: Color {
        if isProminent { return Theme.Colors.surface }
        return isHovering ? Theme.Colors.hover : Theme.Colors.panel
    }
}

/// `.help` only when there is something to say, so call sites do not each write the `if`.
private struct OptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}

/// The time left before the runtime answers on the operator's behalf.
///
/// Shared by every sheet that sits on a deadline: inaction has a consequence, and the sheet says
/// what it is rather than looking as though it will wait forever.
struct Countdown: View {
    let deadline: Date
    /// What happens when it runs out, in three or four words.
    let outcome: String

    @State private var remaining: TimeInterval = 0

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(remaining > 0 ? Self.formatted(remaining) : "expired")
                .font(.body.monospacedDigit())
                .foregroundStyle(remaining < 60 ? .red : .secondary)
            Text(outcome)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .onReceive(ticker) { _ in remaining = max(0, deadline.timeIntervalSinceNow) }
        .onAppear { remaining = max(0, deadline.timeIntervalSinceNow) }
    }

    static func formatted(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension View {
    /// The surface every selectable row shares: selected wins over hovered, both over nothing.
    func rowSurface(isSelected: Bool, isHovering: Bool) -> some View {
        background(
            isSelected
                ? Theme.Colors.selection
                : (isHovering ? Theme.Colors.hover.opacity(0.5) : Color.clear))
    }
}

extension NSEvent {
    /// Whether ⌘ is held at this instant.
    ///
    /// A SwiftUI `Button` action carries no event, so a control that means one thing on a click
    /// and another on a ⌘-click has to read the flags itself. One place, so every such control
    /// agrees on what "⌘-click" means.
    static var isCommandHeld: Bool { modifierFlags.contains(.command) }
}
