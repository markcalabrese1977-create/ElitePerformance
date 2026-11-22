import Foundation

/// The one deload rule. Insert deload week, the scheduled-deload branch of `PlanMemoryEngine`, and the
/// future "Start with a deload week" all read it, so a deload week is the same week wherever it came from.
///
/// - Sets: half the planned sets, at least one.
/// - RIR 4. Planned reps = `repMin` (the load is sized for the reps that are planned, so the plan and the load agree).
/// - Load = min(RIR-4 sizing at `repMin`, 0.95 x the lift's latest non-deload working load), rounded down to the
///   lift's step. A deload is never heavier than 95% of what the lifter last trained with, whichever way the
///   e1RM estimate points.
/// - Bodyweight lifts carry no load; fixed-load (progression-exempt) lifts hold their last lifted load.
enum DeloadRule {

    static let rir = 4
    /// The cap: a share of the latest non-deload working load.
    static let workingLoadShare = 0.95

    /// Half the planned sets (rounded up), at least one.
    static func sets(forPlanned planned: Int) -> Int { max(1, (planned + 1) / 2) }

    /// Which side of the min a load landed on (or why there was no min).
    enum Basis: String, Equatable {
        /// RIR-4 sizing at repMin was the lower of the two (or equal).
        case rir
        /// The 0.95 x working-load cap was lower.
        case cap
        case bodyweight
        /// Fixed-load lift: holds its last lifted load.
        case exempt
        /// No usable logged working set: no load to write.
        case noHistory
    }

    struct Sizing: Equatable {
        let load: Double
        let basis: Basis
        /// The lift's latest non-deload working load (nil when none).
        let workingLoad: Double?
        /// RIR-4 sizing at repMin (nil when there is no history).
        let rirLoad: Double?
        /// 0.95 x workingLoad rounded down to the step (nil when there is no working load).
        let capLoad: Double?
    }

    /// The most recent completed, non-deload, non-inserted-deload session's heaviest working (back-off) set of
    /// `exerciseId`: the load the lifter last trained with. Nil when there is none.
    static func latestWorkingLoad(for exerciseId: String, in sessions: [Session]) -> Double? {
        let canonical = ExerciseCatalog.canonicalExerciseId(for: exerciseId)
        for s in sessions.filter({ $0.status == .completed && $0.insertedDeload != true }).sorted(by: { $0.date > $1.date }) {
            guard let item = s.items.first(where: { ExerciseCatalog.canonicalExerciseId(for: $0.exerciseId) == canonical }) else { continue }
            if item.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() == "deload" { continue }
            let rows = WorkingSetFilter.droppingWarmups(WorkingSetFilter.qualifyingRows(of: item, role: .backOff))
            if let heaviest = rows.map(\.load).max(), heaviest > 0 { return heaviest }
        }
        return nil
    }

    static func sizing(
        exerciseId: String,
        repMin: Int,
        in sessions: [Session],
        profile: UserProfile?,
        unit: LoadUnit,
        customExercises: [CustomExercise],
        referenceDate: Date
    ) -> Sizing {
        if ExerciseCatalog.isBodyweight(exerciseId: exerciseId, customExercises: customExercises) {
            return Sizing(load: 0, basis: .bodyweight, workingLoad: nil, rirLoad: nil, capLoad: nil)
        }
        let step = UserProfile.loadStep(for: exerciseId, profile: profile, unit: unit)
        if UserProfile.isProgressionExempt(exerciseId: exerciseId, profile: profile) {
            let last = SessionItemEditService.lastCompletedLoad(for: exerciseId, in: sessions)
            return Sizing(load: last ?? 0, basis: last == nil ? .noHistory : .exempt, workingLoad: last, rirLoad: nil, capLoad: nil)
        }
        guard let rirLoad = HistorySeedLoad.load(
            for: exerciseId, goalReps: repMin, targetRIR: rir, in: sessions,
            loadIncrement: step, unit: unit, bodyWeight: profile?.bodyWeight, customExercises: customExercises,
            referenceDate: referenceDate
        ), rirLoad > 0 else {
            return Sizing(load: 0, basis: .noHistory, workingLoad: latestWorkingLoad(for: exerciseId, in: sessions), rirLoad: nil, capLoad: nil)
        }
        guard let working = latestWorkingLoad(for: exerciseId, in: sessions) else {
            let load = UserProfile.clampedLoad(rirLoad, exerciseId: exerciseId, profile: profile, customExercises: customExercises)
            return Sizing(load: load, basis: .rir, workingLoad: nil, rirLoad: rirLoad, capLoad: nil)
        }
        let cap = UnitAwareRounding.round(working * workingLoadShare, increment: step, unit: unit, mode: .down)
        let chosen = min(rirLoad, cap)
        let load = UserProfile.clampedLoad(chosen, exerciseId: exerciseId, profile: profile, customExercises: customExercises)
        return Sizing(load: load, basis: cap < rirLoad ? .cap : .rir, workingLoad: working, rirLoad: rirLoad, capLoad: cap)
    }

    /// Context-free convenience for callers that already hold the profile and lists.
    static func load(exerciseId: String, repMin: Int, in sessions: [Session], profile: UserProfile?, unit: LoadUnit,
                     customExercises: [CustomExercise], referenceDate: Date) -> Double {
        sizing(exerciseId: exerciseId, repMin: repMin, in: sessions, profile: profile, unit: unit,
               customExercises: customExercises, referenceDate: referenceDate).load
    }
}
