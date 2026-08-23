import Foundation
import Testing
@testable import HarnessCore

@Suite("Sharing the centre column's height")
struct PaneLayoutTests {

    static let timelineMinimum: CGFloat = 120
    static let chrome: CGFloat = 43

    private func shell(available: CGFloat, composer: CGFloat, requested: CGFloat) -> CGFloat {
        PaneLayout.shellHeight(
            requested: requested,
            available: available,
            composer: composer,
            chrome: Self.chrome,
            minimum: 120,
            maximumFraction: 0.75,
            timelineMinimum: Self.timelineMinimum)
    }

    @Test("The timeline keeps its strip when the shell opens under a tall composer")
    func leavesRoomForTheTimeline() {
        let available: CGFloat = 900
        let composer: CGFloat = 500
        let shellHeight = shell(available: available, composer: composer, requested: 675)

        #expect(shellHeight == available - composer - Self.timelineMinimum - Self.chrome)
        #expect(available - composer - shellHeight - Self.chrome >= Self.timelineMinimum)
    }

    @Test("A window with no room for both gives the shell its minimum, not the whole column")
    func neverTakesTheWholeColumn() {
        let shellHeight = shell(available: 900, composer: 630, requested: 675)
        #expect(shellHeight == 120)
        #expect(900 - 630 - shellHeight - Self.chrome > 0)
    }

    @Test("A shell asking for less than it may have keeps its own height")
    func honoursASmallerRequest() {
        #expect(shell(available: 900, composer: 250, requested: 200) == 200)
    }

    @Test("The fraction still caps a shell in a tall window with a short composer")
    func capsByFraction() {
        #expect(shell(available: 4000, composer: 200, requested: 3900) == 3000)
    }

    @Test("On a window too short for all three the shell keeps its minimum")
    func keepsAMinimum() {
        #expect(shell(available: 300, composer: 200, requested: 400) == 120)
    }

    @Test("The composer is capped by its share and by the timeline's strip")
    func composerCeiling() {
        let byFraction = PaneLayout.composerHeight(
            requested: 10_000, available: 1000, minimum: 128, maximumFraction: 0.7,
            timelineMinimum: Self.timelineMinimum)
        #expect(byFraction == 700)

        let byTimeline = PaneLayout.composerHeight(
            requested: 10_000, available: 300, minimum: 128, maximumFraction: 0.7,
            timelineMinimum: Self.timelineMinimum)
        #expect(byTimeline == 180)

        let byMinimum = PaneLayout.composerHeight(
            requested: 10_000, available: 100, minimum: 128, maximumFraction: 0.7,
            timelineMinimum: Self.timelineMinimum)
        #expect(byMinimum == 128)
    }
}
