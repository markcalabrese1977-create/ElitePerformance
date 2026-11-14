import Foundation

/// How a logged RIR is stored and read.
///
/// `SessionItem.actualRIRs` stays a plain `[Int]` (so every backup, DTO and old file keeps round-tripping unchanged), with one
/// reserved value: `RIREntry.unset` (-1) means "the lifter did not record an RIR for this set". It is distinct from 0 (a real
/// "no reps left"). Values 0 and up are exactly what was recorded, including everything an old backup holds.
///
/// Only COMPOUND lifts feed decisions with RIR. An isolation set (or a custom exercise, which has no cluster) is judged on
/// reps against the target alone, so a pre-filled or casually typed number on a curl can never earn or block a bump.
enum RIREntry {
    static let unset = -1

    static func unsetArray(count: Int) -> [Int] { Array(repeating: unset, count: max(0, count)) }

    /// The chips shown for a compound set, one tap each.
    static let chipValues = [0, 1, 2, 3, 4]

    /// A compound lift: a press, row, pull, squat-pattern or overhead press that the progression clusters cover, and that the
    /// catalog marks as a compound movement (the pushdowns and extensions that share a cluster with the presses are not).
    static func isCompound(_ exerciseId: String) -> Bool {
        let id = ExerciseCatalog.canonicalExerciseId(for: exerciseId)
        guard let cluster = ExerciseCatalog.cluster(for: id) else { return false }
        switch cluster {
        case .primaryChestPress, .secondaryPressOrArms, .primaryLeg: break
        case .pumpIsolation, .lowBackStability: return false
        }
        return ExerciseCatalog.all.first(where: { $0.id == id })?.isCompound ?? false
    }

    /// The RIR recorded for row `idx`, or nil when it was left unset (or the row has no entry). Any exercise.
    static func recorded(_ item: SessionItem, at idx: Int) -> Int? {
        guard item.actualRIRs.indices.contains(idx), item.actualRIRs[idx] >= 0 else { return nil }
        return item.actualRIRs[idx]
    }

    /// The RIR a DECISION may use for row `idx`: the recorded one, and only on a compound lift.
    static func decisionRIR(_ item: SessionItem, at idx: Int) -> Int? {
        isCompound(item.exerciseId) ? recorded(item, at: idx) : nil
    }

    /// Reads a raw array value: nil for unset.
    static func value(_ raw: Int) -> Int? { raw >= 0 ? raw : nil }
}
