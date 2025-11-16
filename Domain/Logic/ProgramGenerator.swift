import Foundation
import SwiftData

/// Generates an initial block of sessions for a new user.
///
/// v1.1:
/// - Push / Pull / Legs style rotation
/// - Supports custom `daysPerWeek`
/// - Supports custom block length (1–8 weeks)
/// - Automatically adds a reload week at the end (weekIndex = workWeeks + 1)
struct ProgramGenerator {

    static func seedInitialProgram(
        goal: Goal? = nil,
        daysPerWeek: Int,
        blockLengthWeeks: Int = 4,
        context: ModelContext
    ) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Clamp inputs to safe ranges.
        let days = max(daysPerWeek, 1)
        let workWeeks = max(min(blockLengthWeeks, 8), 1)
        let reloadWeekIndex = workWeeks + 1

        func exercises(for focusIndex: Int) -> [CatalogExercise] {
            switch focusIndex {
            case 0:
                // PUSH DAY
                return [
                    ExerciseCatalog.benchPress,
                    ExerciseCatalog.inclineDumbbellPress,
                    ExerciseCatalog.seatedCableFly,
                    ExerciseCatalog.cableTricepRopePushdown,
                    ExerciseCatalog.dumbbellLateralRaise
                ]
            case 1:
                // PULL DAY
                return [
                    ExerciseCatalog.wideGripPulldown,
                    ExerciseCatalog.dumbbellRowSingleArm,
                    ExerciseCatalog.seatedCableRow,
                    ExerciseCatalog.inclineRearDeltFly,
                    ExerciseCatalog.ezBarCurl,
                    ExerciseCatalog.hammerCurl
                ]
            default:
                // LEGS DAY
                return [
                    ExerciseCatalog.hackSquat,
                    ExerciseCatalog.legExtension,
                    ExerciseCatalog.romanianDeadlift,
                    ExerciseCatalog.lyingLegCurl,
                    ExerciseCatalog.machineHipThrust,
                    ExerciseCatalog.cableGluteKickback,
                    ExerciseCatalog.smithMachineCalves,
                    ExerciseCatalog.cableRopeCrunch
                ]
            }
        }

        // MARK: Training weeks (1...workWeeks)

        for week in 1...workWeeks {
            for dayIndex in 0..<days {
                // Date = today + (weekOffset * 7) + dayOffset
                let offsetDays = (week - 1) * 7 + dayIndex
                let date = calendar.date(byAdding: .day, value: offsetDays, to: today) ?? today

                let focusIndex = dayIndex % 3
                let exercisesForDay = exercises(for: focusIndex)

                let session = Session(
                    date: date,
                    status: .planned,
                    readinessStars: 0,
                    weekIndex: week,
                    items: []
                )

                // Simple default prescription: 3x10 @ RIR 2
                for (idx, ex) in exercisesForDay.enumerated() {
                    let order = idx + 1

                    let targetSets = 3
                    let targetReps = 10
                    let targetRIR = 2
                    let plannedReps = Array(repeating: targetReps, count: targetSets)

                    let item = SessionItem(
                        order: order,
                        exerciseId: ex.id,
                        targetReps: targetReps,
                        targetSets: targetSets,
                        targetRIR: targetRIR,
                        suggestedLoad: 0.0,
                        plannedRepsBySet: plannedReps
                    )

                    session.items.append(item)
                }

                context.insert(session)
            }
        }

        // MARK: Reload week (weekIndex = workWeeks + 1)

        for dayIndex in 0..<days {
            let offsetDays = (reloadWeekIndex - 1) * 7 + dayIndex
            let date = calendar.date(byAdding: .day, value: offsetDays, to: today) ?? today

            let focusIndex = dayIndex % 3
            let exercisesForDay = exercises(for: focusIndex)

            let session = Session(
                date: date,
                status: .planned,
                readinessStars: 0,
                weekIndex: reloadWeekIndex,
                items: []
            )

            // Slightly lighter prescription for reload:
            // fewer sets, higher RIR.
            for (idx, ex) in exercisesForDay.enumerated() {
                let order = idx + 1

                let targetSets = 2       // down from 3
                let targetReps = 10
                let targetRIR = 3        // a bit easier
                let plannedReps = Array(repeating: targetReps, count: targetSets)

                let item = SessionItem(
                    order: order,
                    exerciseId: ex.id,
                    targetReps: targetReps,
                    targetSets: targetSets,
                    targetRIR: targetRIR,
                    suggestedLoad: 0.0,
                    plannedRepsBySet: plannedReps
                )

                session.items.append(item)
            }

            context.insert(session)
        }

        // Persist all created sessions
        try? context.save()
    }
}
