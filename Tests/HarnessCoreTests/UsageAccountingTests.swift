import Foundation
import Testing
@testable import HarnessCore

@Suite("Usage accounting")
struct UsageAccountingTests {

    // MARK: - Abbreviation

    @Test("Counts abbreviate at each threshold")
    func abbreviation() {
        #expect(0.abbreviated == "0")
        #expect(999.abbreviated == "999")
        #expect(1_000.abbreviated == "1.0k")
        #expect(139_900.abbreviated == "139.9k")
        #expect(999_999.abbreviated == "1000.0k")
        #expect(1_000_000.abbreviated == "1.0m")
        #expect(2_500_000.abbreviated == "2.5m")
    }

    @Test("Durations abbreviate from milliseconds")
    func durations() {
        #expect(0.durationLabel == "0s")
        #expect(1_500.durationLabel == "1s")
        #expect(59_000.durationLabel == "59s")
        #expect(60_000.durationLabel == "1m 0s")
        #expect(3_725_000.durationLabel == "62m 5s")
    }

    // MARK: - Context fraction

    @Test("The fraction is what is used over the window")
    func fraction() {
        #expect(UsageAccounting.fraction(used: 50, window: 200) == 0.25)
        #expect(UsageAccounting.fraction(used: 200, window: 200) == 1)
    }

    /// The window is a lookup rather than something the runtime reports, so it can be wrong in the
    /// generous direction. An unclamped ring then draws past full.
    @Test("A window smaller than the usage still reads as full, not more")
    func fractionClamps() {
        #expect(UsageAccounting.fraction(used: 900, window: 200) == 1)
    }

    @Test("An unknown window reads as empty rather than dividing by zero")
    func fractionGuardsZero() {
        #expect(UsageAccounting.fraction(used: 500, window: 0) == 0)
        #expect(UsageAccounting.fraction(used: 0, window: 0) == 0)
        #expect(UsageAccounting.fraction(used: 0, window: 200) == 0)
    }

    @Test("Remaining never goes negative")
    func remaining() {
        #expect(UsageAccounting.remaining(used: 50, window: 200) == 150)
        #expect(UsageAccounting.remaining(used: 900, window: 200) == 0)
    }

    // MARK: - Cost

    @Test("No reported cost is an em dash, not zero")
    func costUnreported() {
        #expect(UsageAccounting.costLabel(forUSD: 0) == "—")
    }

    /// Rounding a fraction of a cent to `$0.00` reads as nothing having happened, which is a
    /// different claim from "this was cheap".
    @Test("Spend under a cent keeps four decimals")
    func costSubCent() {
        #expect(UsageAccounting.costLabel(forUSD: 0.0031) == "$0.0031")
        #expect(UsageAccounting.costLabel(forUSD: 0.009) == "$0.0090")
    }

    @Test("Ordinary spend rounds to cents")
    func costCents() {
        #expect(UsageAccounting.costLabel(forUSD: 0.01) == "$0.01")
        #expect(UsageAccounting.costLabel(forUSD: 12.345) == "$12.35")
    }

    // MARK: - Usage rows

    @Test("No completed turn says so instead of showing zeroes")
    func rowsWithoutTurn() {
        let rows = UsageAccounting.rows(usage: nil, turns: nil, spent: 0)
        #expect(rows == [UsageAccounting.Row(label: "No turn has completed yet.", value: "")])
    }

    @Test("Reported keys become rows, in reading order")
    func rowsFromUsage() {
        let usage = JSONValue.object([
            "input_tokens": .int(1_200),
            "output_tokens": .int(340),
            "cache_creation_input_tokens": .int(9_000),
            "cache_read_input_tokens": .int(1_500_000)
        ])
        let rows = UsageAccounting.rows(usage: usage, turns: 3, spent: 2_000_000)
        #expect(rows == [
            .init(label: "Input", value: "1.2k"),
            .init(label: "Output", value: "340"),
            .init(label: "Cache write", value: "9.0k"),
            .init(label: "Cache read", value: "1.5m"),
            .init(label: "Turns", value: "3"),
            .init(label: "Spent this session", value: "2.0m")
        ])
    }

    /// The runtime omits what did not happen. A row reading `Cache read 0` claims a cache miss
    /// that the turn never reported either way.
    @Test("Absent keys are left out rather than shown as zero")
    func rowsSkipAbsentKeys() {
        let usage = JSONValue.object(["input_tokens": .int(10)])
        let rows = UsageAccounting.rows(usage: usage, turns: nil, spent: 10)
        #expect(rows.map(\.label) == ["Input", "Spent this session"])
    }

    @Test("A usage block that is not an object degrades to the spend row")
    func rowsFromNonObject() {
        let rows = UsageAccounting.rows(usage: .string("unexpected"), turns: nil, spent: 42)
        #expect(rows == [.init(label: "Spent this session", value: "42")])
    }
}
