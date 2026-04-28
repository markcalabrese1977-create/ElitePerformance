import Foundation
import SwiftData

enum CustomExerciseIdRepairMigration {
    private static let completionKey = "customExerciseIdRepairMigration.v1.completed"

    /// Repairs session items that have a custom exercise UUID as their exerciseId
    /// but whose exerciseNameSnapshot matches a known built-in catalog exercise.
    /// This happens when PlanMemoryEngine carries forward items from a session
    /// that contained a custom exercise, stamping the custom UUID on all future items.
    static func runIfNeeded(in context: ModelContext) {
        if UserDefaults.standard.bool(forKey: completionKey) {
            print("ℹ️ Custom exercise ID repair migration not needed.")
            return
        }

        let descriptor = FetchDescriptor<Session>()
        guard let sessions = try? context.fetch(descriptor) else {
            print("⚠️ Custom exercise ID repair migration failed: could not fetch sessions.")
            return
        }

        var changedCount = 0

        for session in sessions {
            for item in session.items {
                let rawId = item.exerciseId

                // Only target custom exercise IDs
                guard rawId.hasPrefix("custom_") else { continue }

                // Try to resolve to a built-in via the name snapshot
                guard let snapshot = item.exerciseNameSnapshot?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !snapshot.isEmpty else { continue }

                guard let builtInId = ExerciseCatalog.canonicalBuiltInId(forExerciseName: snapshot) else { continue }

                // Only repair if the snapshot name maps to a real catalog exercise
                // that is different from what's stored
                guard builtInId != rawId else { continue }

                item.exerciseId = builtInId
                changedCount += 1
            }
        }

        do {
            if changedCount > 0 {
                try context.save()
                print("✅ Custom exercise ID repair completed. Updated \(changedCount) items.")
            } else {
                print("ℹ️ Custom exercise ID repair found nothing to update.")
            }
            UserDefaults.standard.set(true, forKey: completionKey)
        } catch {
            print("⚠️ Custom exercise ID repair save failed: \(error)")
        }
    }
}
