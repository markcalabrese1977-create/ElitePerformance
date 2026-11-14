// Domain/Analytics/MesoRemaining.swift
import Foundation

/// How much of the active meso is left, for the "What's next?" panel of the meso summary. While planned sessions remain
/// before the final week, the block is not finished: no verdict yet, and a new block starts the day after the last one.
struct MesoRemaining: Equatable {
    /// Sessions not yet completed whose date is today or later.
    let remainingSessions: Int
    /// The last of them, nil when none remain.
    let lastPlannedDate: Date?
    /// Whole weeks until the last planned session (rounded up, at least 1); 0 when none remain.
    let weeksRemaining: Int
    /// True in the final week (the last planned session is within 7 days) or once nothing remains: the verdict and a
    /// "tomorrow" start apply.
    let isFinalWeekOrOver: Bool
    /// The default start date of the next block.
    let defaultStart: Date

    static func compute(sessions: [(date: Date, status: SessionStatus)], now: Date = Date(), calendar: Calendar = .current) -> MesoRemaining {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let left = sessions.filter { $0.status != .completed && calendar.startOfDay(for: $0.date) >= today }
        guard let last = left.map({ calendar.startOfDay(for: $0.date) }).max() else {
            return MesoRemaining(remainingSessions: 0, lastPlannedDate: nil, weeksRemaining: 0, isFinalWeekOrOver: true, defaultStart: tomorrow)
        }
        let days = calendar.dateComponents([.day], from: today, to: last).day ?? 0
        let weeks = max(1, Int((Double(days) / 7).rounded(.up)))
        let final = days < 7
        return MesoRemaining(
            remainingSessions: left.count, lastPlannedDate: last, weeksRemaining: weeks, isFinalWeekOrOver: final,
            defaultStart: final ? tomorrow : calendar.date(byAdding: .day, value: 1, to: last)!)
    }
}

extension MesoRemaining {
    /// THE one statement of how much of the block is left, used by the Meso Summary's header narrative AND its "What's next?"
    /// card so they can never disagree: "Week 8 of 12 · 9 sessions left (last Jan 30, 2027)". Nil when nothing remains.
    func statusLine(week: Int, totalWeeks: Int) -> String? {
        guard remainingSessions > 0 else { return nil }
        let last = lastPlannedDate.map { " (last \($0.formatted(date: .abbreviated, time: .omitted)))" } ?? ""
        return "Week \(week) of \(totalWeeks) · \(remainingSessions) session\(remainingSessions == 1 ? "" : "s") left\(last)"
    }

    /// The "What's next?" headline while sessions remain: the status line, then the next-block guidance.
    func cardHeadline(week: Int, totalWeeks: Int, finalWeekGuidance: String) -> String? {
        guard let line = statusLine(week: week, totalWeeks: totalWeeks) else { return nil }
        let guidance = isFinalWeekOrOver
            ? finalWeekGuidance
            : "The next block starts the day after the last planned session; pick it when this one is nearly done."
        return "\(line). \(guidance)"
    }
}

/// The header of the Meso Summary: where the block stands.
struct MesoHeader: Equatable {
    let name: String
    /// The week the lifter is in: the week of today's or the next unfinished session, else the last week of the block.
    let currentWeek: Int
    let totalWeeks: Int
    /// Sessions completed, and sessions that were due up to and including today.
    let completed: Int
    let planned: Int

    var weekText: String { "Week \(currentWeek) of \(totalWeeks)" }
    var sessionsText: String { "\(completed)/\(planned) sessions" }

    static func compute(
        name: String, totalWeeks: Int?,
        sessions: [(date: Date, plannedDate: Date?, status: SessionStatus, weekIndex: Int)],
        now: Date = Date(), calendar: Calendar = .current
    ) -> MesoHeader {
        let today = calendar.startOfDay(for: now)
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: today)!
        let maxWeek = sessions.map(\.weekIndex).max() ?? 1
        let upcoming = sessions.filter { $0.status != .completed && calendar.startOfDay(for: $0.date) >= today }
            .min { $0.date < $1.date }
        let week = upcoming?.weekIndex ?? maxWeek
        let due = sessions.filter { $0.status == .completed || ($0.plannedDate ?? $0.date) < endOfToday }
        return MesoHeader(
            name: name, currentWeek: min(week, max(totalWeeks ?? maxWeek, 1)), totalWeeks: max(totalWeeks ?? maxWeek, 1),
            completed: sessions.filter { $0.status == .completed }.count, planned: due.count)
    }
}
