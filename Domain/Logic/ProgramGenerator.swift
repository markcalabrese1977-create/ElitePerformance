import Foundation
import SwiftData

/// Generates an initial block of sessions for a new user.
///
/// v2:
/// - Supports multi-week blocks (up to 8 "hard" weeks).
/// - Optional deload week at the end.
/// - Currently uses a fixed Push / Pull / Legs rotation.
/// - Starting loads are left at 0.0 – to be set later via planning UI.
struct ProgramGenerator {

    /// Seed a full block of training sessions.
    ///
    // MARK: - Weekday helpers

    /// Default weekday pattern for a given frequency.
    /// 1 = Sunday ... 7 = Saturday
    private static func defaultWeekdays(for days: Int) -> [Int] {
        switch days {
        case 2:  return [2, 5]                 // Mon, Thu
        case 3:  return [2, 4, 6]              // Mon, Wed, Fri
        case 4:  return [2, 3, 5, 6]           // Mon, Tue, Thu, Fri
        case 5:  return [2, 3, 4, 5, 6]        // Mon–Fri
        case 6:  return [2, 3, 4, 5, 6, 7]     // Mon–Sat
        default: return [2, 4, 6]              // fallback: Mon, Wed, Fri
        }
    }

    /// Normalize the provided weekdays to a clean pattern of length `daysPerWeek`.
    private static func normalizedTrainingWeekdays(
        daysPerWeek: Int,
        provided: [Int]?
    ) -> [Int] {
        guard let provided, !provided.isEmpty else {
            return defaultWeekdays(for: daysPerWeek)
        }

        // Clamp to 1–7, dedupe, sort
        var normalized = Array(
            Set(
                provided.map { min(max($0, 1), 7) }
            )
        ).sorted()

        if normalized.count >= daysPerWeek {
            return Array(normalized.prefix(daysPerWeek))
        } else {
            // If fewer provided than daysPerWeek, fill with defaults
            var result = normalized
            let defaults = defaultWeekdays(for: daysPerWeek)
            for w in defaults where result.count < daysPerWeek {
                if !result.contains(w) {
                    result.append(w)
                }
            }
            return result
        }
    }

    /// Build a list of session dates using the given weekday pattern,
    /// starting from `today`, until we have `totalSessions` dates.
    private static func buildSessionDates(
        calendar: Calendar,
        today: Date,
        weekdays: [Int],
        totalSessions: Int
    ) -> [Date] {
        var dates: [Date] = []
        dates.reserveCapacity(totalSessions)

        var current = today

        for i in 0..<totalSessions {
            // First session can be today; subsequent ones start at +1 day
            let start = (i == 0)
                ? current
                : (calendar.date(byAdding: .day, value: 1, to: current) ?? current)

            var candidate = start
            while true {
                let weekday = calendar.component(.weekday, from: candidate)
                if weekdays.contains(weekday) {
                    break
                }
                candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            }

            dates.append(candidate)
            current = candidate
        }

        return dates
    }
    
    /// - Parameters:
    ///   - goal: User's primary goal (strength / hypertrophy / fat loss).
    ///   - daysPerWeek: Planned training days per week (e.g. 3–6).
    ///   - totalWeeks: Number of "hard" weeks (1–8). Deload week is added on top if requested.
    ///   - includeDeloadWeek: If true, appends a lighter deload week at the end.
    ///   - context: SwiftData model context.
    static func seedInitialProgram(
        goal: Goal,
        daysPerWeek: Int,
        totalWeeks: Int,
        includeDeloadWeek: Bool,
        trainingDaysOfWeek: [Int]? = nil,
        context: ModelContext
    ) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Clamp inputs to sane ranges
        let trainingDays = max(daysPerWeek, 1)
        let hardWeeks = max(1, min(totalWeeks, 8))
        let totalWeeksCount = includeDeloadWeek ? hardWeeks + 1 : hardWeeks

        // Normalize the weekday pattern for this frequency
        let weekdayPattern = normalizedTrainingWeekdays(
            daysPerWeek: trainingDays,
            provided: trainingDaysOfWeek
        )

        // Build the exact dates we’ll use for each session in order
        let sessionsPerWeek = trainingDays
        let totalSessions = totalWeeksCount * sessionsPerWeek

        let sessionDates = buildSessionDates(
            calendar: calendar,
            today: today,
            weekdays: weekdayPattern,
            totalSessions: totalSessions
        )

        // Clear any existing planned sessions? For now, we assume a fresh user.
        // If you later support re-programming mid-block, you'll want a more
        // careful strategy here instead of blanket deletion.

        var globalDay = 0

        for weekIndex in 0..<totalWeeksCount {
            let isDeload = includeDeloadWeek && (weekIndex == totalWeeksCount - 1)

            for dayIndex in 0..<trainingDays {
                guard globalDay < sessionDates.count else { break }

                let date = sessionDates[globalDay]

                // Simple PPL rotation across the block
                let focusIndex = globalDay % 3

                var exercisesForDay: [CatalogExercise]

                // ... existing switch on focusIndex and all the sets/reps logic ...

                // (Everything from the `switch focusIndex { ... }` down to
                //  `context.insert(session)` stays exactly the same; just use
                //  `date` and `weekIndex` as before.)

                globalDay += 1
            }
        }

        // Persist all created sessions
        try? context.save()
    }
}
