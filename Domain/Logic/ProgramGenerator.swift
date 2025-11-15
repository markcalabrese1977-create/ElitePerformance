import Foundation
import SwiftData

/// Generates an initial block of sessions for a new user.
/// This is intentionally simple: a Push / Pull / Legs style rotation
/// using the current Catalog exercises, so you can test the app
/// with your real meso movements.
struct ProgramGenerator {

    static func seedInitialProgram(
        goal: Goal,
        daysPerWeek: Int,
        context: ModelContext
    ) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Make sure we have at least 1 day to work with
        let days = max(daysPerWeek, 1)

        for dayIndex in 0..<days {
            let date = calendar.date(byAdding: .day, value: dayIndex, to: today) ?? today

            // Simple PPL rotation: 0 = Push, 1 = Pull, 2 = Legs, repeat
            let focusIndex = dayIndex % 3
            let exercisesForDay: [CatalogExercise]

            switch focusIndex {
            case 0:
                // PUSH DAY
                exercisesForDay = [
                    ExerciseCatalog.benchPress,
                    ExerciseCatalog.inclineDumbbellPress,
                    ExerciseCatalog.seatedCableFly,
                    ExerciseCatalog.cableTricepRopePushdown,
                    ExerciseCatalog.dumbbellLateralRaise
                ]
            case 1:
                // PULL DAY
                exercisesForDay = [
                    ExerciseCatalog.wideGripPulldown,
                    ExerciseCatalog.dumbbellRowSingleArm,
                    ExerciseCatalog.seatedCableRow,
                    ExerciseCatalog.inclineRearDeltFly,
                    ExerciseCatalog.ezBarCurl,
                    ExerciseCatalog.hammerCurl
                ]
            default:
                // LEGS DAY
                exercisesForDay = [
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

            // Create a Session for this day
            let session = Session(
                date: date,
                status: .planned,
                readinessStars: 0,
                items: []
            )

            // Convert catalog exercises into SessionItems
            for (idx, ex) in exercisesForDay.enumerated() {
                let order = idx + 1

                // Simple default prescription: 3x10 @ RIR 2
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

        // Persist all created sessions
        try? context.save()
    }
}
