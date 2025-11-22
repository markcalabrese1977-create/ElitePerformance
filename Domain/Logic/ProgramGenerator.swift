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
        context: ModelContext
    ) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Clamp inputs to sane ranges
        let trainingDays = max(daysPerWeek, 1)
        let hardWeeks = max(1, min(totalWeeks, 8))
        let totalWeeksCount = includeDeloadWeek ? hardWeeks + 1 : hardWeeks

        // Clear any existing planned sessions? For now, we assume a fresh user.
        // If you later support re-programming mid-block, you'll want a more
        // careful strategy here instead of blanket deletion.

        for weekIndex in 0..<totalWeeksCount {
            let isDeload = includeDeloadWeek && (weekIndex == totalWeeksCount - 1)

            for dayIndex in 0..<trainingDays {
                let globalDay = (weekIndex * trainingDays) + dayIndex
                let date = calendar.date(byAdding: .day, value: globalDay, to: today) ?? today

                // Simple PPL rotation across the block
                let focusIndex = globalDay % 3
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

                // Base prescription per exercise
                let baseTargetSets = 3
                let baseTargetReps = 10
                let baseTargetRIR = 2

                // Deload tweak: one fewer set, one more RIR (lighter)
                let targetSets: Int
                let targetReps: Int
                let targetRIR: Int

                if isDeload {
                    targetSets = max(1, baseTargetSets - 1)
                    targetReps = baseTargetReps
                    targetRIR = baseTargetRIR + 1
                } else {
                    targetSets = baseTargetSets
                    targetReps = baseTargetReps
                    targetRIR = baseTargetRIR
                }

                let plannedReps = Array(repeating: targetReps, count: targetSets)
                let plannedLoads = Array(repeating: 0.0, count: targetSets)

                // Create a Session for this day
                let session = Session(
                    date: date,
                    status: .planned,
                    readinessStars: 0,
                    weekIndex: weekIndex + 1,   // store human-friendly week numbers (1-based)
                    items: []
                )

                // Convert catalog exercises into SessionItems
                for (idx, ex) in exercisesForDay.enumerated() {
                    let order = idx + 1

                    let item = SessionItem(
                        order: order,
                        exerciseId: ex.id,
                        targetReps: targetReps,
                        targetSets: targetSets,
                        targetRIR: targetRIR,
                        suggestedLoad: 0.0,
                        plannedRepsBySet: plannedReps,
                        plannedLoadsBySet: plannedLoads
                    )

                    session.items.append(item)
                }

                context.insert(session)
            }
        }

        // Persist all created sessions
        try? context.save()
    }
}
