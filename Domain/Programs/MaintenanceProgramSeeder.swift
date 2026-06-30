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
            totalWeeks: totalWeeks,
            isMaintenance: true
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

                let items: [SessionItem] = applyMaintenancePrescription(to: roster)

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

    // MARK: - Path B: Seed Maintenance Block From a New Program Template

    /// Seeds a maintenance block using a freshly chosen ProgramTemplate's day
    /// structure, rather than cloning the prior meso. Applies the same
    /// maintenance prescription as Path A (deload wave, 2 sets, RIR 3-4) to
    /// every exercise in the template's rosters.
    ///
    /// Load anchoring: searches the user's FULL session history (not just the
    /// prior meso) per exercise for the most recent/best e1RM. Falls back to 0
    /// (Auto+ seeds normally) if no history exists for that exercise — this is
    /// expected for exercises that don't overlap with the user's prior split.
    static func seedFromNewProgram(
        template: ProgramTemplate,
        totalWeeks: Int,
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

        // 3) Materialize each day-slot once (week 1) purely to get the
        // exercise roster + title — maintenance uses the same prescription
        // every week, so we don't need per-week wave resolution.
        let daysPerWeek = template.trainingDaysPerWeek
        var dayRosters: [(dayNumber: Int, title: String, roster: [(exerciseId: String, name: String?, order: Int)])] = []

        for dayNumber in 1...daysPerWeek {
            guard let materialized = try? DUPSessionMaterializer.materializeDay(
                template: template,
                weekNumber: 1,
                dayNumber: dayNumber
            ) else { continue }

            let roster = materialized.exercises.map {
                (exerciseId: $0.exerciseId, name: ExerciseCatalog.displayName(for: $0.exerciseId), order: $0.order)
            }
            dayRosters.append((dayNumber: dayNumber, title: materialized.title, roster: roster))
        }

        guard !dayRosters.isEmpty else {
            print("MaintenanceProgramSeeder.seedFromNewProgram: template produced no day rosters, aborting.")
            return
        }

        // 4) Build session dates using the template's natural weekday pattern.
        let effectiveWeekdays = defaultWeekdays(for: daysPerWeek)
        let totalSessions = daysPerWeek * totalWeeks
        let sessionDates = buildSessionDates(
            calendar: calendar,
            today: startDay,
            weekdays: effectiveWeekdays,
            totalSessions: totalSessions
        )

        // 5) Create meso block
        let mesoBlock = MesoBlock(
            name: "Maintenance Block",
            startDate: startDay,
            status: .active,
            notes: "Seeded from \(template.name) on \(startDay.formatted(date: .abbreviated, time: .omitted))",
            totalWeeks: totalWeeks,
            isMaintenance: true
        )
        context.insert(mesoBlock)

        // 6) Seed sessions — same maintenance prescription every week
        var createdCount = 0
        for weekIndex in 0..<totalWeeks {
            for (slotIndex, day) in dayRosters.enumerated() {
                let globalIndex = weekIndex * daysPerWeek + slotIndex
                guard globalIndex < sessionDates.count else { continue }

                let date = sessionDates[globalIndex]
                let items = applyMaintenancePrescription(to: day.roster)

                let session = Session(
                    date: date,
                    status: .planned,
                    readinessStars: 0,
                    sessionNotes: "\(day.title) · Maintenance",
                    weekIndex: weekIndex + 1,
                    dayLabel: day.title,
                    items: items
                )
                session.meso = mesoBlock
                session.programIndex = day.dayNumber
                context.insert(session)
                createdCount += 1
            }
        }

        try context.save()

        // 7) Anchor loads from FULL session history (not just prior meso),
        // per exercise. Falls back to 0 if no history exists for that exercise.
        anchorLoadsFromFullHistory(mesoBlock: mesoBlock, context: context)
    }

    /// Searches the user's entire session history (across all mesos) for the
    /// best/most-recent e1RM per exercise, anchoring each maintenance item's
    /// suggestedLoad accordingly. Exercises with no prior history start at 0,
    /// same as normal first-session behavior (Auto+ seeds from there).
    private static func anchorLoadsFromFullHistory(mesoBlock: MesoBlock, context: ModelContext) {
        let allSessionsDescriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )
        guard let allSessions = try? context.fetch(allSessionsDescriptor) else { return }

        let mesoSessionIDs = Set(mesoBlock.sessions.map { $0.persistentModelID })
        // Excludes maintenance-block sessions from the anchoring pool — see
        // ProgramGenerator.anchorLoadsForNewMeso's identical comment.
        let historicalSessions = allSessions.filter {
            !mesoSessionIDs.contains($0.persistentModelID) && $0.meso?.isMaintenance != true
        }

        for session in mesoBlock.sessions {
            for item in session.items {
                let canonicalId = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)

                let candidates = historicalSessions.compactMap { s -> (e1rm: Double, date: Date)? in
                    guard let match = s.items.first(where: {
                        ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonicalId
                    }) else { return nil }

                    let setCount = min(match.actualLoads.count, match.actualReps.count)
                    guard setCount > 0 else { return nil }

                    var bestE1RM = 0.0
                    for idx in 0..<setCount {
                        let load = match.actualLoads[idx]
                        let reps = match.actualReps[idx]
                        guard load > 0, reps > 0 else { continue }
                        let e1rm = E1RMCalculator.e1RM(load: load, reps: reps)
                        bestE1RM = max(bestE1RM, e1rm)
                    }
                    guard bestE1RM > 0 else { return nil }
                    return (e1rm: bestE1RM, date: s.date)
                }

                guard !candidates.isEmpty else { continue }

                let decayWeighted = E1RMCalculator.decayWeightedE1RM(
                    from: candidates.map { ($0.e1rm, $0.date) }
                )
                guard decayWeighted > 0 else { continue }

                // Maintenance targets RIR 3-4 — back-calculate at the deload
                // prescription's target reps/RIR for this exercise.
                let load = E1RMCalculator.load(for: decayWeighted, reps: item.targetReps, targetRIR: item.targetRIR)
                let rounded = E1RMCalculator.rounded(load, increment: 2.5)
                guard rounded > 0 else { continue }

                item.suggestedLoad = rounded
                let setCount = max(0, item.targetSets)
                item.plannedLoadsBySet = Array(repeating: rounded, count: setCount)
            }
        }

        try? context.save()
    }

    // MARK: - Diagnostic: Audit Existing Maintenance Block for Mis-Prescribed Items

    /// One-time, READ-ONLY diagnostic. Walks the currently active maintenance
    /// meso's sessions and reports any SessionItem whose waveRaw isn't
    /// "deload" — these are exercises added via addExercise() BEFORE today's
    /// fix, which silently fell through to normal progression coaching
    /// instead of the maintenance retention message. Makes no changes.
    /// One-time repair: patches waveRaw = "deload" on mismatched items found
    /// by auditCurrentMaintenanceBlock. Does NOT touch targetSets, targetReps,
    /// targetRIR, suggestedLoad, or plannedLoadsBySet — those reflect the
    /// user's deliberate customization via the Program tab and must be
    /// preserved exactly. Only fixes the coaching-recognition signal.
    static func repairCurrentMaintenanceBlock(context: ModelContext) {
        let mesoDescriptor = FetchDescriptor<MesoBlock>()
        guard let blocks = try? context.fetch(mesoDescriptor) else {
            print("⚠️ Repair: could not fetch meso blocks")
            return
        }

        guard let maintenanceMeso = blocks.first(where: {
            $0.status == .active && $0.name.lowercased().contains("maintenance")
        }) else {
            print("ℹ️ Repair: no active maintenance meso found")
            return
        }

        var repairedCount = 0

        for session in maintenanceMeso.sessions {
            for item in session.items {
                let isDeload = item.waveRaw?.lowercased() == "deload"
                guard !isDeload else { continue }

                item.waveRaw = WaveType.deload.rawValue
                if item.prescriptionNotes == nil || item.prescriptionNotes?.isEmpty == true {
                    item.prescriptionNotes = "Maintenance — hold loads, manage fatigue."
                }
                repairedCount += 1
            }
        }

        try? context.save()
        print("✅ REPAIR COMPLETE — patched waveRaw on \\(repairedCount) item(s). targetSets/targetReps/targetRIR/loads untouched.")
    }

    static func auditCurrentMaintenanceBlock(context: ModelContext) {
        let mesoDescriptor = FetchDescriptor<MesoBlock>()
        guard let blocks = try? context.fetch(mesoDescriptor) else {
            print("⚠️ Audit: could not fetch meso blocks")
            return
        }

        guard let maintenanceMeso = blocks.first(where: {
            $0.status == .active && $0.name.lowercased().contains("maintenance")
        }) else {
            print("ℹ️ Audit: no active maintenance meso found")
            return
        }

        print("🔍 AUDIT — Maintenance Block: \(maintenanceMeso.name)")
        print("   Total sessions: \(maintenanceMeso.sessions.count)")

        var mismatchCount = 0
        var checkedCount = 0

        let sortedSessions = maintenanceMeso.sessions.sorted { $0.date < $1.date }

        for session in sortedSessions {
            for item in session.items {
                checkedCount += 1
                let isDeload = item.waveRaw?.lowercased() == "deload"
                if !isDeload {
                    mismatchCount += 1
                    let name = item.exerciseNameSnapshot ?? ExerciseCatalog.displayName(for: item.exerciseId)
                    print("   ❌ MISMATCH — \(name) | session date: \(session.date.formatted(date: .abbreviated, time: .omitted)) | dayLabel: \(session.dayLabel ?? "nil") | waveRaw: \(item.waveRaw ?? "nil")")
                }
            }
        }

        print("🔍 AUDIT COMPLETE — checked \(checkedCount) items, found \(mismatchCount) mismatched item(s) across \(sortedSessions.count) sessions")
    }

    // MARK: - Reusable Maintenance Prescription

    /// Builds a single maintenance-style SessionItem for one exercise.
    /// Shared by both Path A (continue current split) and Path B (choose new
    /// program) so both paths apply identical retention-focused prescription:
    /// 2 sets, RIR 3-4, deload wave — regardless of where the roster came from.
    static func makeMaintenanceItem(exerciseId: String, name: String?, order: Int) -> SessionItem {
        SessionItem(
            order: order,
            exerciseId: exerciseId,
            exerciseNameSnapshot: name,
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

    /// Applies the maintenance prescription across an entire day's roster.
    /// Roster can come from a prior meso's sessions (Path A) or a freshly
    /// chosen ProgramTemplate's day (Path B) — this function doesn't care
    /// about the source, only the (exerciseId, name, order) shape.
    static func applyMaintenancePrescription(
        to roster: [(exerciseId: String, name: String?, order: Int)]
    ) -> [SessionItem] {
        roster.map { makeMaintenanceItem(exerciseId: $0.exerciseId, name: $0.name, order: $0.order) }
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
