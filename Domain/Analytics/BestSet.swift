// Domain/Analytics/BestSet.swift
import Foundation

/// A lift's best set, shown as load × reps.
struct BestSet: Equatable {
    /// Effective load, stored lb.
    let load: Double
    let reps: Int
    /// Epley e1RM of the set; nil when the set was chosen by the fallback (no set of 12 reps or fewer).
    let e1RM: Double?
    var isFallback: Bool { e1RM == nil }
}

/// Where e1RM may be used: only sets of 12 reps or fewer. Beyond that Epley stops describing strength (a 20-rep set
/// "predicts" a 1RM nobody has lifted), so such a set is not ranked by e1RM; if a lift has no set of 12 or fewer, its best
/// set is its heaviest load (more reps on a tie) and its trend is the best load at matched reps.
enum BestSetRule {
    static let maxRepsForE1RM = 12

    static func isE1RMEligible(reps: Int) -> Bool { reps >= 1 && reps <= maxRepsForE1RM }

    /// THE e1RM for anything a lifter reads as a strength number: records and PR badges, the exercise history sheet, the live
    /// recap and the Meso Summary rows all use it (best working set, warm-ups out, sets of 12 reps or fewer, 0 for a longer set).
    ///
    /// The one deliberate exception is `SetRecord.e1RM` (raw Epley on any rep count), used by stall detection, fatigue and the
    /// meso comparison. Those compare a lift with ITSELF at similar reps (this session's sets against the same lift's earlier
    /// sets on the same wave letter), so Epley's loss of accuracy at high reps cancels out; dropping the long sets there would
    /// instead leave high-rep lifts with no series to compare. Do not use `SetRecord.e1RM` to rank or display a strength number.
    static func e1RM(load: Double, reps: Int) -> Double {
        isE1RMEligible(reps: reps) ? E1RMCalculator.e1RM(load: load, reps: reps) : 0
    }

    /// The best of `sets` ((effective load, reps) of working sets), or nil when there is none.
    static func best(of sets: [(load: Double, reps: Int)]) -> BestSet? {
        let valid = sets.filter { $0.load > 0 && $0.reps > 0 }
        let eligible = valid.filter { isE1RMEligible(reps: $0.reps) }
        if let top = eligible.max(by: { (E1RMCalculator.e1RM(load: $0.load, reps: $0.reps), $0.load) < (E1RMCalculator.e1RM(load: $1.load, reps: $1.reps), $1.load) }) {
            return BestSet(load: top.load, reps: top.reps, e1RM: E1RMCalculator.e1RM(load: top.load, reps: top.reps))
        }
        if let top = valid.max(by: { ($0.load, $0.reps) < ($1.load, $1.reps) }) {
            return BestSet(load: top.load, reps: top.reps, e1RM: nil)
        }
        return nil
    }

    /// The best working set of one item (effective load: a bodyweight lift counts at the lifter's body weight).
    static func best(of item: SessionItem, bodyWeight: Double?, customExercises: [CustomExercise] = []) -> BestSet? {
        let isBodyweight = ExerciseCatalog.isBodyweight(exerciseId: item.exerciseId, customExercises: customExercises)
        let rows: [(load: Double, reps: Int)] = WorkingSetFilter.workingRows(of: item, isBodyweight: isBodyweight).map { row in
            let load = row.load > 0 ? row.load : (isBodyweight ? (bodyWeight ?? 0) : 0)
            return (load, row.reps)
        }
        return best(of: rows)
    }

    /// Best load at matched reps: the heaviest load that was lifted for at least `reps` reps (0 when none was).
    static func bestLoad(atLeast reps: Int, in sets: [(load: Double, reps: Int)]) -> Double {
        sets.filter { $0.reps >= reps && $0.load > 0 }.map(\.load).max() ?? 0
    }
}
