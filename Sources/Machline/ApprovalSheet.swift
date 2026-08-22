import HarnessCore
import SwiftUI

/// The command-approval gate.
///
/// Deliberately modal and deliberately explicit. The runtime's own hook timeout fails open, so an
/// approval nobody answers ends in a denial — the countdown here tells the operator that, rather
/// than letting the sheet look like it will wait forever.
struct ApprovalSheet: View {
    @Bindable var model: AppModel
    let pending: PendingApproval

    @State private var feedback = ""
    @State private var isWritingFeedback = false
    @State private var remaining: TimeInterval = 0

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            details
            Divider()
            footer
        }
        .frame(width: 620)
        .onReceive(ticker) { _ in
            remaining = max(0, pending.deadline.timeIntervalSinceNow)
        }
        .onAppear { remaining = max(0, pending.deadline.timeIntervalSinceNow) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: riskSymbol)
                .font(.title)
                .foregroundStyle(riskTint)

            VStack(alignment: .leading, spacing: 3) {
                Text("Approve \(pending.payload.toolName)?")
                    .font(.title3.weight(.semibold))
                Text(riskDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            countdown
        }
        .padding(16)
    }

    /// Denial is the default outcome of inaction, so the countdown says exactly that.
    private var countdown: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(remaining > 0 ? formatted(remaining) : "expired")
                .font(.body.monospacedDigit())
                .foregroundStyle(remaining < 60 ? .red : .secondary)
            Text("until auto-deny")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func formatted(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            labelled("Command") {
                ScrollView(.horizontal) {
                    Text(pending.payload.bashCommand ?? pending.payload.summary)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 80)
            }

            labelled("Working directory") {
                Text(pending.payload.cwd)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if !pending.assessment.signals.isEmpty {
                labelled("Signals") {
                    FlowRow(items: pending.assessment.signals) { signal in
                        Text(signal)
                            .font(.caption)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(riskTint.opacity(0.15), in: Capsule())
                    }
                }
            }

            // Approving something the machine's own denylist refuses is a click that cannot take
            // effect: the runtime evaluates its rules after our hook and blocks it anyway, and the
            // agent is told the system refused it. Say so before the click, not after.
            if let rule = model.machineDenial(for: pending.payload.bashCommand) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your ~/.claude settings deny this")
                            .font(.callout.weight(.semibold))
                        Text("`\(rule)` blocks it in the runtime, after this gate. Approving here "
                            + "will not make it run — remove the rule, or run the session sealed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }

            if isWritingFeedback {
                labelled("Feedback to the agent") {
                    TextField(
                        "e.g. Do not delete dist/, run the clean target instead",
                        text: $feedback,
                        axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                }
            }
        }
        .padding(16)
        // Only the details. The footer's prominent button takes its colour from the tint, and a
        // selection wash is not the colour an Approve button should be.
        .selectableTextTint()
    }

    private func labelled(
        _ title: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if isWritingFeedback {
                Button("Back") { isWritingFeedback = false }
                Spacer()
                Button("Reject with feedback") {
                    model.deny(pending, feedback: feedback.isEmpty
                        ? "Rejected by the operator."
                        : feedback)
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button("Reject…") { isWritingFeedback = true }

                Button("Always allow") { model.alwaysAllow(pending) }
                    .help(alwaysAllowHelp)

                Spacer()

                Button("Reject") {
                    model.deny(pending, feedback: "Rejected by the operator.")
                }
                Button("Approve once") { model.approve(pending) }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    // A destructive command should not be one Return keypress away.
                    .tint(pending.assessment.recommendsDenyByDefault ? .orange : .accentColor)
            }
        }
        .padding(16)
    }

    private var alwaysAllowHelp: String {
        let command = pending.payload.bashCommand ?? pending.payload.summary
        let prefix = command.split(separator: " ").prefix(2).joined(separator: " ")
        return "Adds a session rule allowing commands starting with “\(prefix)”."
    }

    // MARK: - Risk presentation

    private var riskSymbol: String {
        switch pending.assessment.level {
        case .benign: return "questionmark.circle"
        case .network: return "network"
        case .privileged: return "lock.shield"
        case .destructive: return "exclamationmark.triangle.fill"
        }
    }

    private var riskTint: Color {
        switch pending.assessment.level {
        case .benign: return .accentColor
        case .network: return .blue
        case .privileged: return .orange
        case .destructive: return .red
        }
    }

    /// The wording avoids implying the classifier is authoritative — it reads patterns, and
    /// anything it cannot classify is presented as unreviewed rather than as safe.
    private var riskDescription: String {
        switch pending.assessment.level {
        case .benign: return "No known risk signals. Review the command yourself."
        case .network: return "Reaches the network or publishes something."
        case .privileged: return "Touches privileged paths or elevated permissions."
        case .destructive: return "Looks destructive. Read it carefully before approving."
        }
    }
}

/// A simple wrapping row, used for the signal chips.
struct FlowRow<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        // A LazyVGrid with adaptive columns wraps without needing a custom layout.
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 90), spacing: 6, alignment: .leading)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(items, id: \.self) { content($0) }
        }
    }
}
