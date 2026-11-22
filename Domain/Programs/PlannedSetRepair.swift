import Foundation
import SwiftData

/// A planned session whose item gained a set (Change prescription, the Program day editor, volume regulation) used to leave the new set
/// EMPTY: the planned arrays keep padding slots past the planned sets, and growing the count exposed a padding slot (load 0, reps 0, RIR 0)
/// instead of copying the set before it. New sets now copy their predecessor; this repairs the items already written that way.
///
/// Scope: an unlogged item of a PLANNED session, not bodyweight, whose back-off row `i < targetSets` has a planned load of 0 (or no slot at
/// all) while an earlier back-off row has one. That row takes the previous row's planned load; when its reps were 0 too (an empty row) it also
/// takes the previous row's reps and RIR. Top-set rows, completed or in-progress sessions and logged values are never touched, and
/// `planEdited` is left as it is (the repair is not a lifter edit). Idempotent.
enum PlannedSetRepair {

    struct Fix {
        let session: Session
        let item: SessionItem
        /// Zero-based row.
        let index: Int
        let oldLoad: Double, newLoad: Double
        let oldReps: Int, newReps: Int
        let oldRIR: Int, newRIR: Int
    }

    static func plan(sessions: [Session], customExercises: [CustomExercise] = []) -> [Fix] {
        var fixes: [Fix] = []
        for session in sessions where session.status == .planned {
            for item in session.items where item.targetSets > 1 {
                if ExerciseCatalog.isBodyweight(exerciseId: item.exerciseId, customExercises: customExercises) { continue }
                if item.actualReps.contains(where: { $0 > 0 }) || item.actualLoads.contains(where: { $0 > 0 }) { continue }
                var loads = item.plannedLoadsBySet, reps = item.plannedRepsBySet, rirs = item.plannedRIRsBySet
                func at<T>(_ a: [T], _ i: Int, _ zero: T) -> T { a.indices.contains(i) ? a[i] : zero }
                var previous: Int?                                  // the last back-off row seen
                var sawLoad = false
                for i in 0..<item.targetSets where !item.isTopRow(i) {
                    let load = at(loads, i, 0.0)
                    if load > 0 { sawLoad = true }
                    else if sawLoad, let p = previous {
                        let newLoad = at(loads, p, 0.0)
                        let rep = at(reps, i, 0), rir = at(rirs, i, 0)
                        let emptyRow = rep == 0
                        let newReps = emptyRow ? at(reps, p, 0) : rep
                        let newRIR = emptyRow ? at(rirs, p, 0) : rir
                        fixes.append(Fix(session: session, item: item, index: i, oldLoad: load, newLoad: newLoad,
                                         oldReps: rep, newReps: newReps, oldRIR: rir, newRIR: newRIR))
                        func put<T>(_ a: inout [T], _ v: T, _ zero: T) { while a.count <= i { a.append(zero) }; a[i] = v }
                        put(&loads, newLoad, 0.0); put(&reps, newReps, 0); put(&rirs, newRIR, 0)
                    }
                    previous = i
                }
            }
        }
        return fixes
    }

    static func apply(_ fixes: [Fix]) {
        for f in fixes {
            func put<T>(_ a: inout [T], _ v: T, _ zero: T) { while a.count <= f.index { a.append(zero) }; a[f.index] = v }
            put(&f.item.plannedLoadsBySet, f.newLoad, 0.0)
            put(&f.item.plannedRepsBySet, f.newReps, 0)
            put(&f.item.plannedRIRsBySet, f.newRIR, 0)
        }
    }

    @discardableResult
    static func run(in context: ModelContext) -> [Fix] {
        guard let all = try? context.fetch(FetchDescriptor<Session>(sortBy: [SortDescriptor(\Session.date, order: .forward)])) else { return [] }
        let custom = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []
        let fixes = plan(sessions: all, customExercises: custom)
        apply(fixes)
        return fixes
    }
}

/// Startup backfill for `PlannedSetRepair`; idempotent, so it runs every launch.
enum PlannedSetRepairBackfill {
    static func runIfNeeded(in context: ModelContext) {
        let fixes = PlannedSetRepair.run(in: context)
        guard !fixes.isEmpty else {
            BackfillLog.note("ℹ️ planned-set repair not needed.")
            return
        }
        do {
            try context.save()
            BackfillLog.note("✅ planned-set repair completed. Filled \(fixes.count) empty planned set\(fixes.count == 1 ? "" : "s") on \(Set(fixes.map { $0.item.persistentModelID }).count) planned exercises.")
        } catch {
            context.rollback()
            BackfillLog.note("⚠️ planned-set repair save failed: \(error)")
        }
    }
}
