import Foundation
import SwiftData

/// Handles reading/writing PR data from SwiftData.
///
/// A PR is the best working-set e1RM of a canonical exercise (the single definition in `PersonalRecords`, sets of 12 reps
/// or fewer only): Epley on the
/// effective load, warm-ups / rest-pause / drop / skipped rows excluded, every completed session counted (maintenance and
/// deload included). A bodyweight lift uses the lifter's body weight; without one it has no PR. `PRIndex` stores the
/// best set (load = effective load, reps); its e1RM is derived, and `bestSetVolume` is kept as load x reps.
struct PRService {

    /// Best working set logged on `item` by e1RM, or nil when nothing meaningful was done (or a bodyweight lift has no
    /// body weight to measure against). `load` is the effective load.
    static func bestSet(in item: SessionItem, bodyWeight: Double? = nil) -> (e1RM: Double, load: Double, reps: Int)? {
        let isBodyweight = ExerciseCatalog.isBodyweight(exerciseId: item.exerciseId)
        var best: (e1RM: Double, load: Double, reps: Int)?
        for row in WorkingSetFilter.workingRows(of: item, isBodyweight: isBodyweight) {
            let load = E1RMCalculator.effectiveLoad(actualLoad: row.load, exerciseId: item.exerciseId, bodyWeight: bodyWeight)
            let e1rm = BestSetRule.e1RM(load: load, reps: row.reps)      // sets of 12 reps or fewer only
            if e1rm > (best?.e1RM ?? 0) { best = (e1rm, load, row.reps) }
        }
        return best
    }

    /// The REPLACED definition (best single-set load x reps over every logged row), kept only so a report can show what the
    /// switch changed. Nothing in the app reads it.
    static func legacyBestVolumeSet(in item: SessionItem) -> (volume: Double, load: Double, reps: Int)? {
        var best: (volume: Double, load: Double, reps: Int)?
        for i in 0..<min(item.actualReps.count, item.actualLoads.count) where item.actualReps[i] > 0 && item.actualLoads[i] > 0 {
            let v = Double(item.actualReps[i]) * item.actualLoads[i]
            if v > (best?.volume ?? 0) { best = (v, item.actualLoads[i], item.actualReps[i]) }
        }
        return best
    }

    /// Update the PR index based on a single SessionItem's newly saved logs: a strictly higher e1RM is a new PR.
    static func updatePR(for item: SessionItem, in context: ModelContext) {
        let bodyWeight = (try? context.fetch(FetchDescriptor<UserProfile>()).first)?.bodyWeight
        guard let best = bestSet(in: item, bodyWeight: bodyWeight) else {
            item.isPR = false
            return
        }
        let canonical = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
        do {
            let existing = try context.fetch(FetchDescriptor<PRIndex>())
                .first { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical }
            if let existing {
                if best.e1RM > BestSetRule.e1RM(load: existing.bestLoad, reps: existing.bestReps) {
                    existing.exerciseId = canonical
                    existing.bestSetVolume = best.load * Double(best.reps)
                    existing.bestLoad = best.load
                    existing.bestReps = best.reps
                    existing.bestDate = Date()
                    item.isPR = true
                } else {
                    item.isPR = false
                }
            } else {
                let name = ExerciseCatalog.all.first(where: { $0.id == canonical })?.name ?? item.exerciseNameSnapshot ?? "Unknown"
                context.insert(PRIndex(exerciseId: canonical, exerciseName: name, bestSetVolume: best.load * Double(best.reps),
                                       bestLoad: best.load, bestReps: best.reps, bestDate: Date()))
                item.isPR = true
            }
        } catch {
            // If the fetch fails for some reason, don't crash the app.
            item.isPR = false
        }
    }

    /// Convenience getter if we want to display current PR elsewhere.
    static func currentPR(for exerciseId: String, in context: ModelContext) -> PRIndex? {
        let canonical = ExerciseCatalog.canonicalExerciseId(for: exerciseId)
        return (try? context.fetch(FetchDescriptor<PRIndex>()))?.first { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical }
    }
}
