import Foundation

/// How the centre column's height is shared between the timeline, the shell, and the composer.
///
/// In the view each pane sized itself against the window alone, so the timeline — the only one
/// without a minimum in that sum — could be squeezed to nothing.
public enum PaneLayout {

    public static func composerHeight(
        requested: CGFloat,
        available: CGFloat,
        minimum: CGFloat,
        maximumFraction: CGFloat,
        timelineMinimum: CGFloat
    ) -> CGFloat {
        let ceiling = max(minimum, min(available * maximumFraction, available - timelineMinimum))
        return min(requested, ceiling)
    }

    public static func shellHeight(
        requested: CGFloat,
        available: CGFloat,
        composer: CGFloat,
        chrome: CGFloat,
        minimum: CGFloat,
        maximumFraction: CGFloat,
        timelineMinimum: CGFloat
    ) -> CGFloat {
        min(requested, shellCeiling(
            available: available, composer: composer, chrome: chrome, minimum: minimum,
            maximumFraction: maximumFraction, timelineMinimum: timelineMinimum))
    }

    /// `chrome` is the pane's handle and header, which take height whatever is left. On a window
    /// too short for all three the shell keeps `minimum` and the timeline gives way.
    public static func shellCeiling(
        available: CGFloat,
        composer: CGFloat,
        chrome: CGFloat,
        minimum: CGFloat,
        maximumFraction: CGFloat,
        timelineMinimum: CGFloat
    ) -> CGFloat {
        let remaining = available - composer - timelineMinimum - chrome
        return max(minimum, min(available * maximumFraction, remaining))
    }
}
