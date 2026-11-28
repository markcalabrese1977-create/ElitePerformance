import Foundation
import SwiftData

/// One-time migration that clears phantom numeric loads from bodyweight exercises.
///
/// Before FIX B, the load-projection / carry-forward engine progressed a fictional
/// external load for bodyweight exercises (e.g. a mistyped 235 on a bodyweight
/// Pull-Up that then climbed week over week to 250). That phantom lived in
/// `SessionItem.suggestedLoad` and `SessionItem.plannedLoadsBySet`, surfacing as a
/// bogus "SUGGESTED 250.0" pill and — at the next meso boundary — seeding the new
/// block via ProgramGenerator.anchorLoadsForNewMeso's `suggestedLoad == 0` gate.
///
/// FIX B stops *new* phantoms at the source: LoadProjectionService.project returns
/// nil for BW, PlanMemoryEngine no longer carries a BW load, and SessionView's
/// persist() re-stamp / editSet pre-fill are BW-guarded. This migration clears any
/// phantom already persisted: for every `SessionItem` whose exercise is bodyweight,
/// reset `suggestedLoad` to 0 and zero out `plannedLoadsBySet` (preserving array
/// length so the materializer's per-set indexing is unaffected).
///
/// `actualLoads` are intentionally left untouched — the Cut 0 fix already stores
/// those as 0 for BW work, and a genuinely logged value is real data, not a phantom.
/// We only ever clear the *plan* fields, and only for bodyweight exercises, so
/// loaded-exercise data is never modified.
///
/// Only items of PLANNED sessions are cleared. A completed (or in-progress) session is history: a restore
/// clears this migration's completion flag and re-runs it, and it must not rewrite what a finished session
/// held. The readers that could show a phantom plan load on a finished bodyweight item (the History set
/// row, the analytics plan column, the block summary's opening/closing load, the volume-regulation fill)
/// ignore it themselves instead.
enum BodyweightPhantomLoadMigration {
    private static let completionKey = "bodyweightPhantomLoadMigration.v1.completed"

    static func runIfNeeded(in context: ModelContext) {
        if UserDefaults.standard.bool(forKey: completionKey) {
            BackfillLog.note("ℹ️ Bodyweight phantom-load migration not needed.")
            return
        }

        guard let sessions = try? context.fetch(FetchDescriptor<Session>()) else {
            BackfillLog.note("⚠️ Bodyweight phantom-load migration failed: could not fetch sessions.")
            return
        }
        let items = sessions.filter { $0.status == .planned }.flatMap(\.items)

        let customExercises = (try? context.fetch(FetchDescriptor<CustomExercise>())) ?? []

        var changedCount = 0

        for item in items {
            guard ExerciseCatalog.isBodyweight(
                exerciseId: item.exerciseId,
                customExercises: customExercises
            ) else { continue }

            let hasPhantom = item.suggestedLoad != 0 || item.plannedLoadsBySet.contains { $0 != 0 }
            guard hasPhantom else { continue }

            item.suggestedLoad = 0
            item.plannedLoadsBySet = Array(repeating: 0, count: item.plannedLoadsBySet.count)
            changedCount += 1
        }

        do {
            if changedCount > 0 {
                try context.save()
                BackfillLog.note("✅ Bodyweight phantom-load migration completed. Cleared \(changedCount) items.")
            } else {
                BackfillLog.note("ℹ️ Bodyweight phantom-load migration found nothing to clear.")
            }

            UserDefaults.standard.set(true, forKey: completionKey)
        } catch {
            BackfillLog.note("⚠️ Bodyweight phantom-load migration save failed: \(error)")
        }
    }
}
