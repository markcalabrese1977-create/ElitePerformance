import Foundation
import SwiftData

/// Items created before RIR could be "unset" were padded with 0s. On a compound lift of a PLANNED or IN-PROGRESS session, a
/// set that has no reps and an RIR of 0 was never logged: its 0 is padding, not a recorded RIR, so it becomes unset (-1).
/// Logged sets (reps > 0), completed sessions and isolation lifts are never touched. Idempotent: a converted set is -1, no
/// longer 0, so a second run changes nothing and there is no flag to persist.
enum RIRUnsetBackfill {

    /// The (item, row) pairs a run would convert.
    static func candidates(in context: ModelContext) -> [(item: SessionItem, row: Int)] {
        guard let sessions = try? context.fetch(FetchDescriptor<Session>()) else { return [] }
        var out: [(SessionItem, Int)] = []
        for s in sessions where s.status == .planned || s.status == .inProgress {
            for item in s.items where RIREntry.isCompound(item.exerciseId) {
                for row in RIREntry.paddedZeroRows(item) { out.append((item, row)) }
            }
        }
        return out
    }

    static func runIfNeeded(in context: ModelContext) {
        let todo = candidates(in: context)
        guard !todo.isEmpty else {
            BackfillLog.note("ℹ️ RIR unset backfill not needed.")
            return
        }
        for (item, row) in todo { RIREntry.setRecorded(item, at: row, to: RIREntry.unset) }
        do {
            try context.save()
            BackfillLog.note("✅ RIR unset backfill completed. Cleared \(todo.count) padded sets.")
        } catch {
            context.rollback()
            BackfillLog.note("⚠️ RIR unset backfill save failed: \(error)")
        }
    }
}
