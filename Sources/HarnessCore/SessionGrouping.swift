import Foundation

/// When a conversation happened, coarse enough to group by.
public enum SessionAge: String, Sendable, CaseIterable, Identifiable {
    case today
    case yesterday
    case thisWeek
    case earlier

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .thisWeek: return "Earlier this week"
        case .earlier: return "Older"
        }
    }

    /// Whether the group is worth having open by default.
    ///
    /// Only today's work is; everything else is history, and a rail that opens with two hundred
    /// rows makes the handful that matter impossible to find.
    public var isExpandedByDefault: Bool { self == .today }

    public static func of(
        _ date: Date, now: Date = Date(), calendar: Calendar = .current
    ) -> SessionAge {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        // Seven days back rather than "this calendar week": on a Monday the latter would put
        // Friday's work in Older.
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now), date > weekAgo {
            return .thisWeek
        }
        return .earlier
    }
}

/// Conversations split into age groups, newest group first, empty groups dropped.
public struct SessionGroup: Sendable, Identifiable {
    public let age: SessionAge
    public let sessions: [HistoricalSession]

    public var id: String { age.rawValue }

    public init(age: SessionAge, sessions: [HistoricalSession]) {
        self.age = age
        self.sessions = sessions
    }

    public static func group(
        _ sessions: [HistoricalSession], now: Date = Date(), calendar: Calendar = .current
    ) -> [SessionGroup] {
        var byAge: [SessionAge: [HistoricalSession]] = [:]
        for session in sessions {
            byAge[SessionAge.of(session.lastActivityAt, now: now, calendar: calendar), default: []]
                .append(session)
        }
        return SessionAge.allCases.compactMap { age in
            guard let found = byAge[age], !found.isEmpty else { return nil }
            return SessionGroup(
                age: age,
                sessions: found.sorted { $0.lastActivityAt > $1.lastActivityAt })
        }
    }
}
