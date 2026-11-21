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
        // A custom exercise has no cluster: it is compound when the lifter said so, or when its closest built-in is
        // (`CustomExercise.resolvedIsCompound`, carried by the catalog mirror that context-free lookups read).
        if !ExerciseCatalog.builtIn.contains(where: { $0.id == id }) {
            return ExerciseCatalog.all.first(where: { $0.id == id })?.isCompound ?? false
        }
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
        guard EffortTracking.mode != .off else { return nil }   // Effort tracking Off: pure rep progression
        return isCompound(item.exerciseId) ? recorded(item, at: idx) : nil
    }

    /// Rows holding a 0 with no reps behind them: padding from before RIR could be unset, not a recorded value.
    static func paddedZeroRows(_ item: SessionItem) -> [Int] {
        (0..<item.actualRIRs.count).filter { row in
            item.actualRIRs[row] == 0 && (item.actualReps.indices.contains(row) ? item.actualReps[row] : 0) == 0
        }
    }

    /// Writes the RIR of row `idx`, padding any rows before it as unset. The only element write.
    static func setRecorded(_ item: SessionItem, at idx: Int, to value: Int) {
        guard idx >= 0 else { return }
        if item.actualRIRs.count <= idx { item.actualRIRs.append(contentsOf: unsetArray(count: idx + 1 - item.actualRIRs.count)) }
        item.actualRIRs[idx] = value
    }

    /// Grows (with unset) or trims the array to `count` rows.
    static func resize(_ item: SessionItem, to count: Int) {
        if item.actualRIRs.count < count {
            item.actualRIRs.append(contentsOf: unsetArray(count: count - item.actualRIRs.count))
        } else if item.actualRIRs.count > count {
            item.actualRIRs = Array(item.actualRIRs.prefix(count))
        }
    }

    /// Reads a raw array value: nil for unset.
    static func value(_ raw: Int) -> Int? { raw >= 0 ? raw : nil }
}
