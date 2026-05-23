// Domain/Programs/MaintenanceProgramSeeder.swift
import Foundation
import SwiftData

enum MaintenanceProgramSeeder {

    /// Seeds a maintenance block derived from the structure of a completed meso.
    ///
    /// - Same 6-day split and exercise order as the source meso.
    /// - Deload wave prescription applied to every session (2 sets, RIR 3-4, no intensifiers).
    /// - Loads anchored from previous meso peak via ProgramGenerator.anchorLoadsForNewMeso().
    /// - Duration: `totalWeeks` (default 4), no appended deload week.
    static func seed(
        from sourceMeso: MesoBlock,
        trainingWeekdays: [Int],
        totalWeeks: Int = 4,
        startDate: Date = Date(),
        context: ModelContext,
        calendar: Calendar = .current
    ) throws {
        let startDay = calendar.startOfDay(for: startDate)

        // 1) Archive active mesos
        let mesoDescriptor = FetchDescriptor<MesoBlock>()
        let existingBlocks = try context.fetch(mesoDescriptor)
        for block in existingBlocks where block.status == .active {
            block.status = .archived
        }

        // 2) Delete non-completed sessions on or after startDate
        let sessionDescriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )
        let allSessions = try context.fetch(sessionDescriptor)
        let sessionsToDelete = allSessions.filter { session in
            let sessionDay = calendar.startOfDay(for: session.date)
            return sessionDay >= startDay && session.status != .completed
        }
        for session in sessionsToDelete {
            context.delete(session)
        }
        try context.save()

        // 3) Build day structure from source meso
        // Group completed+planned sessions by dayLabel to recover the exercise roster per day
        let sourceSessions = sourceMeso.sessions.sorted { $0.date < $1.date }

        // Collect unique day slots in order (by programIndex / dayLabel)
        var seenDayLabels: [String] = []
        var seenSet = Set<String>()
        for session in sourceSessions {
            let label = session.dayLabel ?? "Day \(session.programIndex)"
            if !seenSet.contains(label) {
                seenSet.insert(label)
                seenDayLabels.append(label)
            }
        }

        let daysPerWeek = seenDayLabels.count
        guard daysPerWeek > 0 else {
            print("MaintenanceProgramSeeder: source meso has no sessions, aborting.")
            return
        }

        // Build exercise roster per day label — use the most recent session for that label
        // so we get the latest exercise swap state
        var dayRosters: [String: [(exerciseId: String, name: String?, order: Int)]] = [:]
        for label in seenDayLabels {
            let matchingSessions = sourceSessions.filter {
                ($0.dayLabel ?? "Day \($0.programIndex)") == label
            }
            // Most recent session for this day label
            if let latest = matchingSessions.last {
                let roster = latest.items
                    .sorted { $0.order < $1.order }
                    .map { (exerciseId: $0.exerciseId, name: $0.exerciseNameSnapshot, order: $0.order) }
                dayRosters[label] = roster
            }
        }

        // 4) Build normalized weekdays
        let normalizedWeekdays = Array(Set(trainingWeekdays)).sorted()
        let effectiveWeekdays = normalizedWeekdays.isEmpty
            ? defaultWeekdays(for: daysPerWeek)
            : normalizedWeekdays

        // 5) Build session dates
        let totalSessions = daysPerWeek * totalWeeks
        let sessionDates = buildSessionDates(
            calendar: calendar,
            today: startDay,
            weekdays: effectiveWeekdays,
            totalSessions: totalSessions
        )

        // 6) Create meso block
        let mesoBlock = MesoBlock(
            name: "Maintenance Block",
            startDate: startDay,
            status: .active,
            notes: "Seeded from \(sourceMeso.name) on \(startDay.formatted(date: .abbreviated, time: .omitted))",
            totalWeeks: totalWeeks
        )
        context.insert(mesoBlock)

        // 7) Seed sessions using deload wave prescription for every week
        var createdCount = 0
        for weekIndex in 0..<totalWeeks {
            for (dayIndex, dayLabel) in seenDayLabels.enumerated() {
                let globalIndex = weekIndex * daysPerWeek + dayIndex
                guard globalIndex < sessionDates.count else { continue }

                let date = sessionDates[globalIndex]
                let roster = dayRosters[dayLabel] ?? []

                let items: [SessionItem] = roster.map { exercise in
                    // Maintenance prescription: 2 sets, rep range from deload wave,
                    // RIR 3-4, no intensifier
                    SessionItem(
                        order: exercise.order,
                        exerciseId: exercise.exerciseId,
                        exerciseNameSnapshot: exercise.name,
                        targetReps: 10,
                        targetSets: 2,
                        targetRIR: 3,
                        suggestedLoad: 0.0,
                        waveRaw: WaveType.deload.rawValue,
                        priorityRaw: ExercisePriority.standard.rawValue,
                        setMin: 2,
                        setMax: 3,
                        repMin: 8,
                        repMax: 12,
                        targetRIRMin: 3,
                        targetRIRMax: 4,
                        intensifierRaw: IntensifierType.none.rawValue,
                        intensifierNotes: nil,
                        prescriptionNotes: "Maintenance — hold loads, manage fatigue.",
                        plannedRepsBySet: [10, 10],
                        plannedLoadsBySet: [0.0, 0.0],
                        plannedRIRsBySet: [3, 3]
                    )
                }

                let session = Session(
                    date: date,
                    status: .planned,
                    readinessStars: 0,
                    sessionNotes: "\(dayLabel) · Maintenance",
                    weekIndex: weekIndex + 1,
                    dayLabel: dayLabel,
                    items: items
                )
                session.meso = mesoBlock
                session.programIndex = dayIndex + 1
                context.insert(session)
                createdCount += 1
            }
        }

        try context.save()


        // 8) Anchor loads from previous meso peak
        ProgramGenerator.anchorLoadsForNewMeso(mesoBlock: mesoBlock, context: context)
    }

    // MARK: - Helpers (mirrors ProgramGenerator private helpers)

    private static func defaultWeekdays(for days: Int) -> [Int] {
        switch days {
        case 2:  return [2, 5]
        case 3:  return [2, 4, 6]
        case 4:  return [2, 3, 5, 6]
        case 5:  return [2, 3, 4, 5, 6]
        case 6:  return [2, 3, 4, 5, 6, 7]
        default: return [2, 4, 6]
        }
    }

    private static func buildSessionDates(
        calendar: Calendar,
        today: Date,
        weekdays: [Int],
        totalSessions: Int
    ) -> [Date] {
        var dates: [Date] = []
        var current = today
        for i in 0..<totalSessions {
            let start = i == 0 ? current : (calendar.date(byAdding: .day, value: 1, to: current) ?? current)
            var candidate = start
            while true {
                let weekday = calendar.component(.weekday, from: candidate)
                if weekdays.contains(weekday) { break }
                candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            }
            dates.append(candidate)
            current = candidate
        }
        return dates
    }
}
