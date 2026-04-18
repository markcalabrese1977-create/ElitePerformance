import Foundation
import SwiftData

enum CanonicalExerciseIdMigration {
    private static let completionKey = "canonicalExerciseIdMigration.v1.completed"

    static func runIfNeeded(in context: ModelContext) {
        if UserDefaults.standard.bool(forKey: completionKey) {
            print("ℹ️ Canonical exercise ID migration not needed.")
            return
        }

        let descriptor = FetchDescriptor<Session>()
        guard let sessions = try? context.fetch(descriptor) else {
            print("⚠️ Canonical exercise ID migration failed: could not fetch sessions.")
            return
        }

        var changedCount = 0

        for session in sessions {
            for item in session.items {
                let rawId = item.exerciseId
                let canonicalId = ExerciseCatalog.canonicalExerciseId(for: rawId)

                guard !canonicalId.isEmpty else { continue }
                guard canonicalId != rawId else { continue }

                item.exerciseId = canonicalId

                if item.exerciseNameSnapshot?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                    item.exerciseNameSnapshot = ExerciseCatalog.displayName(for: canonicalId)
                }

                changedCount += 1
            }
        }

        do {
            if changedCount > 0 {
                try context.save()
                print("✅ Canonical exercise ID migration completed. Updated \(changedCount) items.")
            } else {
                print("ℹ️ Canonical exercise ID migration found nothing to update.")
            }

            UserDefaults.standard.set(true, forKey: completionKey)
        } catch {
            print("⚠️ Canonical exercise ID migration save failed: \(error)")
        }
    }
}
