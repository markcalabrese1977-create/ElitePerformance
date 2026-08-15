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
enum BodyweightPhantomLoadMigration {
    private static let completionKey = "bodyweightPhantomLoadMigration.v1.completed"

    static func runIfNeeded(in context: ModelContext) {
        if UserDefaults.standard.bool(forKey: completionKey) {
            print("ℹ️ Bodyweight phantom-load migration not needed.")
            return
        }

        guard let items = try? context.fetch(FetchDescriptor<SessionItem>()) else {
            print("⚠️ Bodyweight phantom-load migration failed: could not fetch session items.")
            return
        }

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
                print("✅ Bodyweight phantom-load migration completed. Cleared \(changedCount) items.")
            } else {
                print("ℹ️ Bodyweight phantom-load migration found nothing to clear.")
            }

            UserDefaults.standard.set(true, forKey: completionKey)
        } catch {
            print("⚠️ Bodyweight phantom-load migration save failed: \(error)")
        }
    }
}
