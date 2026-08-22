import HarnessCore
import SwiftUI

/// What the agent is doing right now, at the foot of the timeline.
///
/// Only facts the runtime reports: the state it is in, how long it has been there, and the counts
/// it has published. Nothing is estimated — an invented token count during a stream would be a
/// number the operator could act on and should not.
struct ActivityIndicator: View {
    let node: AgentNode
    let startedAt: Date

    @State private var now = Date()
    @State private var phase = 0

    /// Two ticks a second: enough for a seconds counter and a spinner, cheap enough to leave on.
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Text(Self.markers[phase % Self.markers.count])
                .font(Theme.Typography.monoStrong)
                .foregroundStyle(Theme.Colors.accent)
                .frame(width: 12, alignment: .center)

            Text(verb)
                .font(Theme.Typography.control)
                .foregroundStyle(Theme.Colors.textStrong)

            Text(facts)
                .font(Theme.Typography.monoMeta)
                .foregroundStyle(Theme.Colors.subtle)

            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Space.md)
        .onReceive(tick) { instant in
            now = instant
            phase += 1
        }
    }

    /// A rotating asterisk rather than a spinner: it sits on the text baseline and costs nothing.
    private static let markers = ["✳", "✴", "✳", "✳"]

    private var verb: String {
        switch node.state {
        case .thinking: return "Thinking…"
        case .executingTool(let name, _): return "\(name)…"
        case .waitingForApproval(let name, _): return "Waiting on approval for \(name)"
        case .blocked(let reason): return reason
        default: return "Working…"
        }
    }

    private var facts: String {
        var parts = [elapsed]
        if node.telemetry.toolUseCount > 0 {
            parts.append("\(node.telemetry.toolUseCount) tools")
        }
        if let tokens = node.telemetry.totalTokens, tokens > 0 {
            parts.append("↓ \(tokens.abbreviated) tokens")
        }
        return "(\(parts.joined(separator: " · ")))"
    }

    private var elapsed: String {
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}
