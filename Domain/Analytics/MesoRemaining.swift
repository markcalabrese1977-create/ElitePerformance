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
