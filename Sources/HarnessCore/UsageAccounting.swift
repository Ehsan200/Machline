import Foundation

extension Int {
    /// `139900` → `139.9k`. Used wherever a token count would otherwise dominate a narrow row.
    public var abbreviated: String {
        if self >= 1_000_000 { return String(format: "%.1fm", Double(self) / 1_000_000) }
        if self >= 1_000 { return String(format: "%.1fk", Double(self) / 1_000) }
        return "\(self)"
    }

    /// Milliseconds as a compact duration.
    public var durationLabel: String {
        let seconds = self / 1000
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}

/// What the context ring and the usage table are reading.
///
/// Pure arithmetic and formatting over figures the runtime reported, kept out of the view model so
/// it can be tested: every one of these has a boundary that reads wrong rather than crashing when
/// it slips, which is the kind of thing that survives a long time unnoticed.
public enum UsageAccounting {

    public struct Row: Equatable, Sendable {
        public let label: String
        public let value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    /// How full the context window is, as a proportion.
    ///
    /// Clamped: the window size is a lookup rather than something the runtime reports, so a model
    /// whose real window is smaller than the table says would otherwise drive the ring past full.
    public static func fraction(used: Int, window: Int) -> Double {
        guard window > 0, used > 0 else { return 0 }
        return min(1, Double(used) / Double(window))
    }

    /// Tokens left in the window.
    public static func remaining(used: Int, window: Int) -> Int {
        max(0, window - used)
    }

    /// Session spend, or an em dash when no turn has reported one.
    ///
    /// Under a cent is still spend, and rounding it to `$0.00` reads as nothing having happened.
    public static func costLabel(forUSD cost: Double) -> String {
        guard cost > 0 else { return "—" }
        return cost < 0.01
            ? String(format: "$%.4f", cost)
            : String(format: "$%.2f", cost)
    }

    /// The breakdown under the ring, built from the last turn's `usage` block.
    ///
    /// Keys absent from the block are left out rather than shown as zero: the runtime omits what
    /// did not happen, and a row reading `Cache read 0` claims a cache miss that may not have
    /// occurred.
    public static func rows(usage: JSONValue?, turns: Int?, spent: Int) -> [Row] {
        guard let usage else {
            return [Row(label: "No turn has completed yet.", value: "")]
        }

        var rows: [Row] = []
        func add(_ label: String, _ key: String) {
            guard let value = usage[key]?.intValue else { return }
            rows.append(Row(label: label, value: value.abbreviated))
        }
        add("Input", "input_tokens")
        add("Output", "output_tokens")
        add("Cache write", "cache_creation_input_tokens")
        add("Cache read", "cache_read_input_tokens")
        if let turns {
            rows.append(Row(label: "Turns", value: "\(turns)"))
        }
        rows.append(Row(label: "Spent this session", value: spent.abbreviated))
        return rows
    }
}
