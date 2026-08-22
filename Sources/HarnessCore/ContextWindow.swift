import Foundation

/// How much context a model has.
///
/// The runtime reports how many tokens a turn used but never the size of the window they went
/// into, so the denominator has to come from somewhere. A lookup is honest about being a lookup;
/// the numerator beside it is always the runtime's own number.
public enum ContextWindow {
    public static let small = 200_000
    public static let large = 1_000_000

    /// Models with a 1M window. Matched as prefixes so a dated snapshot
    /// (`claude-opus-4-5-20251101`) resolves the same as its base id.
    private static let largeWindowModels = [
        "claude-fable-5", "claude-mythos-5",
        "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6",
        "claude-sonnet-5", "claude-sonnet-4-6"
    ]

    /// Aliases the CLI accepts in place of a model id. `opus` and `sonnet` track the latest in
    /// their family, which is 1M today; `haiku` is not.
    private static let largeWindowAliases = ["opus", "sonnet", "fable", "mythos"]

    /// The window for a model name, alias, or `nil`.
    ///
    /// Defaults to the smaller window when nothing matches: understating the denominator shows the
    /// context fuller than it is, which fails toward caution rather than toward a surprise.
    public static func size(forModel name: String?) -> Int {
        guard let name, !name.isEmpty else { return small }
        let lowered = name.lowercased()

        // An explicit 1M suffix wins over anything inferred from the family.
        if lowered.contains("[1m]") || lowered.hasSuffix("-1m") { return large }
        if largeWindowModels.contains(where: { lowered.hasPrefix($0) }) { return large }
        if largeWindowAliases.contains(lowered) { return large }
        return small
    }
}
