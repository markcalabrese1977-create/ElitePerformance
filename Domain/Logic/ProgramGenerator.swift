import Foundation
import SwiftData

/// Generates an initial block of sessions for a new user.
///
/// v2:
/// - Supports multi-week blocks (up to 8 "hard" weeks).
/// - Optional deload week at the end.
/// - Currently uses a fixed Push / Pull / Legs rotation.
/// - Starting loads are left at 0.0 – to be set later via planning UI.
/// - Honors exact user-selected weekdays; no auto-filled days.
/// Provided `weekdays` are the single source of truth and use Calendar weekday numbers (1=Sun...7=Sat).
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

        return normalized
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
    
    private static func defaultMesoName(
        goal: Goal,
        daysPerWeek: Int,
        totalWeeks: Int,
        includeDeloadWeek: Bool
    ) -> String {
        let goalText: String
        switch goal {
        case .strength:
            goalText = "Strength"
        case .fatLoss:
            goalText = "Fat Loss"
        case .hypertrophy:
            goalText = "Hypertrophy"
        case .longevity:
            goalText = "Longevity"
        @unknown default:
            goalText = "Training"
        }

        let deloadText = includeDeloadWeek ? " + Deload" : ""
        return "\(goalText) \(daysPerWeek)-Day Block (\(totalWeeks) Weeks\(deloadText))"
    }
    
    /// - Parameters:
    ///   - goal: User's primary goal (strength / hypertrophy / fat loss).
    ///   - daysPerWeek: Planned training days per week (e.g. 3–6).
    ///   - totalWeeks: Number of "hard" weeks (1–8). Deload week is added on top if requested.
    ///   - includeDeloadWeek: If true, appends a lighter deload week at the end.
    ///   - weekdays: Optional user-selected training weekdays (1 = Sunday ... 7 = Saturday). Overrides defaults.
    ///   - startDate: Optional start date for the program. Defaults to today.
    ///   - context: SwiftData model context.
    static func seedInitialProgram(
        goal: Goal,
        daysPerWeek: Int,
        totalWeeks: Int,
        includeDeloadWeek: Bool,
        weekdays: [Int]? = nil,
        startDate: Date? = nil,
        context: ModelContext
    ) {
        let calendar = Calendar.current
        let baseStart = startDate ?? Date()
        let today = calendar.startOfDay(for: baseStart)

        let desiredDays = max(daysPerWeek, 1)
        let hardWeeks = max(1, min(totalWeeks, 12))
        let totalWeeksCount = includeDeloadWeek ? hardWeeks + 1 : hardWeeks

        let trainingWeekdays = normalizedTrainingWeekdays(
            daysPerWeek: desiredDays,
            provided: weekdays
        )
        let trainingDays = trainingWeekdays.count

        let totalSessions = trainingDays * totalWeeksCount
        let sessionDates = buildSessionDates(
            calendar: calendar,
            today: today,
            weekdays: trainingWeekdays,
            totalSessions: totalSessions
        )

        let mesoName = defaultMesoName(
            goal: goal,
            daysPerWeek: trainingDays,
            totalWeeks: hardWeeks,
            includeDeloadWeek: includeDeloadWeek
        )

        let mesoBlock = MesoBlock(
            name: mesoName,
            startDate: today,
            status: .active,
            notes: "Seeded via ProgramGenerator on \(today.formatted(date: .abbreviated, time: .omitted))"
        )
        context.insert(mesoBlock)

        var createdSessions = 0

        for weekIndex in 0..<totalWeeksCount {
            let isDeload = includeDeloadWeek && (weekIndex == totalWeeksCount - 1)

            for dayIndex in 0..<trainingDays {
                let globalIndex = (weekIndex * trainingDays) + dayIndex
                guard globalIndex < sessionDates.count else { continue }

                let date = sessionDates[globalIndex]

                let dayPlan = DefaultCatalogProgramTemplate.dayPlan(for: globalIndex)
                let prescription = DefaultCatalogProgramTemplate.prescription(
                    goal: goal,
                    isDeload: isDeload
                )

                print("DEBUG ProgramGenerator.seedInitialProgram – week=\(weekIndex + 1) day=\(dayIndex + 1) plan=\(dayPlan.title)")
                
                let session = Session(
                    date: date,
                    status: .planned,
                    readinessStars: 0,
                    weekIndex: weekIndex + 1,
                    items: []
                )

                session.meso = mesoBlock
                session.programIndex = dayIndex + 1

                for (idx, ex) in dayPlan.exercises.enumerated() {
                    let order = idx + 1

                    let item = SessionItem(
                        order: order,
                        exerciseId: ex.id,
                        exerciseNameSnapshot: ex.name,
                        targetReps: prescription.targetReps,
                        targetSets: prescription.targetSets,
                        targetRIR: prescription.targetRIR,
                        suggestedLoad: 0.0,
                        plannedRepsBySet: prescription.plannedRepsBySet,
                        plannedLoadsBySet: prescription.plannedLoadsBySet,
                        plannedRIRsBySet: prescription.plannedRIRsBySet
                    )

                    session.items.append(item)
                }

                context.insert(session)
                createdSessions += 1
            }
        }

        do {
            try context.save()
            print("DEBUG ProgramGenerator.seedInitialProgram – created sessions: \(createdSessions)")
            print("DEBUG ProgramGenerator.seedInitialProgram – created meso block: \(mesoName)")

            let fetch = FetchDescriptor<Session>()
            if let sessions = try? context.fetch(fetch) {
                print("DEBUG ProgramGenerator.seedInitialProgram – sessions after save: \(sessions.count)")
            } else {
                print("DEBUG ProgramGenerator.seedInitialProgram – fetch after save failed")
            }
        } catch {
            print("ERROR ProgramGenerator.seedInitialProgram – context.save() failed: \(error)")
        }
    }
}
