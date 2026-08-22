import Foundation
import Testing
@testable import HarnessCore

/// A rail that opens with two hundred rows hides the handful that matter, so history is grouped
/// by age and only today's group opens by default.
struct SessionGroupingTests {

    private let calendar = Calendar(identifier: .gregorian)
    private lazy var now: Date = {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 22, hour: 14))!
    }()

    private func session(_ date: Date) -> HistoricalSession {
        HistoricalSession(
            id: UUID().uuidString, fileURL: URL(fileURLWithPath: "/tmp/x.jsonl"),
            cwd: "/tmp", firstPrompt: "prompt", startedAt: date, lastActivityAt: date,
            gitBranch: nil, cliVersion: nil, model: nil, byteCount: 0)
    }

    @Test("Ages are assigned from the day, not from elapsed hours")
    mutating func agesByDay() {
        let now = self.now
        // 01:00 today is 13 hours ago but still today; 23:00 yesterday is 15 hours ago and is not.
        let earlyToday = calendar.date(bySettingHour: 1, minute: 0, second: 0, of: now)!
        let lateYesterday = calendar.date(byAdding: .hour, value: -15, to: now)!

        #expect(SessionAge.of(earlyToday, now: now, calendar: calendar) == .today)
        #expect(SessionAge.of(lateYesterday, now: now, calendar: calendar) == .yesterday)
    }

    /// Seven days back rather than the calendar week: on a Monday, "this week" would otherwise put
    /// Friday's work in Older.
    @Test("Recent days land in this week, older ones in Older")
    mutating func weekBoundary() {
        let now = self.now
        let fourDaysAgo = calendar.date(byAdding: .day, value: -4, to: now)!
        let tenDaysAgo = calendar.date(byAdding: .day, value: -10, to: now)!

        #expect(SessionAge.of(fourDaysAgo, now: now, calendar: calendar) == .thisWeek)
        #expect(SessionAge.of(tenDaysAgo, now: now, calendar: calendar) == .earlier)
    }

    @Test("Only today opens by default")
    func onlyTodayIsExpanded() {
        #expect(SessionAge.today.isExpandedByDefault)
        for age in [SessionAge.yesterday, .thisWeek, .earlier] {
            #expect(!age.isExpandedByDefault, "\(age)")
        }
    }

    @Test("Groups come back newest first with empty ones dropped")
    mutating func groupOrdering() {
        let now = self.now
        let sessions = [
            session(calendar.date(byAdding: .day, value: -10, to: now)!),
            session(now),
            session(calendar.date(byAdding: .day, value: -1, to: now)!)
        ]
        let groups = SessionGroup.group(sessions, now: now, calendar: calendar)

        #expect(groups.map(\.age) == [.today, .yesterday, .earlier])
        #expect(!groups.contains { $0.age == .thisWeek })
    }

    @Test("Sessions within a group are newest first")
    mutating func withinGroupOrdering() {
        let now = self.now
        let older = session(calendar.date(byAdding: .hour, value: -5, to: now)!)
        let newer = session(now)
        let groups = SessionGroup.group([older, newer], now: now, calendar: calendar)

        #expect(groups.count == 1)
        #expect(groups[0].sessions.map(\.id) == [newer.id, older.id])
    }

    @Test("No sessions means no groups")
    func emptyInput() {
        #expect(SessionGroup.group([]).isEmpty)
    }
}

/// Grouping keys off the transcript's last write. Several transcripts sharing a modification time
/// is ordinary — resuming one rewrites it — so the grouping must stay stable when it happens.
struct SessionGroupingStabilityTests {

    private let calendar = Calendar(identifier: .gregorian)

    private func session(_ id: String, _ date: Date) -> HistoricalSession {
        HistoricalSession(
            id: id, fileURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"),
            cwd: "/tmp", firstPrompt: id, startedAt: date, lastActivityAt: date,
            gitBranch: nil, cliVersion: nil, model: nil, byteCount: 0)
    }

    @Test("Sessions sharing a timestamp all land in the same group and none are lost")
    func identicalTimestamps() {
        let now = Date()
        let sessions = ["a", "b", "c"].map { session($0, now) }
        let groups = SessionGroup.group(sessions, now: now, calendar: calendar)

        #expect(groups.count == 1)
        #expect(groups[0].age == .today)
        #expect(Set(groups[0].sessions.map(\.id)) == ["a", "b", "c"])
    }

    /// Ids are what the rail matches the running session against, so a group must never merge two.
    @Test("Every session keeps its own identity through grouping")
    func identitiesArePreserved() {
        let now = Date()
        let old = calendar.date(byAdding: .day, value: -9, to: now)!
        let groups = SessionGroup.group(
            [session("new", now), session("old", old)], now: now, calendar: calendar)

        let ids = groups.flatMap { $0.sessions.map(\.id) }
        #expect(ids.count == Set(ids).count)
        #expect(Set(ids) == ["new", "old"])
    }
}

/// Opening a conversation makes the CLI append to its transcript immediately, so the file's
/// modification date is not when the conversation last had a message in it. Using mtime meant that
/// merely clicking a months-old session restamped it as "just now" and jumped it to the top of
/// Today — reordering the list the operator was reading, under their cursor.
struct LastActivityTests {

    private func makeTranscript(
        entries: [(stamp: String?, text: String)]
    ) throws -> (url: URL, byteCount: Int) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("session.jsonl")

        let lines = entries.map { entry -> String in
            if let stamp = entry.stamp {
                return #"{"type":"user","timestamp":"\#(stamp)","text":"\#(entry.text)"}"#
            }
            return #"{"type":"queue-operation","text":"\#(entry.text)"}"#
        }
        let body = lines.joined(separator: "\n")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return (url, body.utf8.count)
    }

    @Test("The last timestamped entry is what counts")
    func readsLastTimestamp() throws {
        let file = try makeTranscript(entries: [
            (stamp: "2026-08-11T09:00:00.000Z", text: "first"),
            (stamp: "2026-08-13T17:30:00.000Z", text: "last")
        ])
        let found = try #require(
            SessionHistory.lastEntryDate(url: file.url, byteCount: file.byteCount))

        let expected = ISO8601DateFormatter.transcript().date(from: "2026-08-13T17:30:00.000Z")
        #expect(found == expected)
    }

    /// Resuming writes untimestamped bookkeeping lines to the end of the transcript. Those must not
    /// become the conversation's last activity.
    @Test("Untimestamped trailing entries are skipped")
    func skipsUntimestampedTail() throws {
        let file = try makeTranscript(entries: [
            (stamp: "2026-08-11T09:00:00.000Z", text: "real message"),
            (stamp: nil, text: "enqueue"),
            (stamp: nil, text: "dequeue")
        ])
        let found = try #require(
            SessionHistory.lastEntryDate(url: file.url, byteCount: file.byteCount))

        #expect(found == ISO8601DateFormatter.transcript().date(from: "2026-08-11T09:00:00.000Z"))
    }

    @Test("A transcript with no timestamps reports none, so the caller can fall back")
    func noTimestamps() throws {
        let file = try makeTranscript(entries: [(stamp: nil, text: "enqueue")])
        #expect(SessionHistory.lastEntryDate(url: file.url, byteCount: file.byteCount) == nil)
    }

    /// The tail is read from a fixed offset, which lands mid-line; that partial line must not be
    /// parsed as if it were whole.
    @Test("A large transcript still reports its final timestamp")
    func largeTranscript() throws {
        var entries: [(stamp: String?, text: String)] = (0..<4000).map {
            (stamp: "2026-08-01T00:00:00.000Z", text: "padding \($0) \(String(repeating: "x", count: 40))")
        }
        entries.append((stamp: "2026-08-20T12:00:00.000Z", text: "final"))
        let file = try makeTranscript(entries: entries)

        let found = try #require(
            SessionHistory.lastEntryDate(url: file.url, byteCount: file.byteCount))
        #expect(found == ISO8601DateFormatter.transcript().date(from: "2026-08-20T12:00:00.000Z"))
    }
}
