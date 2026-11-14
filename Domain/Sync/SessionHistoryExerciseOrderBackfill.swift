import Foundation
import SwiftData

/// One-time backfill for `SessionHistoryExercise.order`.
///
/// The exercise list of a history entry is an unordered relationship, so the order the exercises were done in was never
/// stored; a restore even reshuffled it. Rows that predate `order` all decode with 0. For each history entry whose
/// exercises all still have order 0, the current relationship order (the best available: the original is already lost on a
/// device that restored a backup) is written as the order. Entries with an order already assigned are left alone. Idempotent.
/// On a store with no history yet it does nothing and does NOT mark itself done.
enum SessionHistoryExerciseOrderBackfill {
    private static let completionKey = "sessionHistoryExerciseOrder.v1.completed"

    static func runIfNeeded(in context: ModelContext) {
        if UserDefaults.standard.bool(forKey: completionKey) {
            BackfillLog.note("ℹ️ SessionHistoryExercise order backfill not needed.")
            return
        }
        guard let histories = try? context.fetch(FetchDescriptor<SessionHistory>()) else {
            BackfillLog.note("⚠️ SessionHistoryExercise order backfill failed: could not fetch history.")
            return
        }
        guard !histories.isEmpty else {
            BackfillLog.note("ℹ️ SessionHistoryExercise order backfill: no history yet, will run once there is.")
            return
        }
        var changed = 0
        for history in histories where history.exercises.count > 1 && history.exercises.allSatisfy({ $0.order == 0 }) {
            for (index, exercise) in history.exercises.enumerated() { exercise.order = index }
            changed += 1
        }
        do {
            if changed > 0 { try context.save() }
            UserDefaults.standard.set(true, forKey: completionKey)
            BackfillLog.note(changed > 0
                ? "✅ SessionHistoryExercise order backfill completed. Ordered \(changed) history entries."
                : "ℹ️ SessionHistoryExercise order backfill not needed.")
        } catch {
            BackfillLog.note("⚠️ SessionHistoryExercise order backfill failed to save: \(error)")
        }
    }
}
